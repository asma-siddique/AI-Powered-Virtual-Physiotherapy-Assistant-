"""US 1.3 - Role-based access control, enforced by the server on every endpoint."""

import pytest
from sqlalchemy import select

from app.main import app
from app.models import Account, AuditLog, Role
from tests.conftest import bearer, sign_in

# Every role-restricted endpoint and the one role allowed to call it. A new
# endpoint that is missing here fails test_every_endpoint_is_covered below.
RESTRICTED = [
    ("POST", "/api/v1/physio/invite-codes", Role.physiotherapist),
    ("GET", "/api/v1/physio/invite-codes", Role.physiotherapist),
    ("GET", "/api/v1/physio/patients", Role.physiotherapist),
    ("GET", "/api/v1/physio/patients/00000000-0000-0000-0000-000000000000", Role.physiotherapist),
    ("GET", "/api/v1/admin/users", Role.admin),
    ("GET", "/api/v1/admin/audit-log", Role.admin),
    ("GET", "/api/v1/admin/consents", Role.admin),
    ("GET", "/api/v1/patient/consent", Role.patient),
    ("POST", "/api/v1/patient/consent", Role.patient),
]
ANY_SIGNED_IN = [
    ("GET", "/api/v1/auth/me"),
    ("GET", "/api/v1/auth/sessions"),
    ("POST", "/api/v1/auth/logout"),
    ("DELETE", "/api/v1/auth/sessions/00000000-0000-0000-0000-000000000000"),
]
PUBLIC = {
    ("POST", "/api/v1/auth/register"),
    ("POST", "/api/v1/auth/login"),
    ("POST", "/api/v1/auth/refresh"),
    ("GET", "/health"),
    ("GET", "/"),
}


@pytest.mark.parametrize(("method", "path", "allowed"), RESTRICTED)
def test_restricted_endpoint_rejects_every_other_role(client, make, method, path, allowed):
    for role in Role:
        tokens = sign_in(client, make.account(role))
        response = client.request(method, path, headers=bearer(tokens))
        if role == allowed:
            assert response.status_code != 403, f"{role} should reach {method} {path}"
        else:
            assert response.status_code == 403, f"{role} must not reach {method} {path}"
            assert response.json()["detail"]["code"] == "forbidden"


@pytest.mark.parametrize(("method", "path"), [(m, p) for m, p, _ in RESTRICTED] + ANY_SIGNED_IN)
def test_protected_endpoint_requires_a_valid_token(client, method, path):
    assert client.request(method, path).status_code == 401
    assert client.request(method, path, headers={"Authorization": "Bearer not-a-token"}).status_code == 401


def test_every_endpoint_is_covered_by_an_access_rule():
    documented = {(m, p.split("/00000000")[0]) for m, p, _ in RESTRICTED}
    documented |= {(m, p.split("/00000000")[0]) for m, p in ANY_SIGNED_IN} | PUBLIC
    for route in app.routes:
        if not hasattr(route, "methods") or route.path.startswith(("/docs", "/redoc", "/openapi")):
            continue
        for method in route.methods - {"HEAD", "OPTIONS"}:
            prefix = route.path.split("/{")[0]
            assert (method, prefix) in documented, f"No access rule test for {method} {route.path}"


def test_physiotherapist_sees_only_their_own_roster(client, make):
    sarah = make.account(Role.physiotherapist)
    omar = make.account(Role.physiotherapist)
    sarahs_patient = make.patient_of(sarah)
    omars_patient = make.patient_of(omar)

    roster = client.get("/api/v1/physio/patients", headers=bearer(sign_in(client, sarah))).json()

    assert [p["id"] for p in roster] == [str(sarahs_patient.id)]
    assert str(omars_patient.id) not in str(roster)


def test_direct_request_for_another_physiotherapists_patient_is_rejected(client, make):
    sarah = make.account(Role.physiotherapist)
    omars_patient = make.patient_of(make.account(Role.physiotherapist))
    headers = bearer(sign_in(client, sarah))

    theirs = client.get(f"/api/v1/physio/patients/{omars_patient.id}", headers=headers)
    missing = client.get("/api/v1/physio/patients/00000000-0000-0000-0000-000000000000", headers=headers)

    assert theirs.status_code == 404
    assert theirs.json() == missing.json()


def test_physiotherapist_only_lists_their_own_invite_codes(client, make):
    sarah = make.account(Role.physiotherapist)
    omar = make.account(Role.physiotherapist)
    make.invite(omar, code="PHY-OMAR-0001")
    headers = bearer(sign_in(client, sarah))

    created = client.post("/api/v1/physio/invite-codes", headers=headers)
    listed = client.get("/api/v1/physio/invite-codes", headers=headers).json()

    assert created.status_code == 201
    assert created.json()["status"] == "active" and created.json()["code"].startswith("PHY-")
    assert [c["code"] for c in listed] == [created.json()["code"]]


def test_invite_code_created_through_the_api_registers_a_patient(client, db, make):
    physio = make.account(Role.physiotherapist)
    headers = bearer(sign_in(client, physio))
    code = client.post("/api/v1/physio/invite-codes", headers=headers).json()["code"]

    registered = client.post(
        "/api/v1/auth/register",
        json={
            "full_name": "Marcus Johnson",
            "identifier": "marcus@example.test",
            "password": "Recover-2026",
            "invite_code": code.lower(),  # typed in lower case by the patient
        },
    )

    assert registered.status_code == 201, registered.text
    listed = client.get("/api/v1/physio/invite-codes", headers=headers).json()
    assert listed[0]["status"] == "redeemed"
    assert listed[0]["redeemed_by"]["full_name"] == "Marcus Johnson"
    roster = client.get("/api/v1/physio/patients", headers=headers).json()
    assert [p["full_name"] for p in roster] == ["Marcus Johnson"]
    assert db.execute(select(AuditLog).where(AuditLog.action == "invite_code.created")).scalar_one()


def test_role_change_in_the_database_applies_to_the_very_next_request(client, db, make):
    account = make.account(Role.physiotherapist)
    headers = bearer(sign_in(client, account))
    assert client.get("/api/v1/physio/patients", headers=headers).status_code == 200

    db.get(Account, account.id).role = Role.patient
    db.commit()

    assert client.get("/api/v1/physio/patients", headers=headers).status_code == 403


def test_deactivation_ends_existing_sessions_immediately(client, db, make):
    account = make.account(Role.patient)
    headers = bearer(sign_in(client, account))

    db.get(Account, account.id).is_active = False
    db.commit()

    assert client.get("/api/v1/auth/me", headers=headers).status_code == 401


def test_admin_can_read_users_and_the_audit_log(client, make):
    admin = make.account(Role.admin)
    make.account(Role.patient)
    headers = bearer(sign_in(client, admin))

    users = client.get("/api/v1/admin/users", headers=headers)
    patients = client.get("/api/v1/admin/users?role=patient", headers=headers)
    audit = client.get("/api/v1/admin/audit-log", headers=headers)

    assert users.status_code == 200 and len(users.json()) == 2
    assert [u["role"] for u in patients.json()] == ["patient"]
    assert "password_hash" not in users.text
    assert audit.status_code == 200
