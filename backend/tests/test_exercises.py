"""US 7.1 exercise templates, 7.2 active exercise control, 2.3 library selection."""

import pytest
from sqlalchemy import select

from app.models import AuditLog, ExerciseTemplate, Role
from tests.conftest import CHECK, SEEDED_EXERCISES, bearer, sign_in

ADMIN = "/api/v1/admin/exercises"
PICKER = "/api/v1/physio/exercises"


def template(**overrides) -> dict:
    return {
        "name": "Wall Sit",
        "domain": "Knee rehabilitation",
        "body_area": "knee",
        "primary_targets": "Quadriceps",
        "target_joints": ["Hip", " knee ", "ankle"],
        "movement_pattern": "Back against a wall, slide down until the knees are at a right angle and hold.",
        "instructions": "Lean against a wall and slide down until your knees are bent, then hold.",
        "checks": [CHECK],
        **overrides,
    }


@pytest.fixture
def admin(client, make):
    return bearer(sign_in(client, make.account(Role.admin)))


@pytest.fixture
def physio(client, make):
    return bearer(sign_in(client, make.account(Role.physiotherapist)))


def test_migrations_add_the_five_supported_exercises():
    assert SEEDED_EXERCISES == ["Arm Abduction", "Leg Abduction", "Leg Lunge", "Push-ups", "Squats"]


def test_admin_creates_a_template_with_its_profile_and_thresholds(client, db, admin):
    response = client.post(ADMIN, json=template(), headers=admin)

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["slug"] == "wall-sit" and body["version"] == 1
    assert body["target_joints"] == ["hip", "knee", "ankle"]
    assert body["checks"][0]["red"] == 15
    entry = db.execute(select(AuditLog).where(AuditLog.action == "exercise_template.created")).scalar_one()
    assert entry.target_id == body["id"]


def test_a_new_exercise_starts_switched_off_until_an_admin_turns_it_on(client, admin, physio):
    created = client.post(ADMIN, json=template(), headers=admin).json()

    assert created["is_active"] is False
    assert client.get(PICKER, headers=physio).json() == []

    client.post(f"{ADMIN}/{created['id']}/activate", headers=admin)
    assert [e["name"] for e in client.get(PICKER, headers=physio).json()] == ["Wall Sit"]


@pytest.mark.parametrize(
    "overrides",
    [
        {"checks": []},
        {"checks": [{**CHECK, "amber": 4}]},  # AMBER below INFO
        {"checks": [{**CHECK, "red": 10}]},  # RED not above AMBER
        {"checks": [CHECK, CHECK]},  # same key twice
        {"checks": [{**CHECK, "corrective_message": ""}]},
        {"target_joints": []},
        {"target_joints": ["  "]},
        {"movement_pattern": "short"},
    ],
)
def test_incomplete_or_inconsistent_templates_are_rejected(client, db, admin, overrides):
    response = client.post(ADMIN, json=template(**overrides), headers=admin)

    assert response.status_code == 422
    assert db.execute(select(ExerciseTemplate)).first() is None


def test_a_check_may_leave_red_empty_so_it_never_pauses_a_session(client, admin):
    depth = {**CHECK, "key": "depth", "label": "Depth", "red": None}

    response = client.post(ADMIN, json=template(checks=[CHECK, depth]), headers=admin)

    assert response.status_code == 201
    assert [c["red"] for c in response.json()["checks"]] == [15, None]


def test_two_exercises_cannot_share_a_name(client, admin):
    assert client.post(ADMIN, json=template(), headers=admin).status_code == 201

    duplicate = client.post(ADMIN, json=template(name="wall  sit"), headers=admin)

    assert duplicate.status_code == 409
    assert duplicate.json()["detail"]["code"] == "exercise_exists"


def test_editing_thresholds_makes_a_new_version_and_records_the_old_values(client, db, make, admin):
    squats = make.exercise("Squats")
    stricter = {**CHECK, "amber": 8, "red": 12}

    response = client.patch(f"{ADMIN}/{squats.id}", json={"checks": [stricter]}, headers=admin)

    assert response.status_code == 200, response.text
    assert response.json()["version"] == 2
    assert response.json()["checks"][0]["red"] == 12
    assert response.json()["name"] == "Squats"  # fields that were not sent are untouched
    entry = db.execute(select(AuditLog).where(AuditLog.action == "exercise_template.updated")).scalar_one()
    assert entry.detail["version"] == 2
    assert entry.detail["changed"]["checks"]["from"][0]["red"] == 15
    assert entry.detail["changed"]["checks"]["to"][0]["red"] == 12


def test_saving_without_changes_does_not_create_a_version(client, db, make, admin):
    squats = make.exercise("Squats")

    response = client.patch(f"{ADMIN}/{squats.id}", json={"name": "Squats"}, headers=admin)

    assert response.json()["version"] == 1
    assert db.execute(select(AuditLog).where(AuditLog.action == "exercise_template.updated")).first() is None


def test_an_edit_with_bad_thresholds_changes_nothing(client, db, make, admin):
    squats = make.exercise("Squats")

    response = client.patch(f"{ADMIN}/{squats.id}", json={"checks": [{**CHECK, "info": 20}]}, headers=admin)

    assert response.status_code == 422
    db.expire_all()
    assert db.get(ExerciseTemplate, squats.id).version == 1


def test_picker_lists_only_active_exercises_with_what_a_physiotherapist_needs(client, make, physio):
    make.exercise("Squats")
    make.exercise("Leg Lunge", primary_targets="Quadriceps, hip stabilisers")
    make.exercise("Wall Sit", active=False)

    listed = client.get(PICKER, headers=physio).json()

    assert [e["name"] for e in listed] == ["Leg Lunge", "Squats"]
    assert listed[0]["primary_targets"] == "Quadriceps, hip stabilisers"
    assert listed[0]["target_joints"] == ["hip", "knee", "ankle"]
    assert "checks" not in listed[0]  # thresholds are for admins


def test_deactivating_removes_an_exercise_from_the_picker_at_once(client, db, make, admin, physio):
    squats = make.exercise("Squats")

    response = client.post(f"{ADMIN}/{squats.id}/deactivate", headers=admin)

    assert response.status_code == 200 and response.json()["is_active"] is False
    assert client.get(PICKER, headers=physio).json() == []
    # Still in the library for admins, and nothing was deleted.
    assert [e["name"] for e in client.get(ADMIN, headers=admin).json()] == ["Squats"]
    assert db.execute(select(AuditLog).where(AuditLog.action == "exercise_template.deactivated")).scalar_one()

    client.post(f"{ADMIN}/{squats.id}/activate", headers=admin)
    assert [e["name"] for e in client.get(PICKER, headers=physio).json()] == ["Squats"]


def test_repeating_a_deactivation_is_harmless_and_logged_once(client, db, make, admin):
    squats = make.exercise("Squats")

    client.post(f"{ADMIN}/{squats.id}/deactivate", headers=admin)
    again = client.post(f"{ADMIN}/{squats.id}/deactivate", headers=admin)

    assert again.status_code == 200
    logged = db.execute(select(AuditLog).where(AuditLog.action == "exercise_template.deactivated")).all()
    assert len(logged) == 1


def test_unknown_exercise_is_not_found(client, admin):
    missing = "00000000-0000-0000-0000-000000000000"

    assert client.patch(f"{ADMIN}/{missing}", json={"name": "Anything"}, headers=admin).status_code == 404
    assert client.post(f"{ADMIN}/{missing}/deactivate", headers=admin).status_code == 404
