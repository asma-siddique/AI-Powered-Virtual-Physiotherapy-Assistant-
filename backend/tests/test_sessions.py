"""US 3.1 - Camera pre-check and session initialization."""

import uuid

import pytest
from sqlalchemy import select

from app import disclaimer, pose
from app.models import AuditLog, ExerciseSession, Role
from tests.conftest import bearer, sign_in

NOBODY = "00000000-0000-0000-0000-000000000000"
SESSIONS = "/api/v1/patient/sessions"
LEGS = [
    "left_shoulder",
    "right_shoulder",
    "left_hip",
    "right_hip",
    "left_knee",
    "right_knee",
    "left_ankle",
    "right_ankle",
]


def good_setup(**changes) -> dict:
    """A camera check that passes for a hip, knee and ankle exercise."""
    evidence = {
        "brightness": 0.55,
        "held_ms": 1800,
        "visibility": dict.fromkeys(LEGS, 0.93),
    }
    evidence.update(changes)
    return evidence


class Case:
    """A patient who has acknowledged the advisory and has Squats in their plan."""

    def __init__(self, client, make, *, consent: bool = True, exercise: str = "Squats") -> None:
        self.client = client
        self.make = make
        self.physio = make.account(Role.physiotherapist, full_name="Sarah Malik")
        self.physio_headers = bearer(sign_in(client, self.physio))
        self.patient = make.patient_of(self.physio)
        self.headers = bearer(sign_in(client, self.patient))
        self.squats = make.exercise(exercise)  # hip, knee, ankle
        self.plan = self.assign("Week 1")
        if consent:
            self.acknowledge()

    def acknowledge(self) -> None:
        response = self.client.post(
            "/api/v1/patient/consent",
            json={"version": disclaimer.CURRENT_VERSION, "acknowledged": True},
            headers=self.headers,
        )
        assert response.status_code == 201, response.text

    def assign(self, name: str, exercise=None) -> dict:
        response = self.client.post(
            f"/api/v1/physio/patients/{self.patient.id}/plans",
            json={
                "name": name,
                "items": [{"exercise_id": str((exercise or self.squats).id), "sets": 3, "reps": 12}],
            },
            headers=self.physio_headers,
        )
        assert response.status_code == 201, response.text
        return response.json()

    @property
    def item_id(self) -> str:
        return self.plan["items"][0]["id"]

    def requirements(self, item: str | None = None, headers: dict | None = None):
        return self.client.get(
            f"/api/v1/patient/plan/items/{item or self.item_id}/precheck", headers=headers or self.headers
        )

    def start(self, evidence: dict | None = None, item: str | None = None, headers: dict | None = None):
        return self.client.post(
            SESSIONS,
            json={"plan_exercise_id": item or self.item_id, "precheck": evidence or good_setup()},
            headers=headers or self.headers,
        )


@pytest.fixture
def case(client, make) -> Case:
    return Case(client, make)


def sessions(db) -> list[ExerciseSession]:
    db.expire_all()
    return list(db.execute(select(ExerciseSession).order_by(ExerciseSession.started_at)).scalars())


# --- What the camera has to show ---------------------------------------------


def test_requirements_follow_the_exercises_own_target_joints(client, make, case):
    legs = case.requirements().json()

    assert legs["exercise"]["name"] == "Squats"
    assert legs["required_landmarks"] == LEGS
    assert (legs["sets"], legs["reps"], legs["difficulty"]) == (3, 12, "medium")
    assert legs["min_visibility"] == pose.MIN_VISIBILITY
    assert legs["min_brightness"] == pose.MIN_BRIGHTNESS
    assert legs["hold_ms"] == pose.HOLD_MS

    # An arm exercise asks for arms, not legs: nothing generic about the set.
    arms = make.exercise("Arm Raise", target_joints=["shoulder", "elbow", "wrist"])
    case.plan = case.assign("Week 2", arms)
    assert case.requirements().json()["required_landmarks"] == [
        "left_shoulder",
        "right_shoulder",
        "left_elbow",
        "right_elbow",
        "left_wrist",
        "right_wrist",
        "left_hip",
        "right_hip",
    ]


def test_every_tracked_landmark_has_a_place_in_the_pose_models_33():
    assert len(pose.LANDMARKS) == 33 and len(set(pose.LANDMARKS)) == 33
    for names in pose.JOINT_LANDMARKS.values():
        assert set(names) <= set(pose.LANDMARKS)
    # A joint name from an older template adds nothing, but the trunk stays.
    assert pose.required_landmarks(["spine"]) == ["left_shoulder", "right_shoulder", "left_hip", "right_hip"]


def test_admin_can_only_name_joints_the_camera_check_understands(client, make):
    headers = bearer(sign_in(client, make.account(Role.admin)))
    exercise = make.exercise("Squats")

    response = client.patch(
        f"/api/v1/admin/exercises/{exercise.id}",
        json={"target_joints": ["Knee", "spine"]},
        headers=headers,
    )
    accepted = client.patch(
        f"/api/v1/admin/exercises/{exercise.id}",
        json={"target_joints": [" Knee ", "ankle", "knee"]},
        headers=headers,
    )

    assert response.status_code == 422
    assert "shoulder, elbow, wrist, hip, knee, ankle" in response.text
    assert accepted.status_code == 200 and accepted.json()["target_joints"] == ["knee", "ankle"]


# --- Starting a session -------------------------------------------------------


def test_a_session_starts_once_the_camera_check_passes(client, db, case):
    response = case.start()

    assert response.status_code == 201, response.text
    body = response.json()
    assert body["status"] == "active" and body["ended_at"] is None
    assert body["exercise"]["name"] == "Squats"
    assert (body["sets"], body["reps"], body["rest_seconds"], body["difficulty"]) == (3, 12, 60, "medium")
    assert (body["prescription_revision"], body["template_version"]) == (1, 1)
    assert body["required_landmarks"] == LEGS
    stored = sessions(db)[0]
    assert stored.patient_id == case.patient.id and str(stored.plan_exercise_id) == case.item_id
    # The evidence and the thresholds it was judged against are kept with it.
    assert stored.precheck["brightness"] == 0.55 and stored.precheck["held_ms"] == 1800
    assert stored.precheck["visibility"] == dict.fromkeys(LEGS, 0.93)
    assert stored.precheck["min_visibility"] == pose.MIN_VISIBILITY
    entry = db.execute(select(AuditLog).where(AuditLog.action == "session.started")).scalar_one()
    assert entry.actor_id == case.patient.id and entry.target_id == body["id"]
    assert client.get(f"{SESSIONS}/{body['id']}", headers=case.headers).json() == body


@pytest.mark.parametrize(
    ("changes", "problems"),
    [
        ({"brightness": 0.1}, ["lighting"]),
        ({"held_ms": 400}, ["steady"]),
        (
            {"visibility": dict.fromkeys(LEGS, 0.93) | {"left_ankle": 0.2, "right_ankle": 0.59}},
            ["landmark:left_ankle", "landmark:right_ankle"],
        ),
        (
            {"visibility": {name: 0.93 for name in LEGS if "knee" not in name}},
            ["landmark:left_knee", "landmark:right_knee"],
        ),
        ({"visibility": {}}, [f"landmark:{name}" for name in LEGS]),
        (
            {"brightness": 0.0, "held_ms": 0, "visibility": dict.fromkeys(LEGS, 0.93) | {"left_hip": 0.0}},
            ["lighting", "landmark:left_hip", "steady"],
        ),
    ],
)
def test_no_session_exists_until_the_check_really_passes(client, db, case, changes, problems):
    response = case.start(good_setup(**changes))

    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "precheck_failed"
    assert response.json()["detail"]["problems"] == problems
    # Nothing was created, so nothing can be scored from this setup.
    assert sessions(db) == []
    assert db.execute(select(AuditLog).where(AuditLog.action == "session.started")).first() is None


def test_a_client_cannot_simply_declare_the_check_passed(client, db, case):
    response = client.post(
        SESSIONS,
        json={"plan_exercise_id": case.item_id, "precheck": {"passed": True}},
        headers=case.headers,
    )
    declared = case.start(good_setup(visibility={}) | {"passed": True})

    assert response.status_code == 422 and declared.status_code == 422
    assert sessions(db) == []


@pytest.mark.parametrize(
    "evidence",
    [
        good_setup(brightness=1.4),
        good_setup(brightness=-0.1),
        good_setup(held_ms=-5),
        good_setup(visibility={"left_knee": 3}),
        good_setup(visibility={"tail": 0.9}),
        {"brightness": 0.5},
    ],
)
def test_impossible_measurements_are_refused(client, db, case, evidence):
    assert case.start(evidence).status_code == 422
    assert sessions(db) == []


def test_only_landmarks_the_exercise_needs_are_judged(client, case):
    # Arms out of view do not matter for a leg exercise.
    extra = dict.fromkeys(LEGS, 0.9) | {"left_wrist": 0.0, "right_elbow": 0.05, "nose": 0.1}

    assert case.start(good_setup(visibility=extra)).status_code == 201


def test_the_advisory_must_be_acknowledged_first(client, make, db):
    case = Case(client, make, consent=False)

    for response in (case.requirements(), case.start()):
        assert response.status_code == 403
        assert response.json()["detail"]["code"] == "consent_required"
    assert sessions(db) == []
    case.acknowledge()
    assert case.start().status_code == 201


def test_a_session_is_only_for_an_exercise_in_the_patients_own_current_plan(client, make, db, case):
    other = Case(client, make, exercise="Leg Lunge")
    week_one_item = case.item_id
    case.plan = case.assign("Week 2")  # archives Week 1

    someone_elses = case.start(item=other.item_id)
    archived = case.start(item=week_one_item)
    unknown = case.start(item=NOBODY)

    for response in (someone_elses, archived, unknown):
        assert response.status_code == 404
    assert someone_elses.json() == unknown.json()
    assert case.requirements(item=other.item_id).status_code == 404
    assert sessions(db) == []


def test_an_exercise_that_was_switched_off_cannot_be_started(client, make, db, case):
    admin = bearer(sign_in(client, make.account(Role.admin)))
    client.post(f"/api/v1/admin/exercises/{case.squats.id}/deactivate", headers=admin)

    for response in (case.requirements(), case.start()):
        assert response.status_code == 409
        assert response.json()["detail"]["code"] == "exercise_unavailable"
    assert sessions(db) == []


def test_starting_again_closes_a_session_that_was_left_open(client, db, case):
    first = case.start().json()
    second = case.start().json()

    stored = {str(s.id): s for s in sessions(db)}
    assert stored[first["id"]].status == "abandoned" and stored[first["id"]].ended_at is not None
    assert stored[second["id"]].status == "active"
    assert client.get(f"{SESSIONS}/{first['id']}", headers=case.headers).json()["status"] == "abandoned"


# --- The session keeps what it was started with ------------------------------


def test_editing_the_prescription_does_not_change_a_session_already_started(client, db, case):
    session = case.start().json()

    edited = client.patch(
        f"/api/v1/physio/patients/{case.patient.id}/plans/{case.plan['id']}/items/{case.item_id}",
        json={"sets": 5, "reps": 8, "difficulty": "hard"},
        headers=case.physio_headers,
    )

    assert edited.status_code == 200
    kept = client.get(f"{SESSIONS}/{session['id']}", headers=case.headers).json()
    assert (kept["sets"], kept["reps"], kept["difficulty"], kept["prescription_revision"]) == (
        3,
        12,
        "medium",
        1,
    )
    # A session started after the edit gets the new prescription.
    client.post(f"{SESSIONS}/{session['id']}/end", headers=case.headers)
    later = case.start().json()
    assert (later["sets"], later["reps"], later["difficulty"], later["prescription_revision"]) == (
        5,
        8,
        "hard",
        2,
    )


def test_editing_thresholds_does_not_change_a_session_already_started(client, make, db, case):
    session = case.start().json()
    admin = bearer(sign_in(client, make.account(Role.admin)))
    stricter = [dict(check, amber=7, red=9) for check in sessions(db)[0].checks]

    updated = client.patch(
        f"/api/v1/admin/exercises/{case.squats.id}", json={"checks": stricter}, headers=admin
    )

    assert updated.status_code == 200 and updated.json()["version"] == 2
    stored = next(s for s in sessions(db) if str(s.id) == session["id"])
    assert stored.template_version == 1
    assert [(c["amber"], c["red"]) for c in stored.checks] == [(10, 15)]


# --- Ending a session ---------------------------------------------------------


def test_ending_a_session_records_when_it_finished(client, db, case, time):
    session = case.start().json()
    time.advance(minutes=4)

    response = client.post(f"{SESSIONS}/{session['id']}/end", headers=case.headers)

    assert response.status_code == 200
    assert response.json()["status"] == "completed" and response.json()["ended_at"] is not None
    entry = db.execute(select(AuditLog).where(AuditLog.action == "session.ended")).scalar_one()
    assert entry.detail == {"seconds": 240}
    # Ending it again (a double tap, a retry) changes nothing and records nothing.
    again = client.post(f"{SESSIONS}/{session['id']}/end", headers=case.headers)
    assert again.json() == response.json()
    assert len(db.execute(select(AuditLog).where(AuditLog.action == "session.ended")).all()) == 1


def test_a_patient_cannot_read_or_end_someone_elses_session(client, make, case):
    other = Case(client, make, exercise="Leg Lunge")
    theirs = other.start().json()

    read = client.get(f"{SESSIONS}/{theirs['id']}", headers=case.headers)
    ended = client.post(f"{SESSIONS}/{theirs['id']}/end", headers=case.headers)
    missing = client.get(f"{SESSIONS}/{uuid.uuid4()}", headers=case.headers)

    assert read.status_code == ended.status_code == 404
    assert read.json() == missing.json()
    assert client.get(f"{SESSIONS}/{theirs['id']}", headers=other.headers).json()["status"] == "active"


@pytest.mark.parametrize("role", [Role.physiotherapist, Role.admin])
def test_only_patients_start_sessions(client, make, case, role):
    headers = bearer(sign_in(client, make.account(role)))

    assert case.start(headers=headers).status_code == 403
    assert case.requirements(headers=headers).status_code == 403
