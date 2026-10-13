"""Creates local demo accounts: `python -m app.seed`.

Reads the SEED_* values from .env (see .env.example). Safe to run repeatedly;
existing accounts are left untouched. Refuses to run in production.

The demo patient also gets a starter plan, once, so there is an exercise to
start a session with straight after seeding.

`python -m app.seed --test-patients` also creates five test patients of the
demo physiotherapist, each with every exercise that is switched on, for trying
all the exercises out. They sign in with SEED_TEST_PATIENT_PASSWORD (the demo
patient's password when that is not set).

`python -m app.seed --team` also creates an admin account for each person in
SEED_TEAM_ADMINS, with the password SEED_TEAM_PASSWORD.

Add `--reset-passwords` to set the passwords of team and test accounts that
already exist to the values in .env, for instance after changing them there.
No other account's password is ever touched."""

import re
import sys
import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit, auth_service, clock, plan_service, rls
from app.config import get_settings
from app.db import get_engine
from app.exercise_schemas import PlanCreate, PlanItemIn
from app.models import Account, ExerciseTemplate, PatientAssignment, Role
from app.security import hash_password


def _ensure(db: Session, name: str, email: str | None, password: str | None, role: Role) -> Account | None:
    if not email or not password:
        print(f"  skipped {role.value}: SEED_* email/password not set")
        return None
    email = email.strip().lower()
    existing = db.execute(select(Account).where(Account.email == email)).scalar_one_or_none()
    if existing:
        print(f"  exists  {role.value}: {email}")
        return existing
    account = Account(
        id=uuid.uuid4(),
        full_name=name,
        email=email,
        password_hash=hash_password(password),
        role=role,
        created_at=clock.utcnow(),
    )
    db.add(account)
    db.flush()
    audit.record(
        db,
        "account.seeded",
        target_type="account",
        target_id=account.id,
        detail={"role": role.value},
    )
    print(f"  created {role.value}: {email}")
    return account


# The demo patient's starter plan: exercise name, sets, reps.
_STARTER_PLAN = [("Squats", 3, 10), ("Arm Abduction", 2, 10)]


def _ensure_starter_plan(db: Session, physio: Account, patient: Account) -> None:
    """Assigns the starter plan the same way a physiotherapist would, unless
    the patient has ever had a plan: a plan somebody chose is never replaced."""
    if plan_service.history(db, patient.id):
        print("  exists  plan for the demo patient")
        return
    responsible = auth_service.current_physiotherapist(db, patient.id)
    if not patient.is_active or responsible is None or responsible.id != physio.id:
        print("  skipped starter plan: the demo patient is not with the demo physiotherapist")
        return
    available = {
        template.name: template
        for template in db.execute(select(ExerciseTemplate).where(ExerciseTemplate.is_active)).scalars()
    }
    items = [
        PlanItemIn(exercise_id=available[name].id, sets=sets, reps=reps)
        for name, sets, reps in _STARTER_PLAN
        if name in available
    ]
    if not items:
        print("  skipped starter plan: its exercises are not switched on")
        return
    plan_service.assign(db, physio, patient, PlanCreate(name="Starter plan", items=items), None)
    print(f"  created starter plan for the demo patient ({len(items)} exercises)")


# Test patients: name and email. Each gets every active exercise, starting
# from a different one, so "up next" differs from patient to patient.
TEST_PATIENTS = [
    ("Ali Raza", "ali@physioai.test"),
    ("Sara Ahmed", "sara@physioai.test"),
    ("Bilal Hussain", "bilal@physioai.test"),
    ("Hina Tariq", "hina@physioai.test"),
    ("Usman Sheikh", "usman@physioai.test"),
]
# Short, so a whole exercise can be tried in a minute or two.
TEST_SETS, TEST_REPS = 2, 5
TEST_PLAN_NAME = "All exercises"


def _link(db: Session, physio: Account, patient: Account) -> None:
    """Puts the patient with the physiotherapist unless they are with someone."""
    linked = db.execute(
        select(PatientAssignment).where(
            PatientAssignment.patient_id == patient.id, PatientAssignment.ended_at.is_(None)
        )
    ).scalar_one_or_none()
    if linked is None:
        db.add(
            PatientAssignment(patient_id=patient.id, physiotherapist_id=physio.id, assigned_at=clock.utcnow())
        )


def _reset_password(db: Session, account: Account, password: str | None) -> None:
    """Sets a team or test account's password to the one in .env."""
    if not password:
        return
    account.password_hash = hash_password(password)
    audit.record(
        db,
        "account.password_reset",
        target_type="account",
        target_id=account.id,
        detail={"role": account.role.value, "by": "seed"},
    )
    print(f"  reset   password of {account.email}")


def team_admins(listed: str) -> list[tuple[str, str]]:
    """The people in SEED_TEAM_ADMINS as (name, email). An entry that is not
    "Full Name <email>" is reported and left out rather than guessed at."""
    people = []
    for entry in (part.strip() for part in listed.split(",")):
        if not entry:
            continue
        match = re.fullmatch(r"(.+?)\s*<\s*([^<>\s]+@[^<>\s]+)\s*>", entry)
        if match is None:
            print(f'  skipped team admin "{entry}": write it as Full Name <email>')
            continue
        people.append((match.group(1).strip(), match.group(2).lower()))
    return people


def ensure_team_admins(db: Session, listed: str, password: str | None, *, reset: bool) -> None:
    """Creates an admin account for each person on the team's list."""
    for name, email in team_admins(listed):
        existed = db.execute(select(Account).where(Account.email == email)).scalar_one_or_none()
        account = _ensure(db, name, email, password, Role.admin)
        if account is not None and existed is not None and reset and account.role == Role.admin:
            _reset_password(db, account, password)
    db.commit()


def ensure_test_patients(db: Session, physio: Account, password: str | None, *, reset: bool = False) -> None:
    """Creates the test patients with a plan of every exercise that is
    switched on. Like the rest of the seed: what exists is left as it is, and
    a plan somebody chose is never replaced."""
    templates = list(
        db.execute(
            select(ExerciseTemplate).where(ExerciseTemplate.is_active).order_by(ExerciseTemplate.name)
        ).scalars()
    )
    for number, (name, email) in enumerate(TEST_PATIENTS):
        existed = db.execute(select(Account).where(Account.email == email)).scalar_one_or_none()
        patient = _ensure(db, name, email, password, Role.patient)
        if patient is None:
            continue
        if existed is not None and reset and patient.role == Role.patient:
            _reset_password(db, patient, password)
        _link(db, physio, patient)
        db.commit()
        if plan_service.history(db, patient.id):
            print(f"  exists  plan for {email}")
            continue
        responsible = auth_service.current_physiotherapist(db, patient.id)
        if not patient.is_active or responsible is None or responsible.id != physio.id or not templates:
            print(f"  skipped plan for {email}")
            continue
        start = number % len(templates)
        items = [
            PlanItemIn(exercise_id=template.id, sets=TEST_SETS, reps=TEST_REPS)
            for template in templates[start:] + templates[:start]
        ]
        plan_service.assign(db, physio, patient, PlanCreate(name=TEST_PLAN_NAME, items=items), None)
        print(f"  created plan for {email} ({len(items)} exercises, starting with {templates[start].name})")


def main(argv: list[str] | None = None) -> None:
    arguments = sys.argv[1:] if argv is None else argv
    settings = get_settings()
    if settings.is_production:
        raise SystemExit("Refusing to seed demo accounts in production.")
    with rls.as_system(Session(get_engine())) as db:
        _ensure(
            db, settings.seed_admin_name, settings.seed_admin_email, settings.seed_admin_password, Role.admin
        )
        physio = _ensure(
            db,
            settings.seed_physio_name,
            settings.seed_physio_email,
            settings.seed_physio_password,
            Role.physiotherapist,
        )
        patient = _ensure(
            db,
            settings.seed_patient_name,
            settings.seed_patient_email,
            settings.seed_patient_password,
            Role.patient,
        )
        if physio and patient:
            _link(db, physio, patient)
        db.commit()
        if physio and patient:
            _ensure_starter_plan(db, physio, patient)
        reset = "--reset-passwords" in arguments
        if "--team" in arguments:
            ensure_team_admins(db, settings.seed_team_admins, settings.seed_team_password, reset=reset)
        if "--test-patients" in arguments:
            if physio is None:
                print("  skipped test patients: there is no demo physiotherapist")
            else:
                ensure_test_patients(
                    db,
                    physio,
                    settings.seed_test_patient_password or settings.seed_patient_password,
                    reset=reset,
                )
    print("Seed complete.")


if __name__ == "__main__":
    main()
