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


# --- Test patients (python -m app.seed --test-patients) ------------------------


def test_test_patients_are_only_created_when_asked_for(db, make, demo):
    make.exercise("Squats")

    seed.main([])

    assert len(db.execute(select(Account)).all()) == 3


def test_each_test_patient_gets_every_exercise_that_is_switched_on(client, db, make, demo):
    for name in ("Arm Abduction", "Leg Lunge", "Squats"):
        make.exercise(name)
    make.exercise("Wall Sit", active=False)

    seed.main(["--test-patients"])

    emails = [email for _, email in seed.TEST_PATIENTS]
    accounts = {a.email: a for a in db.execute(select(Account)).scalars()}
    assert set(emails) <= set(accounts)
    assert len(accounts) == 3 + len(emails)
    first_exercises = []
    for email in emails:
        # They sign in with the demo patient's password and see their plan.
        signed_in = client.post(
            "/api/v1/auth/login",
            json={"identifier": email, "password": demo["seed_patient_password"]},
        )
        assert signed_in.status_code == 200, signed_in.text
        assert signed_in.json()["physiotherapist"]["full_name"] == get_settings().seed_physio_name
        plan = client.get("/api/v1/patient/plan", headers=bearer(signed_in.json())).json()
        assert plan["name"] == seed.TEST_PLAN_NAME
        names = [item["exercise"]["name"] for item in plan["items"]]
        assert sorted(names) == ["Arm Abduction", "Leg Lunge", "Squats"]
        assert {(item["sets"], item["reps"]) for item in plan["items"]} == {(seed.TEST_SETS, seed.TEST_REPS)}
        first_exercises.append(names[0])
    # Each starts from a different exercise, in turn.
    assert first_exercises[:3] == ["Arm Abduction", "Leg Lunge", "Squats"]


def test_creating_the_test_patients_again_changes_nothing(db, make, demo):
    make.exercise("Squats")

    seed.main(["--test-patients"])
    seed.main(["--test-patients"])

    assert len(db.execute(select(Account)).all()) == 3 + len(seed.TEST_PATIENTS)
    assert len(plans(db)) == 1 + len(seed.TEST_PATIENTS)


# --- The team's admin accounts (python -m app.seed --team) ---------------------


@pytest.fixture
def team(monkeypatch, demo) -> list[str]:
    settings = get_settings()
    monkeypatch.setattr(
        settings,
        "seed_team_admins",
        "Asma Siddique <Asma@Team.Test>, Dure Sameen<dure@team.test>,  , not an address",
    )
    monkeypatch.setattr(settings, "seed_team_password", "Team-Pass-1")
    monkeypatch.setattr(settings, "seed_test_patient_password", "Easy-Pass-1")
    return ["asma@team.test", "dure@team.test"]


def can_sign_in(client, email: str, password: str, role: str) -> bool:
    response = client.post(
        "/api/v1/auth/login", json={"identifier": email, "password": password, "role": role}
    )
    return response.status_code == 200


def test_the_team_gets_an_admin_account_each(client, db, make, team):
    seed.main(["--team"])

    accounts = {a.email: a for a in db.execute(select(Account)).scalars()}
    # The two people named properly; the entry that is not an address is left out.
    assert len(accounts) == 3 + 2
    for email in team:
        assert accounts[email].role == Role.admin
        assert can_sign_in(client, email, "Team-Pass-1", "admin")
    assert accounts["asma@team.test"].full_name == "Asma Siddique"


def test_team_admins_are_only_created_when_asked_for(db, make, team):
    seed.main([])

    assert len(db.execute(select(Account)).all()) == 3


def test_test_patients_use_their_own_password_when_one_is_set(client, db, make, team):
    make.exercise("Squats")

    seed.main(["--test-patients"])

    email = seed.TEST_PATIENTS[0][1]
    assert can_sign_in(client, email, "Easy-Pass-1", "patient")
    assert not can_sign_in(client, email, "Demo-Patient-1", "patient")


def test_passwords_of_team_and_test_accounts_can_be_reset_from_the_settings(
    client, db, make, team, monkeypatch
):
    make.exercise("Squats")
    seed.main(["--team", "--test-patients"])
    settings = get_settings()
    monkeypatch.setattr(settings, "seed_team_password", "Team-Pass-2")
    monkeypatch.setattr(settings, "seed_test_patient_password", "Easy-Pass-2")
    patient = seed.TEST_PATIENTS[0][1]

    # Without being asked to, the seed leaves existing passwords alone.
    seed.main(["--team", "--test-patients"])
    assert can_sign_in(client, team[0], "Team-Pass-1", "admin")

    seed.main(["--team", "--test-patients", "--reset-passwords"])

    assert can_sign_in(client, team[0], "Team-Pass-2", "admin")
    assert can_sign_in(client, patient, "Easy-Pass-2", "patient")
    assert not can_sign_in(client, team[0], "Team-Pass-1", "admin")
    # The demo accounts' passwords are never touched by a reset.
    assert can_sign_in(client, "admin@demo.test", "Demo-Admin-1", "admin")
    assert can_sign_in(client, "patient@demo.test", "Demo-Patient-1", "patient")
