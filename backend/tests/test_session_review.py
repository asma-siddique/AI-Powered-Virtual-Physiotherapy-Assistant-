"""US 4.2, 5.1 and 5.2 - the session summary and form score, the patient's
history, and the physiotherapist's flagged-session queue."""

from datetime import timedelta

import pytest
from sqlalchemy import select

from app import scoring
from app.config import get_settings
from app.models import AuditLog, ExerciseSession, Notification, Role
from tests.conftest import bearer, sign_in
from tests.test_repetitions import Arm
from tests.test_sessions import NOBODY, SESSIONS, Case, good_setup

FLAGGED = "/api/v1/physio/flagged-sessions"
PHYSIO_SESSIONS = "/api/v1/physio/sessions"
# Measures that land in each tier for the Arm Abduction checks.
INFO = {"trunk_lean": 6.0}
AMBER = {"elbow_bend": 25.0}
RED = {"trunk_lean": 24.0}


@pytest.fixture
def arm(client, make) -> Arm:
    return Arm(client, make)


def later(arm: Arm, time, **delta) -> None:
    """Moves the clock on. Access tokens do not last that long, so both
    people sign in again."""
    time.advance(**delta)
    arm.headers = bearer(sign_in(arm.client, arm.patient))
    arm.physio_headers = bearer(sign_in(arm.client, arm.physio))


def end(arm: Arm) -> dict:
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/end", headers=arm.headers)
    assert response.status_code == 200, response.text
    return response.json()


def perform(arm: Arm, *reps: dict) -> dict:
    """Does the given repetitions in the session under way and ends it."""
    for number, measures in enumerate(reps, start=1):
        response = arm.rep(number, **measures)
        assert response.status_code == 201, response.text
        if response.json()["pause"]:
            assert arm.acknowledge(response.json()["id"]).status_code == 200
    return end(arm)


def queue(arm: Arm, state: str | None = None, headers: dict | None = None) -> list[dict]:
    response = arm.client.get(
        FLAGGED, params={"state": state} if state else None, headers=headers or arm.physio_headers
    )
    assert response.status_code == 200, response.text
    return response.json()


def flag_notices(db, recipient) -> list[Notification]:
    db.expire_all()
    return list(
        db.execute(
            select(Notification).where(
                Notification.recipient_id == recipient.id, Notification.kind == "session_flagged"
            )
        ).scalars()
    )


# --- The score ---------------------------------------------------------------


def test_the_score_is_the_average_of_what_each_repetition_is_worth():
    measured = {"trunk_lean": 1.0}
    assert scoring.form_score([("ok", measured)] * 3) == (100, 3)
    assert scoring.form_score([("ok", measured), ("info", measured), ("amber", measured)]) == (80, 3)
    assert scoring.form_score([("red", measured), ("ok", measured)]) == (50, 2)
    assert scoring.form_score([("red", measured)]) == (0, 1)


def test_nothing_to_score_is_no_score_rather_than_zero():
    assert scoring.form_score([]) == (None, 0)
    # A repetition where no check was in view says nothing about form.
    unseen = {"trunk_lean": None, "elbow_bend": None}
    assert scoring.form_score([("ok", unseen)]) == (None, 0)
    assert scoring.form_score([("ok", unseen), ("amber", {"trunk_lean": None, "elbow_bend": 25})]) == (55, 1)


# --- The summary (US 4.2) ----------------------------------------------------


def test_ending_a_session_returns_its_summary(arm, db, time):
    arm.rep(1)
    arm.rep(2, **INFO)
    arm.rep(3, **AMBER)
    assert arm.session()["summary"] is None  # nothing is summed up while it is under way
    time.advance(minutes=4, seconds=30)

    summary = end(arm)["summary"]

    assert summary["duration_seconds"] == 270
    assert summary["totals"] == {"repetitions": 3, "ok": 1, "info": 1, "amber": 1, "red": 0}
    assert summary["form_score"] == 80
    assert summary["scored_repetitions"] == 3
    assert summary["scoring_version"] == scoring.VERSION
    assert (summary["previous"], summary["score_change"]) == (None, None)
    # The same summary is read back later, from what was stored.
    assert arm.session()["summary"] == summary
    stored = db.execute(select(ExerciseSession)).scalar_one()
    assert (stored.form_score, stored.scoring_version) == (80, scoring.VERSION)
    ended = db.execute(select(AuditLog).where(AuditLog.action == "session.ended")).scalar_one()
    assert ended.detail["form_score"] == 80


def test_the_summary_compares_with_the_previous_session_of_the_same_exercise(arm, time):
    first = perform(arm, {}, AMBER)  # (100 + 55) / 2 = 78 after rounding
    later(arm, time, days=1)
    # A session of another exercise in between is not what it is compared with.
    arm.plan = arm.assign("Legs", arm.squats)
    assert arm.start(good_setup()).status_code == 201
    later(arm, time, days=1)
    arm.plan = arm.assign("Shoulder again", arm.exercise)
    arm.session_id = arm.begin()

    summary = perform(arm, {}, {}, INFO)["summary"]  # (100 + 100 + 85) / 3 = 95

    assert first["summary"]["form_score"] == 78
    assert summary["form_score"] == 95
    assert summary["previous"]["id"] == first["id"]
    assert summary["previous"]["form_score"] == 78
    assert summary["previous"]["repetitions"] == 2
    assert summary["score_change"] == 17


def test_a_session_with_nothing_to_score_has_no_score_and_no_comparison_number(arm, time):
    empty = end(arm)["summary"]
    later(arm, time, hours=1)
    arm.session_id = arm.begin()
    arm.rep(1, trunk_lean=None, elbow_bend=None)
    unseen = end(arm)["summary"]
    later(arm, time, hours=1)
    arm.session_id = arm.begin()
    scored = perform(arm, {})["summary"]

    assert (empty["form_score"], empty["scored_repetitions"]) == (None, 0)
    assert (unseen["form_score"], unseen["totals"]["repetitions"]) == (None, 1)
    # There is a previous session, but no number to compare with: no change is made up.
    assert scored["previous"]["form_score"] is None
    assert scored["score_change"] is None


# --- History (US 5.1) --------------------------------------------------------


def test_history_lists_ended_sessions_most_recent_first(arm, time):
    first = perform(arm, {}, AMBER)
    later(arm, time, days=2)
    arm.session_id = arm.begin()
    second = perform(arm, {})
    later(arm, time, days=2)
    arm.session_id = arm.begin()  # still under way: not history yet
    arm.rep(1)

    listed = arm.client.get(SESSIONS, headers=arm.headers).json()

    assert [s["id"] for s in listed] == [second["id"], first["id"]]
    assert [s["form_score"] for s in listed] == [100, 78]
    assert listed[1]["totals"] == {"repetitions": 2, "ok": 1, "info": 0, "amber": 1, "red": 0}
    assert listed[0]["exercise"]["name"] == "Arm Abduction"
    assert listed[0]["status"] == "completed"
    assert listed[0]["scoring_version"] == scoring.VERSION


def test_history_can_be_narrowed_to_an_exercise_and_a_date_range(arm, time):
    start = time.now()
    first = perform(arm, {})
    later(arm, time, days=10)
    arm.plan = arm.assign("Legs", arm.squats)
    squats = arm.start(good_setup()).json()
    later(arm, time, days=10)
    arm.plan = arm.assign("Shoulder again", arm.exercise)
    arm.session_id = arm.begin()  # abandons the squats session
    latest = perform(arm, {}, INFO)

    def ids(**params) -> list[str]:
        response = arm.client.get(SESSIONS, params=params, headers=arm.headers)
        assert response.status_code == 200, response.text
        return [s["id"] for s in response.json()]

    middle = (start + timedelta(days=5)).isoformat()
    assert ids() == [latest["id"], squats["id"], first["id"]]
    assert ids(exercise_id=squats["exercise"]["id"]) == [squats["id"]]
    assert ids(since=middle) == [latest["id"], squats["id"]]
    assert ids(until=middle) == [first["id"]]
    assert ids(until=(start - timedelta(days=1)).isoformat()) == []
    assert ids(exercise_id=str(arm.exercise.id), since=middle) == [latest["id"]]


def test_a_session_left_open_is_closed_with_its_own_score(arm, time):
    arm.rep(1)
    arm.rep(2, **AMBER)
    left_open = arm.session_id
    later(arm, time, hours=3)
    arm.session_id = arm.begin()

    listed = arm.client.get(SESSIONS, headers=arm.headers).json()

    assert [(s["id"], s["status"], s["form_score"]) for s in listed] == [(left_open, "abandoned", 78)]


def test_session_detail_shows_every_repetition_in_order(arm):
    arm.rep(2, **AMBER)
    arm.rep(1)
    arm.rep(1, set_number=2, trunk_lean=None)
    session = end(arm)

    response = arm.client.get(f"{SESSIONS}/{session['id']}/detail", headers=arm.headers)

    assert response.status_code == 200, response.text
    detail = response.json()
    assert [(r["set_number"], r["rep_number"], r["tier"]) for r in detail["repetitions"]] == [
        (1, 1, "ok"),
        (1, 2, "amber"),
        (2, 1, "ok"),
    ]
    assert detail["repetitions"][1]["feedback"][0]["check"] == "elbow_bend"
    assert detail["repetitions"][2]["unmeasured"] == ["trunk_lean"]
    assert [c["key"] for c in detail["checks"]] == ["trunk_lean", "elbow_bend"]
    assert (detail["form_score"], detail["scored_repetitions"]) == (85, 3)


def test_history_and_detail_are_only_ever_the_patients_own(arm, client, make):
    session = perform(arm, {})
    someone = Case(client, make, exercise="Leg Lunge")

    assert client.get(SESSIONS, headers=someone.headers).json() == []
    theirs = client.get(f"{SESSIONS}/{session['id']}/detail", headers=someone.headers)
    missing = client.get(f"{SESSIONS}/{NOBODY}/detail", headers=someone.headers)
    assert theirs.status_code == 404
    assert theirs.json() == missing.json()


# --- The flagged queue (US 5.2) ----------------------------------------------


def test_a_red_repetition_puts_the_session_in_the_queue_at_once(arm, db):
    assert queue(arm) == []
    red = arm.rep(1, **RED).json()

    listed = queue(arm)

    # Before the session has even ended: a patient who closes the app after a
    # RED is still seen.
    assert len(listed) == 1
    assert listed[0]["session"]["id"] == arm.session_id
    assert listed[0]["session"]["status"] == "paused"
    assert listed[0]["session"]["flag_reasons"] == ["red"]
    assert listed[0]["patient"] == {"id": str(arm.patient.id), "full_name": arm.patient.full_name}
    notices = flag_notices(db, arm.physio)
    assert len(notices) == 1
    assert "paused for safety" in notices[0].body and notices[0].link == "/physio/flagged"

    # A second RED in the same session is the same queue entry and no new notice.
    arm.acknowledge(red["id"])
    arm.rep(2, **RED)
    assert len(queue(arm)) == 1
    assert len(flag_notices(db, arm.physio)) == 1


def test_a_low_score_flags_the_session_when_it_ends(arm, db):
    perform(arm, AMBER, AMBER)  # 55, below the threshold of 60

    listed = queue(arm)

    assert listed[0]["session"]["flag_reasons"] == ["low_score"]
    assert listed[0]["session"]["form_score"] == 55
    assert listed[0]["flag_threshold"] == 60
    assert "scored below 60" in flag_notices(db, arm.physio)[0].body


def test_a_session_at_or_above_the_threshold_is_not_flagged(arm, db, monkeypatch):
    perform(arm, {}, AMBER, AMBER)  # 70
    assert queue(arm) == []
    assert flag_notices(db, arm.physio) == []

    # The threshold is a setting: raise it and the same form is flagged.
    monkeypatch.setattr(get_settings(), "flag_score_below", 75)
    arm.session_id = arm.begin()
    perform(arm, {}, AMBER, AMBER)
    assert queue(arm)[0]["flag_threshold"] == 75


def test_a_session_with_nothing_to_score_is_not_flagged_as_low(arm):
    end(arm)
    assert queue(arm) == []


def test_both_reasons_are_kept_and_the_queue_is_most_recent_first(arm, db, time):
    perform(arm, RED)  # score 0: RED and low score
    later(arm, time, hours=1)
    arm.session_id = arm.begin()
    perform(arm, AMBER)

    listed = queue(arm)

    assert [entry["session"]["flag_reasons"] for entry in listed] == [["low_score"], ["red", "low_score"]]
    assert listed[0]["flagged_at"] > listed[1]["flagged_at"]
    # One notice for each session, not one for each reason.
    assert len(flag_notices(db, arm.physio)) == 2


def test_only_marking_it_reviewed_takes_a_session_out_of_the_queue(arm, db, time):
    session = perform(arm, RED)
    later(arm, time, days=30)
    assert len(queue(arm)) == 1  # waiting does not make it go away

    response = arm.client.post(f"{PHYSIO_SESSIONS}/{session['id']}/review", headers=arm.physio_headers)

    assert response.status_code == 200, response.text
    assert response.json()["reviewed_at"] is not None
    assert queue(arm) == []
    reviewed = queue(arm, "reviewed")
    assert [entry["session"]["id"] for entry in reviewed] == [session["id"]]
    assert reviewed[0]["reviewed_by"]["full_name"] == "Sarah Malik"
    assert len(queue(arm, "all")) == 1
    entry = db.execute(select(AuditLog).where(AuditLog.action == "session.reviewed")).scalar_one()
    assert entry.actor_id == arm.physio.id and entry.target_id == session["id"]

    # Marking it again keeps the first review.
    again = arm.client.post(f"{PHYSIO_SESSIONS}/{session['id']}/review", headers=arm.physio_headers)
    assert again.json()["reviewed_at"] == response.json()["reviewed_at"]
    assert len(db.execute(select(AuditLog).where(AuditLog.action == "session.reviewed")).all()) == 1


def test_a_new_red_after_a_review_brings_the_session_back(arm, db):
    red = arm.rep(1, **RED).json()
    arm.client.post(f"{PHYSIO_SESSIONS}/{arm.session_id}/review", headers=arm.physio_headers)
    assert queue(arm) == []
    arm.acknowledge(red["id"])

    arm.rep(2, **RED)

    assert [entry["session"]["id"] for entry in queue(arm)] == [arm.session_id]
    assert len(flag_notices(db, arm.physio)) == 2


def test_a_session_that_was_not_flagged_cannot_be_marked_reviewed(arm):
    session = perform(arm, {})

    response = arm.client.post(f"{PHYSIO_SESSIONS}/{session['id']}/review", headers=arm.physio_headers)

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "not_flagged"


def test_a_physiotherapist_opens_a_patients_session_and_history(arm):
    session = perform(arm, {}, RED)

    detail = arm.client.get(f"{PHYSIO_SESSIONS}/{session['id']}", headers=arm.physio_headers)
    listed = arm.client.get(f"/api/v1/physio/patients/{arm.patient.id}/sessions", headers=arm.physio_headers)

    assert detail.status_code == 200, detail.text
    assert [r["tier"] for r in detail.json()["repetitions"]] == ["ok", "red"]
    assert detail.json()["repetitions"][1]["feedback"][0]["check"] == "trunk_lean"
    assert [s["id"] for s in listed.json()] == [session["id"]]


def test_another_physiotherapist_sees_none_of_it(arm, client, make):
    session = perform(arm, RED)
    omar = bearer(sign_in(client, make.account(Role.physiotherapist)))

    assert queue(arm, headers=omar) == []
    assert queue(arm, "all", headers=omar) == []
    for method, path in [
        ("GET", f"{PHYSIO_SESSIONS}/{session['id']}"),
        ("POST", f"{PHYSIO_SESSIONS}/{session['id']}/review"),
        ("GET", f"/api/v1/physio/patients/{arm.patient.id}/sessions"),
    ]:
        response = client.request(method, path, headers=omar)
        assert response.status_code == 404, (method, path)
    # And it is still waiting for the physiotherapist it belongs to.
    assert len(queue(arm)) == 1
