"""US 8.3 - key admin and clinical actions are logged with who, when and what
changed, and a log entry can never be edited or deleted."""

import contextlib
from collections.abc import Iterator

import pytest
from sqlalchemy import select, text
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session

from app import rls
from app.db import get_engine
from app.models import Account, AuditLog, Role
from tests.conftest import CHECK, bearer, sign_in

ADMIN = "/api/v1/admin"


def entries(db, action: str) -> list[AuditLog]:
    db.expire_all()
    return list(db.execute(select(AuditLog).where(AuditLog.action == action).order_by(AuditLog.id)).scalars())


@pytest.fixture
def admin(make) -> Account:
    return make.account(Role.admin)


@pytest.fixture
def as_admin(client, admin) -> dict[str, str]:
    return bearer(sign_in(client, admin))


# --- Every listed action leaves an entry ---------------------------------------


def test_a_threshold_change_is_logged_with_the_old_and_new_values(client, db, make, admin, as_admin, time):
    squats = make.exercise("Squats")
    stricter = {**CHECK, "amber": 8}

    response = client.patch(f"{ADMIN}/exercises/{squats.id}", json={"checks": [stricter]}, headers=as_admin)

    assert response.status_code == 200, response.text
    [entry] = entries(db, "exercise_template.updated")
    assert entry.actor_id == admin.id
    assert entry.created_at == time.now()
    assert (entry.target_type, entry.target_id) == ("exercise_template", str(squats.id))
    change = entry.detail["changed"]["checks"]
    assert (change["from"][0]["amber"], change["to"][0]["amber"]) == (10, 8)
    assert entry.detail["version"] == 2


def test_a_template_edit_is_logged_with_what_changed(client, db, make, admin, as_admin):
    squats = make.exercise("Squats")

    client.patch(f"{ADMIN}/exercises/{squats.id}", json={"primary_targets": "Quadriceps"}, headers=as_admin)

    [entry] = entries(db, "exercise_template.updated")
    assert entry.actor_id == admin.id
    assert entry.detail["changed"] == {"primary_targets": {"from": "Quadriceps, glutes", "to": "Quadriceps"}}


def test_switching_an_exercise_off_and_on_is_logged(client, db, make, admin, as_admin):
    squats = make.exercise("Squats")

    client.post(f"{ADMIN}/exercises/{squats.id}/deactivate", headers=as_admin)
    client.post(f"{ADMIN}/exercises/{squats.id}/activate", headers=as_admin)

    for action in ("exercise_template.deactivated", "exercise_template.activated"):
        [entry] = entries(db, action)
        assert (entry.actor_id, entry.target_id) == (admin.id, str(squats.id))


def test_a_role_change_is_logged_with_both_roles(client, db, make, admin, as_admin, time):
    omar = make.account(Role.physiotherapist)

    response = client.post(f"{ADMIN}/users/{omar.id}/role", json={"role": "admin"}, headers=as_admin)

    assert response.status_code == 200, response.text
    [entry] = entries(db, "account.role_changed")
    assert (entry.actor_id, entry.target_id) == (admin.id, str(omar.id))
    assert entry.created_at == time.now()
    assert entry.detail == {"from": "physiotherapist", "to": "admin"}


def test_moving_a_patient_to_another_physiotherapist_is_logged(client, db, make, admin, as_admin):
    sarah, omar = make.account(Role.physiotherapist), make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)

    response = client.post(
        f"{ADMIN}/users/{jane.id}/reassign", json={"physiotherapist_id": str(omar.id)}, headers=as_admin
    )

    assert response.status_code == 200, response.text
    [entry] = entries(db, "patient.reassigned")
    assert (entry.actor_id, entry.target_id) == (admin.id, str(jane.id))
    assert entry.detail == {
        "from_physiotherapist_id": str(sarah.id),
        "to_physiotherapist_id": str(omar.id),
    }


def test_assigning_a_plan_is_logged_with_the_physiotherapist_and_the_patient(client, db, make):
    sarah = make.account(Role.physiotherapist)
    jane = make.patient_of(sarah)
    squats = make.exercise("Squats")
    headers = bearer(sign_in(client, sarah))
    body = {"name": "Knee plan", "items": [{"exercise_id": str(squats.id), "sets": 3, "reps": 12}]}

    first = client.post(f"/api/v1/physio/patients/{jane.id}/plans", json=body, headers=headers)
    # A new plan replaces the one before it: that is logged as well.
    second = client.post(
        f"/api/v1/physio/patients/{jane.id}/plans", json={**body, "name": "Week 2"}, headers=headers
    )

    assert (first.status_code, second.status_code) == (201, 201)
    logged = entries(db, "plan.assigned")
    assert [entry.actor_id for entry in logged] == [sarah.id, sarah.id]
    assert [entry.target_id for entry in logged] == [first.json()["id"], second.json()["id"]]
    assert all(entry.detail.get("patient_id") == str(jane.id) for entry in logged)


def test_an_action_that_is_refused_leaves_no_entry(client, db, make, as_admin):
    squats = make.exercise("Squats")

    # A threshold out of order is refused, so nothing changed and nothing is logged.
    response = client.patch(
        f"{ADMIN}/exercises/{squats.id}", json={"checks": [{**CHECK, "info": 50}]}, headers=as_admin
    )

    assert response.status_code == 422
    assert entries(db, "exercise_template.updated") == []


# --- Append-only ---------------------------------------------------------------


@contextlib.contextmanager
def acting_as(account: Account | None) -> Iterator[Session]:
    """A database session as [account], the way a request of theirs has one."""
    with Session(get_engine()) as session:
        if account is not None:
            rls.set_user(session, account)
        yield session


@pytest.fixture
def logged(client, db, make, as_admin) -> AuditLog:
    """One real entry: an admin's role change."""
    omar = make.account(Role.physiotherapist)
    client.post(f"{ADMIN}/users/{omar.id}/role", json={"role": "admin"}, headers=as_admin)
    return entries(db, "account.role_changed")[0]


@pytest.mark.parametrize("role", [Role.admin, Role.physiotherapist, Role.patient, None])
@pytest.mark.parametrize(
    "statement",
    [
        "UPDATE audit_log SET detail = '{}' WHERE id = :id",
        "UPDATE audit_log SET actor_id = NULL WHERE id = :id",
        "UPDATE audit_log SET created_at = now() WHERE id = :id",
        "DELETE FROM audit_log WHERE id = :id",
    ],
)
def test_no_role_can_change_or_delete_an_entry(db, make, logged, role, statement):
    someone = make.account(role) if role else None

    with acting_as(someone) as session, pytest.raises(DBAPIError, match="append-only"):
        session.execute(text(statement), {"id": logged.id})

    [entry] = entries(db, "account.role_changed")
    assert entry.detail == {"from": "physiotherapist", "to": "admin"}
    assert entry.actor_id is not None


def test_the_system_itself_cannot_change_or_delete_an_entry(db, logged):
    for statement in ("UPDATE audit_log SET action = 'nothing.happened'", "DELETE FROM audit_log"):
        with pytest.raises(DBAPIError, match="append-only"):
            db.execute(text(statement))
        db.rollback()

    assert entries(db, "account.role_changed") != []


def test_the_api_offers_no_way_to_edit_or_delete_the_log(client, logged, as_admin):
    for method in ("put", "patch", "delete", "post"):
        whole = getattr(client, method)(f"{ADMIN}/audit-log", headers=as_admin)
        one = getattr(client, method)(f"{ADMIN}/audit-log/{logged.id}", headers=as_admin)
        assert whole.status_code == 405
        assert one.status_code in (404, 405)


def test_new_entries_are_still_added_after_the_log_is_locked(client, db, make, as_admin):
    omar = make.account(Role.physiotherapist)

    client.post(f"{ADMIN}/users/{omar.id}/role", json={"role": "admin"}, headers=as_admin)
    client.post(f"{ADMIN}/users/{omar.id}/role", json={"role": "physiotherapist"}, headers=as_admin)

    assert [entry.detail["to"] for entry in entries(db, "account.role_changed")] == [
        "admin",
        "physiotherapist",
    ]


def test_the_admin_reads_the_log_with_who_when_and_what(client, db, make, admin, as_admin, logged):
    listed = client.get(f"{ADMIN}/audit-log", headers=as_admin).json()

    entry = next(item for item in listed if item["action"] == "account.role_changed")
    assert entry["actor_id"] == str(admin.id)
    assert entry["created_at"]
    assert entry["detail"] == {"from": "physiotherapist", "to": "admin"}
