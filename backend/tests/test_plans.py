"""US 2.1 - Exercise plan creation and assignment (and the 2.3 / 7.2 rules it relies on)."""

import pytest
from sqlalchemy import func, select

from app.models import AuditLog, ExercisePlan, PlanExercise, Role
from tests.conftest import bearer, sign_in

MISSING = "00000000-0000-0000-0000-000000000000"


def plans_url(patient) -> str:
    return f"/api/v1/physio/patients/{patient.id}/plans"


def item(exercise, **overrides) -> dict:
    return {"exercise_id": str(exercise.id), "sets": 3, "reps": 12, **overrides}


def count(db, model) -> int:
    return db.execute(select(func.count()).select_from(model)).scalar()


@pytest.fixture
def setting(client, make):
    """A physiotherapist with one patient and two active exercises."""

    class Setting:
        physio = make.account(Role.physiotherapist, full_name="Dr. Sarah Malik")
        patient = make.patient_of(physio)
        squats = make.exercise("Squats")
        lunge = make.exercise("Leg Lunge")

    Setting.physio_headers = bearer(sign_in(client, Setting.physio))
    Setting.patient_headers = bearer(sign_in(client, Setting.patient))
    return Setting


def test_patient_sees_the_plan_their_physiotherapist_assigned(client, db, setting):
    body = {
        "name": "Knee rehabilitation plan",
        "items": [
            item(setting.squats, sets=2, reps=12, rest_seconds=45, difficulty="easy", note=" Go slowly. "),
            item(setting.lunge, sets=2, reps=10),
        ],
    }

    assigned = client.post(plans_url(setting.patient), json=body, headers=setting.physio_headers)

    assert assigned.status_code == 201, assigned.text
    plan = client.get("/api/v1/patient/plan", headers=setting.patient_headers).json()
    assert plan["id"] == assigned.json()["id"]
    assert plan["name"] == "Knee rehabilitation plan" and plan["is_active"] is True
    assert plan["assigned_by"]["full_name"] == "Dr. Sarah Malik"
    assert [(i["exercise"]["name"], i["position"]) for i in plan["items"]] == [
        ("Squats", 1),
        ("Leg Lunge", 2),
    ]
    first = plan["items"][0]
    assert (first["sets"], first["reps"], first["rest_seconds"], first["difficulty"]) == (2, 12, 45, "easy")
    assert first["note"] == "Go slowly."
    assert plan["items"][1]["rest_seconds"] == 60 and plan["items"][1]["difficulty"] == "medium"
    assert plan["has_inactive_exercise"] is False

    entry = db.execute(select(AuditLog).where(AuditLog.action == "plan.assigned")).scalar_one()
    assert entry.detail["patient_id"] == str(setting.patient.id)
    assert entry.detail["archived_plan_id"] is None


def test_patient_without_a_plan_gets_none(client, setting):
    response = client.get("/api/v1/patient/plan", headers=setting.patient_headers)

    assert response.status_code == 200 and response.json() is None


def test_a_plan_cannot_use_an_exercise_that_is_not_active(client, db, make, setting):
    retired = make.exercise("Wall Sit", active=False)

    response = client.post(
        plans_url(setting.patient),
        json={"items": [item(setting.squats), item(retired)]},
        headers=setting.physio_headers,
    )

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "exercise_unavailable"
    assert response.json()["detail"]["exercise_ids"] == [str(retired.id)]
    assert count(db, ExercisePlan) == 0 and count(db, PlanExercise) == 0


def test_a_plan_cannot_use_an_exercise_that_does_not_exist(client, db, setting):
    response = client.post(
        plans_url(setting.patient),
        json={"items": [{"exercise_id": MISSING, "sets": 3, "reps": 10}]},
        headers=setting.physio_headers,
    )

    assert response.status_code == 409
    assert count(db, ExercisePlan) == 0


def test_assigning_a_new_plan_archives_the_old_one_without_changing_it(client, db, setting, time):
    first = client.post(
        plans_url(setting.patient),
        json={"name": "Week 1", "items": [item(setting.squats, sets=3)]},
        headers=setting.physio_headers,
    ).json()
    time.advance(days=7)

    second = client.post(
        plans_url(setting.patient),
        json={"name": "Week 2", "items": [item(setting.squats, sets=2), item(setting.lunge)]},
        headers=bearer(sign_in(client, setting.physio)),
    )

    assert second.status_code == 201, second.text
    headers = bearer(sign_in(client, setting.physio))
    history = client.get(plans_url(setting.patient), headers=headers).json()
    assert [(p["name"], p["is_active"]) for p in history] == [("Week 2", True), ("Week 1", False)]
    archived = history[1]
    assert archived["id"] == first["id"]
    assert archived["archived_at"] == second.json()["created_at"]
    assert [(i["exercise"]["name"], i["sets"]) for i in archived["items"]] == [("Squats", 3)]
    current = client.get("/api/v1/patient/plan", headers=bearer(sign_in(client, setting.patient))).json()
    assert current["name"] == "Week 2"
    entries = db.execute(select(AuditLog).where(AuditLog.action == "plan.assigned")).scalars().all()
    assert sorted(str(e.detail["archived_plan_id"]) for e in entries) == sorted(["None", first["id"]])


def test_deactivating_an_exercise_keeps_existing_plans_intact_and_flags_them(client, make, setting):
    client.post(
        plans_url(setting.patient),
        json={"items": [item(setting.squats), item(setting.lunge)]},
        headers=setting.physio_headers,
    )
    admin = bearer(sign_in(client, make.account(Role.admin)))

    client.post(f"/api/v1/admin/exercises/{setting.lunge.id}/deactivate", headers=admin)

    plan = client.get(plans_url(setting.patient), headers=setting.physio_headers).json()[0]
    assert plan["has_inactive_exercise"] is True
    assert [(i["exercise"]["name"], i["exercise"]["is_active"]) for i in plan["items"]] == [
        ("Squats", True),
        ("Leg Lunge", False),
    ]
    # The patient still has their full plan.
    assert len(client.get("/api/v1/patient/plan", headers=setting.patient_headers).json()["items"]) == 2


@pytest.mark.parametrize(
    "items",
    [
        [],
        [{"sets": 0, "reps": 10}],
        [{"sets": 3, "reps": 0}],
        [{"sets": 11, "reps": 10}],
        [{"sets": 3, "reps": 10, "rest_seconds": -1}],
        [{"sets": 3, "reps": 10, "difficulty": "extreme"}],
        [{"sets": 3, "reps": 10}, {"sets": 2, "reps": 8}],  # same exercise twice
    ],
)
def test_invalid_prescriptions_are_rejected(client, db, setting, items):
    body = {"items": [{"exercise_id": str(setting.squats.id), **i} for i in items]}

    response = client.post(plans_url(setting.patient), json=body, headers=setting.physio_headers)

    assert response.status_code == 422
    assert count(db, ExercisePlan) == 0


def test_physiotherapist_cannot_assign_or_read_plans_for_a_colleagues_patient(client, db, make, setting):
    other = make.account(Role.physiotherapist)
    their_patient = make.patient_of(other)
    client.post(
        plans_url(their_patient),
        json={"items": [item(setting.squats)]},
        headers=bearer(sign_in(client, other)),
    )

    assign = client.post(
        plans_url(their_patient), json={"items": [item(setting.squats)]}, headers=setting.physio_headers
    )
    read = client.get(plans_url(their_patient), headers=setting.physio_headers)
    unknown = client.get(f"/api/v1/physio/patients/{MISSING}/plans", headers=setting.physio_headers)

    assert assign.status_code == 404 and read.status_code == 404
    assert read.json() == unknown.json()
    assert count(db, ExercisePlan) == 1


def test_each_patient_only_sees_their_own_plan(client, make, setting):
    other_patient = make.patient_of(setting.physio)
    client.post(
        plans_url(setting.patient), json={"items": [item(setting.squats)]}, headers=setting.physio_headers
    )

    theirs = client.get("/api/v1/patient/plan", headers=bearer(sign_in(client, other_patient)))

    assert theirs.json() is None
