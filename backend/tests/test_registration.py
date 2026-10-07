"""US 1.1 - Patient account registration and physiotherapist linking."""

from sqlalchemy import func, select

from app.models import Account, AuditLog, InviteCode, PatientAssignment, Role
from tests.conftest import bearer

URL = "/api/v1/auth/register"


def payload(**overrides) -> dict:
    return {
        "full_name": "Jane Cooper",
        "identifier": "jane@example.test",
        "password": "Recover-2026",
        "invite_code": "PHY-TEST-CODE",
        **overrides,
    }


def test_registration_links_patient_to_the_inviting_physiotherapist(client, db, make):
    physio = make.account(Role.physiotherapist, full_name="Dr. Sarah Malik")
    make.invite(physio)

    response = client.post(URL, json=payload())

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["account"]["role"] == "patient"
    assert body["account"]["email"] == "jane@example.test"
    assert body["physiotherapist"] == {"id": str(physio.id), "full_name": "Dr. Sarah Malik"}

    patient = db.execute(select(Account).where(Account.email == "jane@example.test")).scalar_one()
    link = db.execute(
        select(PatientAssignment).where(PatientAssignment.patient_id == patient.id)
    ).scalar_one()
    assert link.physiotherapist_id == physio.id and link.ended_at is None

    # Registration signs the patient straight in.
    me = client.get("/api/v1/auth/me", headers=bearer(body))
    assert me.status_code == 200 and me.json()["account"]["id"] == str(patient.id)


def test_registration_is_audited_with_the_linked_physiotherapist(client, db, make):
    physio = make.account(Role.physiotherapist)
    make.invite(physio)

    client.post(URL, json=payload())

    entry = db.execute(select(AuditLog).where(AuditLog.action == "account.registered")).scalar_one()
    assert entry.detail["physiotherapist_id"] == str(physio.id)
    assert entry.detail["role"] == "patient"
    assert entry.created_at is not None


def test_mobile_number_can_be_used_instead_of_email(client, make):
    make.invite(make.account(Role.physiotherapist))

    response = client.post(URL, json=payload(identifier="+92 300 1234567"))

    assert response.status_code == 201, response.text
    assert response.json()["account"]["mobile"] == "+923001234567"
    assert response.json()["account"]["email"] is None


def test_invite_code_is_single_use(client, db, make):
    make.invite(make.account(Role.physiotherapist))
    assert client.post(URL, json=payload()).status_code == 201

    second = client.post(URL, json=payload(identifier="someone.else@example.test"))

    assert second.status_code == 400
    assert second.json()["detail"]["code"] == "invite_invalid"
    assert (
        db.execute(select(func.count()).select_from(Account).where(Account.role == Role.patient)).scalar()
        == 1
    )


def test_expired_invite_code_is_rejected_and_no_account_is_created(client, db, make, time):
    make.invite(make.account(Role.physiotherapist), expires_in_days=7)
    time.advance(days=7, seconds=1)

    response = client.post(URL, json=payload())

    assert response.status_code == 400
    assert response.json()["detail"]["code"] == "invite_invalid"
    assert (
        db.execute(select(func.count()).select_from(Account).where(Account.role == Role.patient)).scalar()
        == 0
    )


def test_unknown_invite_code_is_rejected(client, make):
    make.invite(make.account(Role.physiotherapist))

    response = client.post(URL, json=payload(invite_code="PHY-NOPE-NOPE"))

    assert response.status_code == 400
    assert response.json()["detail"]["code"] == "invite_invalid"


def test_invite_from_a_deactivated_physiotherapist_is_rejected(client, make):
    make.invite(make.account(Role.physiotherapist, active=False))

    response = client.post(URL, json=payload())

    assert response.json()["detail"]["code"] == "invite_invalid"


def test_duplicate_identifier_gets_a_neutral_response_and_keeps_the_invite(client, db, make):
    physio = make.account(Role.physiotherapist)
    make.invite(physio)
    make.account(Role.patient, "jane@example.test")

    response = client.post(URL, json=payload(identifier="JANE@example.test"))

    assert response.status_code == 400
    detail = response.json()["detail"]
    assert detail["code"] == "registration_failed"
    for word in ("email", "mobile", "exists", "taken", "registered"):
        assert word not in detail["message"].lower()
    # The code was not burned by the failed attempt.
    assert db.execute(select(InviteCode)).scalar_one().redeemed_at is None


def test_weak_password_is_rejected(client, make):
    make.invite(make.account(Role.physiotherapist))

    assert client.post(URL, json=payload(password="short1")).status_code == 422
    assert client.post(URL, json=payload(password="lettersonly")).status_code == 422
    assert client.post(URL, json=payload(password="1234567890")).status_code == 422


def test_identifier_must_be_an_email_or_mobile_number(client, make):
    make.invite(make.account(Role.physiotherapist))

    response = client.post(URL, json=payload(identifier="not-an-identifier"))

    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "identifier_invalid"
