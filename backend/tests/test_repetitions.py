"""US 3.3 and 3.4 - storing repetitions, severity tiers and the safety pause."""

import uuid

import pytest
from sqlalchemy import select

from app import disclaimer, pose, severity
from app.models import AuditLog, ExerciseSession, ExerciseTemplate, SessionRepetition
from tests.conftest import bearer, sign_in
from tests.test_sessions import NOBODY, SESSIONS, Case

TRUNK = {
    "key": "trunk_lean",
    "label": "Trunk lean",
    "measure": "Sideways lean of the trunk away from vertical",
    "unit": "degrees",
    "info": 5,
    "amber": 10,
    "red": 20,
    "corrective_message": "Keep your body upright. Do not lean away as you lift your arm.",
}
# Never a safety matter, so it has no RED threshold.
ELBOW = {
    "key": "elbow_bend",
    "label": "Elbow straightness",
    "measure": "Elbow flexion during the lift",
    "unit": "degrees",
    "info": 10,
    "amber": 20,
    "red": None,
    "corrective_message": "Keep your elbow straight as you raise your arm.",
}
ARM_JOINTS = ["shoulder", "elbow", "hip"]


class Arm(Case):
    """A patient in the middle of an Arm Abduction session (3 sets of 12)."""

    def __init__(self, client, make) -> None:
        super().__init__(client, make)
        self.exercise = make.exercise("Arm Abduction", target_joints=ARM_JOINTS, checks=[TRUNK, ELBOW])
        self.plan = self.assign("Shoulder plan", self.exercise)
        self.session_id = self.begin()

    def begin(self) -> str:
        landmarks = pose.required_landmarks(ARM_JOINTS, ["trunk_lean", "elbow_bend"])
        response = self.start(
            {"brightness": 0.55, "held_ms": 1800, "visibility": dict.fromkeys(landmarks, 0.93)}
        )
        assert response.status_code == 201, response.text
        return response.json()["id"]

    def rep(self, number: int = 1, *, set_number: int = 1, key: str | None = None, headers=None, **measures):
        """Sends one repetition. Measures not named are perfectly clean."""
        body = {
            "client_key": key or str(uuid.uuid4()),
            "set_number": set_number,
            "rep_number": number,
            "started_ms": number * 3000,
            "ended_ms": number * 3000 + 2400,
            "measures": {"trunk_lean": 1.0, "elbow_bend": 2.0, **measures},
        }
        return self.client.post(
            f"{SESSIONS}/{self.session_id}/repetitions", json=body, headers=headers or self.headers
        )

    def session(self) -> dict:
        response = self.client.get(f"{SESSIONS}/{self.session_id}", headers=self.headers)
        assert response.status_code == 200, response.text
        return response.json()

    def acknowledge(self, repetition_id: str | None = None):
        if repetition_id is None:  # the advisory, during set-up
            return super().acknowledge()
        return self.client.post(
            f"{SESSIONS}/{self.session_id}/acknowledge",
            json={"repetition_id": repetition_id},
            headers=self.headers,
        )


@pytest.fixture
def arm(client, make) -> Arm:
    return Arm(client, make)


def stored(db) -> list[SessionRepetition]:
    db.expire_all()
    return list(db.execute(select(SessionRepetition).order_by(SessionRepetition.created_at)).scalars())


def audited(db, action: str) -> list[AuditLog]:
    db.expire_all()
    return list(db.execute(select(AuditLog).where(AuditLog.action == action)).scalars())


# --- The tier rule itself -----------------------------------------------------


@pytest.mark.parametrize(
    ("value", "tier"),
    [
        (0, "ok"),
        (4.99, "ok"),
        (5, "info"),
        (9.99, "info"),
        (10, "amber"),
        (19.99, "amber"),
        (20, "red"),
        (75, "red"),
    ],
)
def test_a_threshold_is_reached_at_its_own_value(value, tier):
    assert severity.tier_of(value, TRUNK) == tier


def test_a_check_without_a_red_threshold_can_never_be_red():
    assert severity.tier_of(10_000, ELBOW) == "amber"


def test_the_repetition_takes_its_worst_check_and_lists_feedback_worst_first():
    tier, feedback, unmeasured = severity.classify({"trunk_lean": 6, "elbow_bend": 25}, [TRUNK, ELBOW])

    assert tier == "amber"
    assert [(item["check"], item["tier"]) for item in feedback] == [
        ("elbow_bend", "amber"),
        ("trunk_lean", "info"),
    ]
    assert feedback[0]["message"] == ELBOW["corrective_message"]
    assert unmeasured == []


def test_a_check_that_could_not_be_measured_is_reported_not_guessed():
    tier, feedback, unmeasured = severity.classify({"trunk_lean": None, "elbow_bend": 12}, [TRUNK, ELBOW])

    assert (tier, [item["check"] for item in feedback], unmeasured) == (
        "info",
        ["elbow_bend"],
        ["trunk_lean"],
    )


# --- Storing a repetition -----------------------------------------------------


def test_a_session_carries_its_own_thresholds_and_starts_with_nothing_counted(arm):
    session = arm.session()

    assert [check["key"] for check in session["checks"]] == ["trunk_lean", "elbow_bend"]
    assert session["checks"][0]["red"] == 20 and session["checks"][1]["red"] is None
    assert session["exercise"]["slug"] == "arm-abduction"
    assert session["totals"] == {"repetitions": 0, "ok": 0, "info": 0, "amber": 0, "red": 0}
    assert session["pause"] is None
    # The elbow check needs the wrists, so the camera check asked for them.
    assert "left_wrist" in session["required_landmarks"]


def test_a_clean_repetition_is_stored_with_no_feedback(arm, db):
    response = arm.rep(1)

    assert response.status_code == 201, response.text
    body = response.json()
    assert (body["set_number"], body["rep_number"], body["started_ms"], body["ended_ms"]) == (
        1,
        1,
        3000,
        5400,
    )
    assert (body["tier"], body["feedback"], body["unmeasured"]) == ("ok", [], [])
    assert (body["session_status"], body["pause"]) == ("active", None)
    [row] = stored(db)
    assert str(row.id) == body["id"] and row.measures == {"trunk_lean": 1.0, "elbow_bend": 2.0}
    assert arm.session()["totals"] == {"repetitions": 1, "ok": 1, "info": 0, "amber": 0, "red": 0}


def test_info_and_amber_are_stored_as_feedback_and_never_pause(arm, db):
    info = arm.rep(1, trunk_lean=6).json()
    amber = arm.rep(2, trunk_lean=12, elbow_bend=11).json()

    assert (info["tier"], info["session_status"], info["pause"]) == ("info", "active", None)
    assert info["feedback"] == [
        {
            "check": "trunk_lean",
            "label": "Trunk lean",
            "tier": "info",
            "value": 6,
            "unit": "degrees",
            "message": TRUNK["corrective_message"],
        }
    ]
    assert (amber["tier"], amber["session_status"]) == ("amber", "active")
    assert [(item["check"], item["tier"]) for item in amber["feedback"]] == [
        ("trunk_lean", "amber"),
        ("elbow_bend", "info"),
    ]
    # What the patient was shown is exactly what is stored behind it.
    assert [row.feedback for row in stored(db)] == [info["feedback"], amber["feedback"]]
    assert arm.rep(3).status_code == 201
    assert audited(db, "session.paused") == []


def test_the_app_cannot_send_a_verdict_of_its_own(arm, db):
    body = {
        "client_key": str(uuid.uuid4()),
        "set_number": 1,
        "rep_number": 1,
        "started_ms": 0,
        "ended_ms": 2000,
        "measures": {"trunk_lean": 30, "elbow_bend": 0},
        # Ignored: the server decides.
        "tier": "ok",
        "session_status": "active",
    }
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/repetitions", json=body, headers=arm.headers)

    assert response.status_code == 201
    assert (response.json()["tier"], response.json()["session_status"]) == ("red", "paused")


def test_a_check_that_was_not_in_view_is_stored_as_unmeasured(arm, db):
    body = arm.rep(1, trunk_lean=None, elbow_bend=25).json()

    assert (body["tier"], body["unmeasured"]) == ("amber", ["trunk_lean"])
    assert stored(db)[0].measures == {"trunk_lean": None, "elbow_bend": 25}


# --- The safety pause ---------------------------------------------------------


def test_a_red_repetition_pauses_the_session_in_the_same_step(arm, db):
    response = arm.rep(1, trunk_lean=24)

    assert response.status_code == 201
    body = response.json()
    assert (body["tier"], body["session_status"]) == ("red", "paused")
    assert body["pause"] == {
        "repetition_id": body["id"],
        "check": "trunk_lean",
        "message": TRUNK["corrective_message"],
    }
    session = arm.session()
    assert (session["status"], session["pause"]) == ("paused", body["pause"])
    [entry] = audited(db, "session.paused")
    assert entry.detail == {
        "repetition_id": body["id"],
        "set_number": 1,
        "rep_number": 1,
        "check": "trunk_lean",
    }
    assert entry.actor_id == arm.patient.id


def test_nothing_is_counted_while_the_session_is_paused(arm, db):
    red = arm.rep(1, trunk_lean=24).json()

    refused = arm.rep(2)

    assert refused.status_code == 409
    detail = refused.json()["detail"]
    assert detail["code"] == "session_paused" and detail["pause"] == red["pause"]
    assert len(stored(db)) == 1


def test_acknowledging_the_message_lets_the_session_carry_on(arm, db, time):
    red = arm.rep(1, trunk_lean=24).json()
    time.advance(seconds=20)

    response = arm.acknowledge(red["id"])

    assert response.status_code == 200, response.text
    assert (response.json()["status"], response.json()["pause"]) == ("active", None)
    assert stored(db)[0].acknowledged_at is not None
    [entry] = audited(db, "session.pause_acknowledged")
    assert entry.detail == {"repetition_id": red["id"], "check": "trunk_lean"}
    assert arm.rep(2).status_code == 201
    assert arm.session()["totals"] == {"repetitions": 2, "ok": 1, "info": 0, "amber": 0, "red": 1}

    # Acknowledging again (a double tap, a retry) changes nothing and records nothing.
    again = arm.acknowledge(red["id"])
    assert again.status_code == 200 and again.json()["status"] == "active"
    assert len(audited(db, "session.pause_acknowledged")) == 1


def test_only_the_repetition_that_paused_the_session_can_be_acknowledged(arm, db):
    amber = arm.rep(1, trunk_lean=12).json()
    red = arm.rep(2, trunk_lean=24).json()

    for wrong in (amber["id"], NOBODY):
        response = arm.acknowledge(wrong)
        assert response.status_code == 409 and response.json()["detail"]["code"] == "wrong_repetition"
    assert arm.session()["status"] == "paused"
    assert arm.acknowledge(red["id"]).status_code == 200


def test_a_second_red_pauses_again_and_needs_its_own_acknowledgment(arm, db):
    first = arm.rep(1, trunk_lean=24).json()
    arm.acknowledge(first["id"])

    second = arm.rep(2, trunk_lean=31).json()

    assert second["pause"]["repetition_id"] == second["id"]
    assert arm.session()["pause"]["repetition_id"] == second["id"]
    # The first one, already acknowledged, is answered without resuming anything.
    assert arm.acknowledge(first["id"]).json()["status"] == "paused"
    assert arm.acknowledge(second["id"]).json()["status"] == "active"
    assert len(audited(db, "session.paused")) == 2


def test_a_patient_may_end_the_session_while_it_is_paused(arm, db):
    red = arm.rep(1, trunk_lean=24).json()

    ended = arm.client.post(f"{SESSIONS}/{arm.session_id}/end", headers=arm.headers)

    assert ended.status_code == 200
    assert (ended.json()["status"], ended.json()["pause"]) == ("completed", None)
    assert ended.json()["totals"] == {"repetitions": 1, "ok": 0, "info": 0, "amber": 0, "red": 1}
    [entry] = audited(db, "session.ended")
    assert entry.detail["ended_while_paused"] is True and entry.detail["red"] == 1
    # There is nothing left to resume, and no more repetitions are taken.
    late = arm.acknowledge(red["id"])
    assert late.status_code == 409 and late.json()["detail"]["code"] == "session_not_paused"
    refused = arm.rep(2)
    assert refused.status_code == 409 and refused.json()["detail"]["code"] == "session_not_active"


def test_starting_again_closes_a_session_that_was_left_paused(arm, db):
    arm.rep(1, trunk_lean=24)

    second = arm.begin()

    db.expire_all()
    first = db.get(ExerciseSession, uuid.UUID(arm.session_id))
    assert (first.status, first.ended_at is not None) == ("abandoned", True)
    assert db.get(ExerciseSession, uuid.UUID(second)).status == "active"


# --- Retries and duplicates ---------------------------------------------------


def test_sending_the_same_repetition_again_stores_it_once(arm, db):
    key = str(uuid.uuid4())
    first = arm.rep(1, key=key, trunk_lean=12)

    again = arm.rep(1, key=key, trunk_lean=12)

    assert (first.status_code, again.status_code) == (201, 200)
    assert again.json() == first.json()
    assert len(stored(db)) == 1


def test_a_retried_red_repetition_gets_its_pause_back_not_a_refusal(arm, db):
    key = str(uuid.uuid4())
    first = arm.rep(1, key=key, trunk_lean=24)

    # The reply was lost; the app sends it again while the session is paused.
    again = arm.rep(1, key=key, trunk_lean=24)

    assert again.status_code == 200 and again.json() == first.json()
    assert again.json()["pause"]["repetition_id"] == first.json()["id"]
    assert len(stored(db)) == 1 and len(audited(db, "session.paused")) == 1


def test_a_key_cannot_be_reused_for_a_different_repetition(arm, db):
    key = str(uuid.uuid4())
    arm.rep(1, key=key)

    response = arm.rep(2, key=key)

    assert response.status_code == 409 and response.json()["detail"]["code"] == "client_key_reused"
    assert len(stored(db)) == 1


def test_the_same_place_in_a_set_cannot_be_counted_twice(arm, db):
    arm.rep(3)

    response = arm.rep(3)

    assert response.status_code == 409 and response.json()["detail"]["code"] == "repetition_exists"
    assert len(stored(db)) == 1
    # The same number in another set is a different repetition.
    assert arm.rep(3, set_number=2).status_code == 201


# --- What is refused ----------------------------------------------------------


def test_every_check_must_be_accounted_for(arm, db):
    body = {
        "client_key": str(uuid.uuid4()),
        "set_number": 1,
        "rep_number": 1,
        "started_ms": 0,
        "ended_ms": 2000,
        # The safety check is left out altogether.
        "measures": {"elbow_bend": 2},
    }
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/repetitions", json=body, headers=arm.headers)

    assert response.status_code == 422
    assert response.json()["detail"]["code"] == "measures_incomplete"
    assert response.json()["detail"]["missing"] == ["trunk_lean"]
    assert stored(db) == []


def test_a_measure_for_a_check_the_session_does_not_have_is_refused(arm, db):
    response = arm.rep(1, knee_valgus=3)

    assert response.status_code == 422 and response.json()["detail"]["code"] == "unknown_check"
    assert stored(db) == []


@pytest.mark.parametrize(
    "changes",
    [
        {"set_number": 0},
        {"rep_number": 0},
        {"rep_number": 201},
        {"started_ms": -1},
        {"started_ms": 5000, "ended_ms": 4000},
        {"measures": {"trunk_lean": 1e9, "elbow_bend": 0}},
        {"measures": {"trunk_lean": "a lot", "elbow_bend": 0}},
        {"client_key": "not-a-key"},
    ],
)
def test_a_repetition_that_makes_no_sense_is_refused(arm, db, changes):
    body = {
        "client_key": str(uuid.uuid4()),
        "set_number": 1,
        "rep_number": 1,
        "started_ms": 0,
        "ended_ms": 2000,
        "measures": {"trunk_lean": 1, "elbow_bend": 1},
        **changes,
    }
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/repetitions", json=body, headers=arm.headers)

    assert response.status_code == 422, response.text
    assert stored(db) == []


def test_a_set_beyond_the_prescription_is_refused(arm, db):
    response = arm.rep(1, set_number=4)

    assert response.status_code == 422 and response.json()["detail"]["code"] == "set_out_of_range"
    assert arm.rep(1, set_number=3).status_code == 201


def test_another_patient_cannot_write_to_or_resume_the_session(arm, db, make):
    red = arm.rep(1, trunk_lean=24).json()
    stranger = bearer(sign_in(arm.client, make.patient_of(arm.physio)))
    arm.client.post(
        "/api/v1/patient/consent",
        json={"version": disclaimer.CURRENT_VERSION, "acknowledged": True},
        headers=stranger,
    )

    write = arm.rep(2, headers=stranger)
    resume = arm.client.post(
        f"{SESSIONS}/{arm.session_id}/acknowledge", json={"repetition_id": red["id"]}, headers=stranger
    )

    assert (write.status_code, resume.status_code) == (404, 404)
    assert len(stored(db)) == 1 and arm.session()["status"] == "paused"


def test_a_patient_who_has_not_accepted_the_advisory_cannot_store_repetitions(client, make, db):
    case = Case(client, make, consent=False)

    response = client.post(
        f"{SESSIONS}/{NOBODY}/repetitions",
        json={
            "client_key": str(uuid.uuid4()),
            "set_number": 1,
            "rep_number": 1,
            "started_ms": 0,
            "ended_ms": 1,
            "measures": {},
        },
        headers=case.headers,
    )

    assert response.status_code == 403 and response.json()["detail"]["code"] == "consent_required"


# --- Later edits never reach a session that has started ----------------------


def test_changing_the_thresholds_afterwards_does_not_change_this_session(arm, db):
    template = db.get(ExerciseTemplate, arm.exercise.id)
    template.checks = [{**TRUNK, "info": 1, "amber": 2, "red": 3}, ELBOW]
    template.version += 1
    db.commit()

    # 12 degrees is RED by the new thresholds but AMBER by the session's own.
    body = arm.rep(1, trunk_lean=12).json()

    assert (body["tier"], body["session_status"]) == ("amber", "active")
    assert arm.session()["checks"][0]["red"] == 20
