"""US 8.1 - row-level data isolation: what the database itself allows, whatever
the application asks for.

These tests go round the API on purpose. They open a database session as one
person and query another person's rows directly, the way a bug in an
endpoint would.
"""

import contextlib
import uuid
from collections.abc import Iterator

import pytest
from sqlalchemy import func, select, text, update
from sqlalchemy.exc import DBAPIError
from sqlalchemy.orm import Session

from app import clock, disclaimer, pose, rls, session_service
from app.db import Base, get_engine
from app.models import (
    Account,
    ConsentRecord,
    ExercisePlan,
    ExerciseSession,
    Notification,
    PatientAssignment,
    PlanExercise,
    ReminderSettings,
    Role,
    SessionRepetition,
)
from tests.conftest import bearer, sign_in

# Tables that hold a patient's data: each must be protected by a policy.
PROTECTED = {
    "consents",
    "exercise_plans",
    "exercise_sessions",
    "notifications",
    "patient_assignments",
    "plan_exercises",
    "prescription_edits",
    "reminder_settings",
    "session_reminders",
    "session_repetitions",
}
# Tables deliberately left without one, and why.
EXEMPT = {
    "accounts": "needed to work out who is asking, before any identity is known",
    "auth_sessions": "needed to work out who is asking",
    "login_attempts": "counted before sign-in succeeds",
    "invite_codes": "looked up by a person who has no account yet",
    "exercise_templates": "the exercise library, the same for everyone",
    "audit_log": "written by every role; read only through the admin's endpoint",
}
# The clinical tables: what a patient did and was prescribed.
CLINICAL = [ExercisePlan, PlanExercise, ExerciseSession, SessionRepetition]


@contextlib.contextmanager
def acting_as(account: Account | None = None) -> Iterator[Session]:
    """A database session as [account], or as nobody, the way a request has
    one. Whatever it does is rolled back."""
    with Session(get_engine(), expire_on_commit=False) as session:
        if account is not None:
            rls.set_user(session, account)
        yield session
        session.rollback()


def count(session: Session, model, *where) -> int:
    return session.execute(select(func.count()).select_from(model).where(*where)).scalar_one()


class Person:
    """A patient with a plan, an acknowledged advisory, a session with one
    repetition, and a reminder setting: a row in every protected table."""

    def __init__(self, client, make, physio: Account, exercise) -> None:
        self.account = make.patient_of(physio)
        self.headers = bearer(sign_in(client, self.account))
        physio_headers = bearer(sign_in(client, physio))
        created = client.post(
            f"/api/v1/physio/patients/{self.account.id}/plans",
            json={"name": "Plan", "items": [{"exercise_id": str(exercise.id), "sets": 2, "reps": 5}]},
            headers=physio_headers,
        )
        assert created.status_code == 201, created.text
        self.plan_id = uuid.UUID(created.json()["id"])
        item = created.json()["items"][0]["id"]
        consent = client.post(
            "/api/v1/patient/consent",
            json={"version": disclaimer.CURRENT_VERSION, "acknowledged": True},
            headers=self.headers,
        )
        assert consent.status_code == 201, consent.text
        landmarks = pose.required_landmarks(exercise.target_joints, [c["key"] for c in exercise.checks])
        started = client.post(
            "/api/v1/patient/sessions",
            json={
                "plan_exercise_id": item,
                "precheck": {"brightness": 0.6, "held_ms": 1800, "visibility": dict.fromkeys(landmarks, 0.9)},
            },
            headers=self.headers,
        )
        assert started.status_code == 201, started.text
        self.session_id = uuid.UUID(started.json()["id"])
        rep = client.post(
            f"/api/v1/patient/sessions/{self.session_id}/repetitions",
            json={
                "client_key": str(uuid.uuid4()),
                "set_number": 1,
                "rep_number": 1,
                "started_ms": 0,
                "ended_ms": 2000,
                "measures": {c["key"]: 1.0 for c in exercise.checks},
            },
            headers=self.headers,
        )
        assert rep.status_code == 201, rep.text
        saved = client.put(
            "/api/v1/patient/reminders", json={"utc_offset_minutes": 300}, headers=self.headers
        )
        assert saved.status_code == 200, saved.text


class World:
    """Two physiotherapists, each with one patient, and an admin."""

    def __init__(self, client, make) -> None:
        self.sarah = make.account(Role.physiotherapist, full_name="Sarah Malik")
        self.omar = make.account(Role.physiotherapist, full_name="Omar Farooq")
        self.admin = make.account(Role.admin)
        exercise = make.exercise("Squats")
        self.jane = Person(client, make, self.sarah, exercise)
        self.marcus = Person(client, make, self.omar, exercise)


@pytest.fixture
def world(client, make) -> World:
    return World(client, make)


# --- Every table is accounted for -------------------------------------------


def test_every_table_is_either_protected_or_exempt_for_a_stated_reason(db):
    tables = {table.name for table in Base.metadata.sorted_tables}
    secured = set(
        db.execute(
            text(
                "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace "
                "WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity"
            )
        ).scalars()
    )

    # A new table has to be put on one list or the other: there is no way to
    # add patient data that nobody decided how to isolate.
    assert tables == PROTECTED | set(EXEMPT), "a table is on neither list"
    assert secured == PROTECTED
    assert all(reason for reason in EXEMPT.values())


def test_every_protected_table_has_a_policy(db):
    with_policy = set(
        db.execute(text("SELECT DISTINCT tablename FROM pg_policies WHERE schemaname = 'public'")).scalars()
    )

    # Row-level security with no policy would hide everything; a policy on a
    # table without it enabled would do nothing.
    assert with_policy == PROTECTED


def test_requests_run_as_a_role_that_the_policies_apply_to(world):
    with acting_as(world.jane.account) as session:
        role, bypasses = session.execute(
            text(
                "SELECT current_user, "
                "(SELECT rolbypassrls OR rolsuper FROM pg_roles WHERE rolname = current_user)"
            )
        ).one()

    assert role == rls.APP_ROLE
    assert bypasses is False


# --- Who can see what --------------------------------------------------------


def test_a_patient_sees_only_their_own_rows(world):
    with acting_as(world.jane.account) as session:
        for model in CLINICAL:
            assert count(session, model) == 1, model.__tablename__
        assert count(session, ExerciseSession, ExerciseSession.id == world.marcus.session_id) == 0
        assert count(session, ExercisePlan, ExercisePlan.id == world.marcus.plan_id) == 0
        assert count(session, ConsentRecord) == 1
        assert count(session, ReminderSettings) == 1
        assert [a.patient_id for a in session.execute(select(PatientAssignment)).scalars()] == [
            world.jane.account.id
        ]


def test_a_physiotherapist_sees_only_patients_assigned_to_them(world):
    with acting_as(world.sarah) as session:
        for model in CLINICAL:
            assert count(session, model) == 1, model.__tablename__
        assert count(session, ExerciseSession, ExerciseSession.patient_id == world.jane.account.id) == 1
        assert count(session, ExerciseSession, ExerciseSession.patient_id == world.marcus.account.id) == 0
        # Not theirs to read at all: a patient's consent record and settings.
        assert count(session, ConsentRecord) == 0
        assert count(session, ReminderSettings) == 0


def test_an_admin_manages_accounts_but_sees_no_clinical_data(world):
    with acting_as(world.admin) as session:
        for model in CLINICAL:
            assert count(session, model) == 0, model.__tablename__
        # What an admin does need: who is assigned to whom, and the consent
        # records they can retrieve for audit.
        assert count(session, PatientAssignment) == 2
        assert count(session, ConsentRecord) == 2


def test_nobody_signed_in_sees_nothing(world):
    with acting_as() as session:
        for model in [*CLINICAL, ConsentRecord, ReminderSettings, PatientAssignment, Notification]:
            assert count(session, model) == 0, model.__tablename__


def test_the_system_sees_everything_it_has_to_work_on(world, db):
    for model in CLINICAL:
        assert count(db, model) == 2, model.__tablename__


def test_reassignment_moves_what_the_database_shows(world, client):
    admin = bearer(sign_in(client, world.admin))
    moved = client.post(
        f"/api/v1/admin/users/{world.jane.account.id}/reassign",
        json={"physiotherapist_id": str(world.omar.id)},
        headers=admin,
    )
    assert moved.status_code == 200, moved.text

    with acting_as(world.sarah) as session:
        assert count(session, ExerciseSession) == 0
        assert count(session, ExercisePlan) == 0
    with acting_as(world.omar) as session:
        assert count(session, ExerciseSession) == 2
        assert count(session, ExercisePlan) == 2


# --- When the application's own checks are bypassed ---------------------------


def test_another_patients_session_cannot_be_read_by_its_id(world):
    with acting_as(world.jane.account) as session:
        assert session.get(ExerciseSession, world.marcus.session_id) is None
        assert session.get(ExercisePlan, world.marcus.plan_id) is None
        reps = session.execute(
            select(SessionRepetition).where(SessionRepetition.session_id == world.marcus.session_id)
        ).all()
        assert reps == []


def test_a_service_called_without_its_ownership_check_still_leaks_nothing(world, db):
    # An endpoint with a bug: it hands the detail of whatever session it is
    # given, having forgotten to check whose it is.
    someone_elses = db.get(ExerciseSession, world.marcus.session_id)
    assert someone_elses is not None

    with acting_as(world.jane.account) as session:
        detail = session_service.detail(session, someone_elses)

    # The row itself was passed in, but nothing more could be fetched for it.
    assert detail.repetitions == []
    with acting_as(world.marcus.account) as session:
        assert len(session_service.detail(session, someone_elses).repetitions) == 1


def test_another_patients_rows_cannot_be_changed_or_deleted(world, db):
    with acting_as(world.jane.account) as session:
        renamed = session.execute(
            update(ExercisePlan).where(ExercisePlan.id == world.marcus.plan_id).values(name="Hijacked")
        )
        scored = session.execute(
            update(ExerciseSession).where(ExerciseSession.id == world.marcus.session_id).values(form_score=0)
        )
        removed = session.execute(
            text("DELETE FROM session_repetitions WHERE session_id = :id"),
            {"id": world.marcus.session_id},
        )
        session.commit()

    assert (renamed.rowcount, scored.rowcount, removed.rowcount) == (0, 0, 0)
    db.expire_all()
    assert db.get(ExercisePlan, world.marcus.plan_id).name == "Plan"
    assert count(db, SessionRepetition, SessionRepetition.session_id == world.marcus.session_id) == 1


def test_rows_cannot_be_written_into_another_patients_record(world):
    mine = None
    with acting_as(world.jane.account) as session:
        mine = session.get(ExerciseSession, world.jane.session_id)
        with pytest.raises(DBAPIError, match="row-level security"):
            session.execute(
                text(
                    "INSERT INTO session_repetitions (id, session_id, client_key, set_number, rep_number, "
                    "started_ms, ended_ms, measures, tier, feedback, created_at) VALUES "
                    "(:id, :session, :key, 1, 9, 0, 1, '{}', 'ok', '[]', now())"
                ),
                {"id": uuid.uuid4(), "session": world.marcus.session_id, "key": uuid.uuid4()},
            )
    assert mine is not None

    with acting_as(world.jane.account) as session, pytest.raises(DBAPIError, match="row-level security"):
        # Moving one's own session onto someone else is refused as well.
        session.execute(
            update(ExerciseSession)
            .where(ExerciseSession.id == world.jane.session_id)
            .values(patient_id=world.marcus.account.id)
        )


def test_a_patient_cannot_assign_themselves_to_a_physiotherapist(world):
    with acting_as(world.jane.account) as session, pytest.raises(DBAPIError, match="row-level security"):
        session.add(
            PatientAssignment(
                patient_id=world.jane.account.id,
                physiotherapist_id=world.omar.id,
                assigned_at=clock.utcnow(),
            )
        )
        session.flush()

    with acting_as(world.omar) as session:
        # Nor can a physiotherapist take a colleague's patient.
        taken = session.execute(
            update(PatientAssignment)
            .where(PatientAssignment.patient_id == world.jane.account.id)
            .values(physiotherapist_id=world.omar.id)
        )
        assert taken.rowcount == 0


# --- Notifications -----------------------------------------------------------


def test_a_notification_is_read_only_by_the_person_it_is_for(world, db):
    with acting_as(world.jane.account) as session:
        # Anyone may leave a notification for someone else...
        session.add(
            Notification(
                recipient_id=world.sarah.id,
                kind="test",
                title="For Sarah",
                body="Only Sarah may read this.",
                created_at=clock.utcnow(),
            )
        )
        session.commit()
        # ...but cannot read it back, or mark it read for them.
        assert count(session, Notification, Notification.title == "For Sarah") == 0
        marked = session.execute(
            update(Notification).where(Notification.title == "For Sarah").values(read_at=clock.utcnow())
        )
        assert marked.rowcount == 0

    with acting_as(world.sarah) as session:
        assert count(session, Notification, Notification.title == "For Sarah") == 1
    with acting_as(world.omar) as session:
        assert count(session, Notification, Notification.title == "For Sarah") == 0
    db.execute(text("DELETE FROM notifications WHERE title = 'For Sarah'"))
    db.commit()


# --- Nothing carries over ----------------------------------------------------


def test_one_persons_identity_does_not_stay_on_the_connection(world):
    engine = get_engine()
    # Many sessions in a row share a small pool of connections.
    for _ in range(8):
        with acting_as(world.jane.account) as session:
            assert count(session, ExerciseSession) == 1
        with Session(engine) as nobody:
            assert count(nobody, ExerciseSession) == 0
            assert nobody.execute(text("SELECT app_role()")).scalar_one() == "anonymous"


def test_the_identity_is_kept_across_the_commits_of_one_request(world):
    with acting_as(world.jane.account) as session:
        assert count(session, ExerciseSession) == 1
        session.commit()
        # A new transaction on the same session is still Jane's.
        assert count(session, ExerciseSession) == 1
        assert session.execute(text("SELECT app_user_id()")).scalar_one() == world.jane.account.id


def test_stepping_up_to_the_system_is_temporary(world):
    with acting_as(world.jane.account) as session:
        with rls.system(session):
            assert count(session, ExerciseSession) == 2
        assert count(session, ExerciseSession) == 1
        assert rls.current(session) == (str(world.jane.account.id), "patient")
