"""The demo data `python -m app.seed` creates for local development."""

import pytest
from sqlalchemy import select

from app import seed
from app.config import get_settings
from app.models import Account, ExercisePlan, Notification, PlanExercise, Role
from tests.conftest import bearer


@pytest.fixture
def demo(monkeypatch) -> dict[str, str]:
    """Demo account details, as .env would provide them."""
    settings = get_settings()
    values = {
        "seed_admin_email": "admin@demo.test",
        "seed_physio_email": "physio@demo.test",
        "seed_patient_email": "patient@demo.test",
        "seed_admin_password": "Demo-Admin-1",
        "seed_physio_password": "Demo-Physio-1",
        "seed_patient_password": "Demo-Patient-1",
    }
    for name, value in values.items():
        monkeypatch.setattr(settings, name, value)
    return values


def plans(db) -> list[ExercisePlan]:
    db.expire_all()
    return list(db.execute(select(ExercisePlan).order_by(ExercisePlan.created_at)).scalars())


def test_seed_creates_the_three_accounts_and_a_plan_the_patient_can_start(client, db, make, demo):
    make.exercise("Squats")
    make.exercise("Arm Abduction", target_joints=["shoulder", "elbow", "hip"])
    make.exercise("Push-ups")

    seed.main()

    roles = {a.email: a.role for a in db.execute(select(Account)).scalars()}
    assert roles == {
        "admin@demo.test": Role.admin,
        "physio@demo.test": Role.physiotherapist,
        "patient@demo.test": Role.patient,
    }
    signed_in = client.post(
        "/api/v1/auth/login",
        json={"identifier": "patient@demo.test", "password": demo["seed_patient_password"]},
    ).json()
    plan = client.get("/api/v1/patient/plan", headers=bearer(signed_in)).json()
    assert plan["name"] == "Starter plan"
    assert plan["assigned_by"]["id"] == signed_in["physiotherapist"]["id"]
    assert [(i["exercise"]["name"], i["sets"], i["reps"]) for i in plan["items"]] == [
        ("Squats", 3, 10),
        ("Arm Abduction", 2, 10),
    ]
    # Assigned the same way a physiotherapist would: the patient is told.
    assert [n.kind for n in db.execute(select(Notification)).scalars()] == ["plan_assigned"]


def test_running_the_seed_again_changes_nothing(db, make, demo):
    make.exercise("Squats")

    seed.main()
    seed.main()

    assert len(db.execute(select(Account)).all()) == 3
    assert len(plans(db)) == 1
    assert len(db.execute(select(PlanExercise)).all()) == 1


def test_seed_never_replaces_a_plan_somebody_chose(client, db, make, demo):
    make.exercise("Squats")
    lunge = make.exercise("Leg Lunge")
    seed.main()
    physio = client.post(
        "/api/v1/auth/login",
        json={"identifier": "physio@demo.test", "password": demo["seed_physio_password"]},
    ).json()
    patient = db.execute(select(Account).where(Account.role == Role.patient)).scalar_one()
    chosen = client.post(
        f"/api/v1/physio/patients/{patient.id}/plans",
        json={"name": "Chosen by Sarah", "items": [{"exercise_id": str(lunge.id), "sets": 2, "reps": 8}]},
        headers=bearer(physio),
    )
    assert chosen.status_code == 201

    seed.main()

    assert [(p.name, p.archived_at is None) for p in plans(db)] == [
        ("Starter plan", False),
        ("Chosen by Sarah", True),
    ]


def test_seed_without_the_starter_exercises_still_creates_the_accounts(db, make, demo):
    make.exercise("Squats", active=False)

    seed.main()

    assert len(db.execute(select(Account)).all()) == 3
    assert plans(db) == []
