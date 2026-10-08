"""US 7.3 - user and role management, and the audited role change of US 1.3."""

import uuid

import pytest
from sqlalchemy import select

from app.models import (
    Account,
    AuditLog,
    ConsentRecord,
    ExercisePlan,
    Notification,
    PatientAssignment,
    Role,
)
from tests.conftest import PASSWORD, bearer, sign_in

USERS = "/api/v1/admin/users"
NOBODY = "00000000-0000-0000-0000-000000000000"


@pytest.fixture
def admin(make) -> Account:
    return make.account(Role.admin, full_name="Alex Morgan")


@pytest.fixture
def headers(client, admin) -> dict[str, str]:
    return bearer(sign_in(client, admin))


def stored(db, account: Account) -> Account:
    """The account as the database has it now, not as this test last saw it."""
    db.expire_all()
    return db.get(Account, account.id)


def audit_entries(db, action: str) -> list[AuditLog]:
    db.expire_all()
    return list(db.execute(select(AuditLog).where(AuditLog.action == action)).scalars())


def notices(db, account: Account) -> list[Notification]:
    db.expire_all()
    return list(db.execute(select(Notification).where(Notification.recipient_id == account.id)).scalars())


def login(client, identifier: str, password: str, **extra):
    return client.post("/api/v1/auth/login", json={"identifier": identifier, "password": password, **extra})


def assign_plan(client, physio: Account, patient: Account, exercise) -> dict:
    response = client.post(
        f"/api/v1/physio/patients/{patient.id}/plans",
        json={"name": "Knee plan", "items": [{"exercise_id": str(exercise.id), "sets": 3, "reps": 10}]},
        headers=bearer(sign_in(client, physio)),
    )
    assert response.status_code == 201, response.text
    return response.json()


# --- Listing -----------------------------------------------------------------


def test_list_shows_each_account_with_what_an_admin_needs_to_manage_it(client, make, headers):
    sarah = make.account(Role.physiotherapist, full_name="Sarah Malik")
    jane = make.patient_of(sarah)
    make.patient_of(sarah)
    gone = make.patient_of(sarah)
    gone.is_active = False
    make.db.commit()
    sign_in(client, jane)

    users = {u["id"]: u for u in client.get(USERS, headers=headers).json()}

    assert len(users) == 5
    assert users[str(jane.id)]["physiotherapist"] == {"id": str(sarah.id), "full_name": "Sarah Malik"}
    assert users[str(jane.id)]["patient_count"] is None
    assert users[str(jane.id)]["last_seen_at"] is not None
    # Only patients who can still use the app count towards a caseload.
    assert users[str(sarah.id)]["patient_count"] == 2
    assert users[str(sarah.id)]["physiotherapist"] is None
    assert users[str(sarah.id)]["last_seen_at"] is None
    assert users[str(gone.id)]["is_active"] is False
    assert "password" not in str(users).replace("must_change_password", "")


def test_list_can_be_filtered_by_role_status_and_search_text(client, make, headers):
    sarah = make.account(Role.physiotherapist, "sarah@clinic.test", full_name="Sarah Malik")
    make.account(Role.physiotherapist, "omar@clinic.test", full_name="Omar Farooq", active=False)
    make.patient_of(sarah, "jane_cooper@example.test")

    def names(query: str) -> list[str]:
        return [u["full_name"] for u in client.get(f"{USERS}?{query}", headers=headers).json()]

    assert names("role=physiotherapist") == ["Omar Farooq", "Sarah Malik"]
    assert names("role=physiotherapist&active=true") == ["Sarah Malik"]
    assert names("active=false") == ["Omar Farooq"]
    assert names("q=MALIK") == ["Sarah Malik"]
    assert names("q=omar@clinic") == ["Omar Farooq"]
    # "_" and "%" are searched for as written, not treated as wildcards.
    assert names("q=jane_cooper") == ["Test Patient"]
    assert names("q=jane%25cooper") == []
    assert names("q=nobody-here") == []


# --- Creating accounts -------------------------------------------------------


def test_admin_creates_a_physiotherapist_who_must_choose_their_own_password(client, db, admin, headers):
    response = client.post(
        USERS,
        json={"full_name": "  Omar   Farooq ", "identifier": "Omar@Clinic.Test", "role": "physiotherapist"},
        headers=headers,
    )

    assert response.status_code == 201, response.text
    created = response.json()
    temporary = created["temporary_password"]
    assert created["user"]["full_name"] == "Omar Farooq"
    assert created["user"]["email"] == "omar@clinic.test"
    assert created["user"]["must_change_password"] is True and created["user"]["patient_count"] == 0
    entry = audit_entries(db, "account.created")[0]
    assert entry.actor_id == admin.id and entry.target_id == created["user"]["id"]
    assert entry.detail == {"role": "physiotherapist"}
    assert temporary not in str(db.execute(select(AuditLog.detail)).all())

    # First sign-in: nothing opens except choosing a new password.
    signed_in = login(client, "omar@clinic.test", temporary, role="physiotherapist")
    assert signed_in.status_code == 200 and signed_in.json()["password_change_required"] is True
    tokens = signed_in.json()
    blocked = client.get("/api/v1/physio/patients", headers=bearer(tokens))
    assert blocked.status_code == 403
    assert blocked.json()["detail"]["code"] == "password_change_required"
    assert client.get("/api/v1/auth/me", headers=bearer(tokens)).status_code == 200

    changed = client.post(
        "/api/v1/auth/change-password",
        json={"current_password": temporary, "new_password": "Chosen-By-Omar-1"},
        headers=bearer(tokens),
    )
    assert changed.status_code == 200 and changed.json()["password_change_required"] is False
    assert client.get("/api/v1/physio/patients", headers=bearer(tokens)).status_code == 200
    assert login(client, "omar@clinic.test", temporary).status_code == 401
    detail = audit_entries(db, "account.password_changed")[0].detail
    assert detail["replaced_temporary_password"] is True


def test_admin_creates_a_patient_already_linked_to_a_physiotherapist(client, db, make, headers):
    sarah = make.account(Role.physiotherapist, full_name="Sarah Malik")

    response = client.post(
        USERS,
        json={
            "full_name": "Marcus Johnson",
            "identifier": "+92 300 1234567",
            "role": "patient",
            "physiotherapist_id": str(sarah.id),
        },
        headers=headers,
    )

    assert response.status_code == 201, response.text
    user = response.json()["user"]
    assert user["mobile"] == "+923001234567" and user["email"] is None
    assert user["physiotherapist"] == {"id": str(sarah.id), "full_name": "Sarah Malik"}
    roster = client.get("/api/v1/physio/patients", headers=bearer(sign_in(client, sarah))).json()
    assert [p["full_name"] for p in roster] == ["Marcus Johnson"]
    assert audit_entries(db, "account.created")[0].detail == {
        "role": "patient",
        "physiotherapist_id": str(sarah.id),
    }
    notice = notices(db, sarah)[0]
    assert notice.kind == "patient_assigned" and "Marcus Johnson" in notice.body

    # The patient chooses a password, then still has to acknowledge the advisory.
    temporary = response.json()["temporary_password"]
    tokens = login(client, "+923001234567", temporary, role="patient").json()
    assert tokens["password_change_required"] is True and tokens["advisory_acknowledged"] is False
    consent = client.get("/api/v1/patient/consent", headers=bearer(tokens))
    assert consent.status_code == 403 and consent.json()["detail"]["code"] == "password_change_required"
    client.post(
        "/api/v1/auth/change-password",
        json={"current_password": temporary, "new_password": "Chosen-By-Marcus-1"},
        headers=bearer(tokens),
    )
    assert client.get("/api/v1/patient/consent", headers=bearer(tokens)).status_code == 200


@pytest.mark.parametrize(
    ("body", "status", "code"),
    [
        ({"full_name": "No Physio", "identifier": "a@example.test", "role": "patient"}, 422, None),
        ({"full_name": "X", "identifier": "a@example.test", "role": "admin"}, 422, None),
        (
            {"full_name": "Bad Contact", "identifier": "not-an-email", "role": "admin"},
            422,
            "identifier_invalid",
        ),
        ({"full_name": "Bad Role", "identifier": "a@example.test", "role": "superuser"}, 422, None),
        (
            {"full_name": "Both Roles", "identifier": "a@example.test", "role": ["admin", "patient"]},
            422,
            None,
        ),
    ],
)
def test_an_account_cannot_be_created_from_incomplete_or_invalid_details(
    client, db, headers, body, status, code
):
    response = client.post(USERS, json=body, headers=headers)

    assert response.status_code == status
    if code:
        assert response.json()["detail"]["code"] == code
    assert len(db.execute(select(Account)).all()) == 1  # only the admin


def test_staff_are_never_given_a_physiotherapist_and_patients_need_an_active_one(client, make, headers):
    sarah = make.account(Role.physiotherapist)
    left = make.account(Role.physiotherapist, active=False)
    other_admin = make.account(Role.admin)

    def create(role: str, physio: Account | None):
        body = {"full_name": "New Person", "identifier": f"{uuid.uuid4().hex[:8]}@example.test", "role": role}
        if physio:
            body["physiotherapist_id"] = str(physio.id)
        return client.post(USERS, json=body, headers=headers)

    assert create("physiotherapist", sarah).status_code == 422
    for not_a_working_physio in (left, other_admin):
        response = create("patient", not_a_working_physio)
        assert response.status_code == 422
        assert response.json()["detail"]["code"] == "physiotherapist_invalid"
    assert create("patient", sarah).status_code == 201


def test_two_accounts_cannot_share_an_email_or_mobile(client, db, make, headers):
    make.account(Role.patient, "taken@example.test")

    response = client.post(
        USERS,
        json={"full_name": "Second Person", "identifier": "TAKEN@example.test", "role": "admin"},
        headers=headers,
    )

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "identifier_taken"
    assert audit_entries(db, "account.created") == []


# --- Deactivating and reactivating -------------------------------------------


def test_deactivated_account_cannot_sign_in_and_keeps_its_history(client, db, make, admin, headers):
    sarah = make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)
    plan = assign_plan(client, sarah, jane, make.exercise())
    janes_tokens = sign_in(client, jane)
    client.post(
        "/api/v1/patient/consent",
        json={
            "version": client.get("/api/v1/patient/consent", headers=bearer(janes_tokens)).json()[
                "disclaimer"
            ]["version"],
            "acknowledged": True,
        },
        headers=bearer(janes_tokens),
    )

    response = client.post(f"{USERS}/{jane.id}/deactivate", headers=headers)

    assert response.status_code == 200 and response.json()["is_active"] is False
    # Signed out at once, and refused exactly like a wrong password from now on.
    assert client.get("/api/v1/auth/me", headers=bearer(janes_tokens)).status_code == 401
    refused = login(client, jane.email, PASSWORD)
    assert refused.status_code == 401 and refused.json()["detail"]["code"] == "invalid_credentials"
    refresh = client.post(
        "/api/v1/auth/refresh", json={"refresh_token": janes_tokens["tokens"]["refresh_token"]}
    )
    assert refresh.status_code == 401
    # Nothing the account produced is gone.
    assert db.get(ExercisePlan, uuid.UUID(plan["id"])) is not None
    assert db.execute(select(ConsentRecord).where(ConsentRecord.account_id == jane.id)).scalar_one()
    assert db.execute(select(PatientAssignment).where(PatientAssignment.patient_id == jane.id)).scalar_one()
    assert audit_entries(db, "plan.assigned") and audit_entries(db, "consent.acknowledged")
    entry = audit_entries(db, "account.deactivated")[0]
    assert entry.actor_id == admin.id and entry.target_id == str(jane.id)
    assert entry.detail == {"role": "patient", "devices_signed_out": 1}
    # Her physiotherapist can no longer change the plan of an account that is off.
    replan = client.post(
        f"/api/v1/physio/patients/{jane.id}/plans",
        json={
            "name": "Another",
            "items": [{"exercise_id": plan["items"][0]["exercise"]["id"], "sets": 2, "reps": 8}],
        },
        headers=bearer(sign_in(client, sarah)),
    )
    assert replan.status_code == 409 and replan.json()["detail"]["code"] == "patient_inactive"


def test_reactivated_account_can_sign_in_again(client, db, make, headers):
    sarah = make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)
    client.post(f"{USERS}/{jane.id}/deactivate", headers=headers)

    response = client.post(f"{USERS}/{jane.id}/activate", headers=headers)

    assert response.status_code == 200 and response.json()["is_active"] is True
    sign_in(client, jane)
    assert len(audit_entries(db, "account.activated")) == 1
    # Asking again changes nothing and records nothing.
    client.post(f"{USERS}/{jane.id}/activate", headers=headers)
    assert len(audit_entries(db, "account.activated")) == 1


def test_physiotherapist_with_patients_cannot_be_deactivated_until_they_are_reassigned(client, make, headers):
    sarah = make.account(Role.physiotherapist)
    omar = make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)
    make.patient_of(sarah)

    blocked = client.post(f"{USERS}/{sarah.id}/deactivate", headers=headers)

    assert blocked.status_code == 409
    assert blocked.json()["detail"]["code"] == "has_active_patients"
    assert blocked.json()["detail"]["patient_count"] == 2
    assert "2 active patients" in blocked.json()["detail"]["message"]
    sign_in(client, sarah)  # still active

    others = [u for u in client.get(f"{USERS}?role=patient", headers=headers).json()]
    for patient in others:
        moved = client.post(
            f"{USERS}/{patient['id']}/reassign", json={"physiotherapist_id": str(omar.id)}, headers=headers
        )
        assert moved.status_code == 200
    assert jane.id is not None
    assert client.post(f"{USERS}/{sarah.id}/deactivate", headers=headers).status_code == 200


def test_patient_cannot_be_reactivated_while_their_physiotherapist_is_inactive(client, make, headers):
    sarah = make.account(Role.physiotherapist)
    omar = make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)
    client.post(f"{USERS}/{jane.id}/deactivate", headers=headers)
    assert client.post(f"{USERS}/{sarah.id}/deactivate", headers=headers).status_code == 200

    blocked = client.post(f"{USERS}/{jane.id}/activate", headers=headers)

    assert blocked.status_code == 409
    assert blocked.json()["detail"]["code"] == "physiotherapist_inactive"
    client.post(f"{USERS}/{jane.id}/reassign", json={"physiotherapist_id": str(omar.id)}, headers=headers)
    assert client.post(f"{USERS}/{jane.id}/activate", headers=headers).status_code == 200


def test_admin_cannot_lock_themselves_out(client, db, admin, headers):
    deactivate = client.post(f"{USERS}/{admin.id}/deactivate", headers=headers)
    demote = client.post(f"{USERS}/{admin.id}/role", json={"role": "physiotherapist"}, headers=headers)
    reset = client.post(f"{USERS}/{admin.id}/reset-password", headers=headers)

    for response in (deactivate, demote, reset):
        assert response.status_code == 409
        assert response.json()["detail"]["code"] == "own_account"
    assert client.get("/api/v1/auth/me", headers=headers).status_code == 200
    account = stored(db, admin)
    assert account.is_active and account.role == Role.admin and not account.must_change_password


# --- Reassigning a patient ---------------------------------------------------


def test_reassignment_moves_access_from_the_old_physiotherapist_to_the_new_one(
    client, db, make, admin, headers
):
    sarah = make.account(Role.physiotherapist, full_name="Sarah Malik")
    omar = make.account(Role.physiotherapist, full_name="Omar Farooq")
    jane = make.patient_of(sarah)
    plan = assign_plan(client, sarah, jane, make.exercise())
    sarahs = bearer(sign_in(client, sarah))
    omars = bearer(sign_in(client, omar))
    assert client.get(f"/api/v1/physio/patients/{jane.id}", headers=omars).status_code == 404

    response = client.post(
        f"{USERS}/{jane.id}/reassign", json={"physiotherapist_id": str(omar.id)}, headers=headers
    )

    assert response.status_code == 200, response.text
    assert response.json()["physiotherapist"] == {"id": str(omar.id), "full_name": "Omar Farooq"}
    # Both sides change with this one request, on tokens issued before it.
    assert client.get(f"/api/v1/physio/patients/{jane.id}", headers=sarahs).status_code == 404
    assert client.get(f"/api/v1/physio/patients/{jane.id}/plans", headers=sarahs).status_code == 404
    assert client.get("/api/v1/physio/patients", headers=sarahs).json() == []
    assert client.get(f"/api/v1/physio/patients/{jane.id}", headers=omars).status_code == 200
    # The plan carries over: the new physiotherapist sees it and the patient keeps it.
    carried = client.get(f"/api/v1/physio/patients/{jane.id}/plans", headers=omars).json()
    assert [p["id"] for p in carried] == [plan["id"]]
    janes = sign_in(client, jane)
    assert janes["physiotherapist"]["full_name"] == "Omar Farooq"
    assert client.get("/api/v1/patient/plan", headers=bearer(janes)).json()["id"] == plan["id"]

    entry = audit_entries(db, "patient.reassigned")[0]
    assert entry.actor_id == admin.id and entry.target_id == str(jane.id)
    assert entry.detail == {
        "from_physiotherapist_id": str(sarah.id),
        "to_physiotherapist_id": str(omar.id),
    }
    # The earlier assignment is closed, not overwritten.
    history = db.execute(
        select(PatientAssignment)
        .where(PatientAssignment.patient_id == jane.id)
        .order_by(PatientAssignment.assigned_at)
    ).scalars()
    assert [(a.physiotherapist_id, a.ended_at is None) for a in history] == [
        (sarah.id, False),
        (omar.id, True),
    ]
    assert [n.kind for n in notices(db, jane)][-1] == "physiotherapist_changed"
    assert [n.kind for n in notices(db, omar)] == ["patient_assigned"]
    assert [n.kind for n in notices(db, sarah)] == ["patient_unassigned"]


def test_reassigning_to_the_same_physiotherapist_changes_nothing(client, db, make, headers):
    sarah = make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)

    response = client.post(
        f"{USERS}/{jane.id}/reassign", json={"physiotherapist_id": str(sarah.id)}, headers=headers
    )

    assert response.status_code == 200
    assert audit_entries(db, "patient.reassigned") == []
    assert notices(db, jane) == [] and notices(db, sarah) == []


def test_only_patients_are_reassigned_and_only_to_an_active_physiotherapist(client, make, admin, headers):
    sarah = make.account(Role.physiotherapist)
    left = make.account(Role.physiotherapist, active=False)
    jane = make.patient_of(sarah)

    def reassign(user: Account | str, to: Account | str):
        user_id = user if isinstance(user, str) else user.id
        to_id = to if isinstance(to, str) else to.id
        return client.post(
            f"{USERS}/{user_id}/reassign", json={"physiotherapist_id": str(to_id)}, headers=headers
        )

    staff = reassign(sarah, sarah)
    assert staff.status_code == 409 and staff.json()["detail"]["code"] == "not_a_patient"
    for target in (left, admin, jane, NOBODY):
        response = reassign(jane, target)
        assert response.status_code == 422
        assert response.json()["detail"]["code"] == "physiotherapist_invalid"
    assert reassign(NOBODY, sarah).status_code == 404


# --- Changing a role ---------------------------------------------------------


def test_role_change_is_audited_with_actor_previous_and_new_role(client, db, make, admin, headers):
    omar = make.account(Role.physiotherapist)
    omars = sign_in(client, omar)

    response = client.post(f"{USERS}/{omar.id}/role", json={"role": "admin"}, headers=headers)

    assert response.status_code == 200 and response.json()["role"] == "admin"
    assert response.json()["patient_count"] is None
    entry = audit_entries(db, "account.role_changed")[0]
    assert entry.actor_id == admin.id and entry.target_id == str(omar.id)
    assert entry.detail == {"from": "physiotherapist", "to": "admin"}
    assert entry.created_at is not None
    # Reflected for the person at once: the old session is over, and they sign
    # in under the new role only.
    assert client.get("/api/v1/physio/patients", headers=bearer(omars)).status_code == 401
    assert login(client, omar.email, PASSWORD, role="physiotherapist").status_code == 401
    as_admin = sign_in(client, omar, role="admin")
    assert client.get(USERS, headers=bearer(as_admin)).status_code == 200
    assert client.get("/api/v1/physio/patients", headers=bearer(as_admin)).status_code == 403
    assert [n.kind for n in notices(db, omar)] == ["account_role_changed"]
    assert stored(db, omar).role == Role.admin


def test_setting_the_role_an_account_already_has_records_nothing(client, db, make, headers):
    omar = make.account(Role.physiotherapist)
    tokens = sign_in(client, omar)

    response = client.post(f"{USERS}/{omar.id}/role", json={"role": "physiotherapist"}, headers=headers)

    assert response.status_code == 200
    assert audit_entries(db, "account.role_changed") == []
    assert client.get("/api/v1/auth/me", headers=bearer(tokens)).status_code == 200


@pytest.mark.parametrize(
    ("current", "requested"),
    [
        (Role.patient, "physiotherapist"),
        (Role.patient, "admin"),
        (Role.physiotherapist, "patient"),
        (Role.admin, "patient"),
    ],
)
def test_patient_and_staff_accounts_never_turn_into_each_other(client, db, make, headers, current, requested):
    sarah = make.account(Role.physiotherapist)
    user = make.patient_of(sarah) if current == Role.patient else make.account(current)

    response = client.post(f"{USERS}/{user.id}/role", json={"role": requested}, headers=headers)

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "role_change_not_allowed"
    assert stored(db, user).role == current
    assert audit_entries(db, "account.role_changed") == []


def test_physiotherapist_with_patients_keeps_the_role_until_they_are_reassigned(client, db, make, headers):
    sarah = make.account(Role.physiotherapist)
    make.patient_of(sarah)

    response = client.post(f"{USERS}/{sarah.id}/role", json={"role": "admin"}, headers=headers)

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "has_active_patients"
    assert stored(db, sarah).role == Role.physiotherapist


@pytest.mark.parametrize("role", ["superuser", "", None, ["admin", "physiotherapist"]])
def test_a_role_is_always_exactly_one_of_the_three(client, db, make, headers, role):
    omar = make.account(Role.physiotherapist)

    response = client.post(f"{USERS}/{omar.id}/role", json={"role": role}, headers=headers)

    assert response.status_code == 422
    assert stored(db, omar).role == Role.physiotherapist


# --- Resetting a password ----------------------------------------------------


def test_password_reset_issues_a_temporary_password_and_signs_the_account_out(
    client, db, make, admin, headers
):
    jane = make.patient_of(make.account(Role.physiotherapist))
    janes = sign_in(client, jane)
    for _ in range(5):  # she has also locked herself out by guessing
        login(client, jane.email, "forgotten-pass-1")
    assert login(client, jane.email, PASSWORD).status_code == 423

    response = client.post(f"{USERS}/{jane.id}/reset-password", headers=headers)

    assert response.status_code == 200
    temporary = response.json()["temporary_password"]
    assert client.get("/api/v1/auth/me", headers=bearer(janes)).status_code == 401
    assert login(client, jane.email, PASSWORD).status_code == 401
    # The pause on sign-in is lifted, so the new password works straight away.
    fresh = login(client, jane.email, temporary)
    assert fresh.status_code == 200 and fresh.json()["password_change_required"] is True
    entry = audit_entries(db, "account.password_reset")[0]
    assert entry.actor_id == admin.id and entry.target_id == str(jane.id)
    assert entry.detail == {"devices_signed_out": 1}
    assert temporary not in str(db.execute(select(AuditLog.detail)).all())
    assert stored(db, jane).password_hash != temporary


def test_each_temporary_password_is_different_and_meets_the_policy(client, make, headers):
    jane = make.patient_of(make.account(Role.physiotherapist))

    issued = {
        client.post(f"{USERS}/{jane.id}/reset-password", headers=headers).json()["temporary_password"]
        for _ in range(5)
    }

    assert len(issued) == 5
    for password in issued:
        assert (
            len(password) == 14 and any(c.isdigit() for c in password) and any(c.isalpha() for c in password)
        )


# --- Editing details ---------------------------------------------------------


def test_details_can_be_corrected_and_the_change_is_recorded(client, db, make, admin, headers):
    jane = make.account(Role.patient, "jane@example.test", full_name="Jane Coper")

    response = client.patch(
        f"{USERS}/{jane.id}",
        json={"full_name": "Jane Cooper", "email": "Jane.Cooper@Example.test", "mobile": "0300 1234567"},
        headers=headers,
    )

    assert response.status_code == 200, response.text
    assert response.json()["full_name"] == "Jane Cooper"
    assert response.json()["email"] == "jane.cooper@example.test"
    assert response.json()["mobile"] == "03001234567"
    entry = audit_entries(db, "account.updated")[0]
    assert entry.actor_id == admin.id
    assert entry.detail == {
        "changes": {
            "full_name": {"from": "Jane Coper", "to": "Jane Cooper"},
            "email": {"from": "jane@example.test", "to": "jane.cooper@example.test"},
            "mobile": {"from": None, "to": "03001234567"},
        }
    }
    sign_in(client, stored(db, jane))  # signs in with the new email
    # Saving the same details again is not a change.
    client.patch(f"{USERS}/{jane.id}", json={"full_name": "Jane Cooper"}, headers=headers)
    assert len(audit_entries(db, "account.updated")) == 1


@pytest.mark.parametrize(
    ("body", "status", "code"),
    [
        ({"email": "taken@example.test"}, 409, "identifier_taken"),
        ({"email": "not-an-email"}, 422, "identifier_invalid"),
        ({"mobile": "12"}, 422, "identifier_invalid"),
        ({"email": ""}, 422, "identifier_required"),
        ({"full_name": "J"}, 422, None),
    ],
)
def test_details_that_would_break_sign_in_are_refused(client, db, make, headers, body, status, code):
    make.account(Role.patient, "taken@example.test")
    jane = make.account(Role.patient, "jane@example.test", full_name="Jane Cooper")

    response = client.patch(f"{USERS}/{jane.id}", json=body, headers=headers)

    assert response.status_code == status
    if code:
        assert response.json()["detail"]["code"] == code
    unchanged = stored(db, jane)
    assert (unchanged.full_name, unchanged.email, unchanged.mobile) == (
        "Jane Cooper",
        "jane@example.test",
        None,
    )
    assert audit_entries(db, "account.updated") == []


def test_an_email_can_be_removed_once_the_account_has_a_mobile_number(client, db, make, headers):
    jane = make.account(Role.patient, "jane@example.test", mobile="+923001234567")

    response = client.patch(f"{USERS}/{jane.id}", json={"email": None}, headers=headers)

    assert response.status_code == 200 and response.json()["email"] is None
    assert login(client, "+92 300 1234567", PASSWORD).status_code == 200


# --- Unknown accounts and the temporary-password gate ------------------------


@pytest.mark.parametrize(
    ("method", "suffix", "body"),
    [
        ("PATCH", "", {"full_name": "Someone Else"}),
        ("POST", "/deactivate", None),
        ("POST", "/activate", None),
        ("POST", "/role", {"role": "admin"}),
        ("POST", "/reassign", {"physiotherapist_id": NOBODY}),
        ("POST", "/reset-password", None),
    ],
)
def test_an_unknown_account_is_not_found(client, headers, method, suffix, body):
    response = client.request(method, f"{USERS}/{NOBODY}{suffix}", json=body, headers=headers)

    assert response.status_code == 404 and response.json()["detail"]["code"] == "not_found"


@pytest.mark.parametrize(
    ("method", "path"),
    [
        ("GET", "/api/v1/admin/users"),
        ("GET", "/api/v1/admin/audit-log"),
        ("GET", "/api/v1/notifications"),
        ("GET", "/api/v1/auth/sessions"),
        ("POST", "/api/v1/auth/sessions/revoke-others"),
    ],
)
def test_a_temporary_password_opens_nothing_but_the_way_to_replace_it(client, make, method, path):
    newcomer = make.account(Role.admin, must_change_password=True)
    tokens = sign_in(client, newcomer)

    response = client.request(method, path, headers=bearer(tokens))

    assert response.status_code == 403
    assert response.json()["detail"]["code"] == "password_change_required"
    assert client.get("/api/v1/auth/me", headers=bearer(tokens)).json()["password_change_required"] is True
    assert client.post("/api/v1/auth/logout", headers=bearer(tokens)).status_code == 204
