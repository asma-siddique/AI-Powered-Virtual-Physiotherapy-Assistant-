"""US 6.1 and 6.2 - session reminders, and the alerts sent when a session is
flagged or a physiotherapist writes a note."""

from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app import reminders
from app.models import Notification, Role, SessionReminder
from tests.conftest import bearer, sign_in
from tests.test_repetitions import Arm
from tests.test_session_review import RED, end, perform
from tests.test_sessions import Case, good_setup

PLANS = "/api/v1/physio/patients/{}/plans"
REMINDERS = "/api/v1/patient/reminders"
USERS = "/api/v1/admin/users"

# A Monday, 12:50 UTC: ten to six in the evening in Pakistan (UTC+5).
MONDAY = datetime(2026, 10, 12, 12, 50, tzinfo=UTC)
PKT = 300


@pytest.fixture
def case(client, make) -> Case:
    return Case(client, make)


def notices(db, recipient, kind: str) -> list[Notification]:
    db.expire_all()
    return list(
        db.execute(
            select(Notification)
            .where(Notification.recipient_id == recipient.id, Notification.kind == kind)
            .order_by(Notification.created_at)
        ).scalars()
    )


def settings(case: Case, **body) -> dict:
    response = case.client.put(REMINDERS, json=body, headers=case.headers)
    assert response.status_code == 200, response.text
    return response.json()


def assign(case: Case, name: str, days: list[int] | None = None, exercise=None) -> dict:
    body = {
        "name": name,
        "items": [{"exercise_id": str((exercise or case.squats).id), "sets": 3, "reps": 12}],
    }
    if days is not None:
        body["days"] = days
    response = case.client.post(PLANS.format(case.patient.id), json=body, headers=case.physio_headers)
    assert response.status_code == 201, response.text
    return response.json()


# --- The prescribed frequency ------------------------------------------------


def test_a_plan_is_daily_unless_the_physiotherapist_prescribes_days(case):
    daily = case.plan
    three = assign(case, "Three a week", days=[4, 0, 2])

    assert daily["days"] == [0, 1, 2, 3, 4, 5, 6]
    assert three["days"] == [0, 2, 4]
    seen = case.client.get("/api/v1/patient/plan", headers=case.headers).json()
    assert seen["days"] == [0, 2, 4]


@pytest.mark.parametrize("days", [[], [7], [-1], [1, 1], [0, 1, 2, 3, 4, 5, 6, 0]])
def test_days_that_are_not_days_of_the_week_are_refused(case, days):
    response = case.client.post(
        PLANS.format(case.patient.id),
        json={"items": [{"exercise_id": str(case.squats.id), "sets": 3, "reps": 12}], "days": days},
        headers=case.physio_headers,
    )

    assert response.status_code == 422


# --- The patient's settings --------------------------------------------------


def test_reminders_are_on_at_six_in_the_evening_until_changed(case):
    before = case.client.get(REMINDERS, headers=case.headers).json()

    after = settings(case, time="07:30", utc_offset_minutes=PKT)
    off = settings(case, enabled=False)

    assert before == {
        "enabled": True,
        "time": "18:00",
        "utc_offset_minutes": None,
        "days": [0, 1, 2, 3, 4, 5, 6],
    }
    assert (after["time"], after["utc_offset_minutes"], after["enabled"]) == ("07:30", PKT, True)
    # Only what was sent changed.
    assert (off["enabled"], off["time"], off["utc_offset_minutes"]) == (False, "07:30", PKT)


@pytest.mark.parametrize("body", [{"time": "24:00"}, {"time": "7:5"}, {"utc_offset_minutes": 900}])
def test_a_setting_that_makes_no_sense_is_refused(case, body):
    assert case.client.put(REMINDERS, json=body, headers=case.headers).status_code == 422


def test_settings_are_each_patients_own(case, client, make):
    settings(case, time="06:00", utc_offset_minutes=PKT)
    other = Case(client, make, exercise="Leg Lunge")

    assert client.get(REMINDERS, headers=other.headers).json()["time"] == "18:00"
    assert client.get(REMINDERS, headers=case.physio_headers).status_code == 403


# --- When a reminder is sent -------------------------------------------------


def test_a_reminder_is_sent_when_the_time_arrives_and_only_once(case, db):
    settings(case, utc_offset_minutes=PKT)

    early = reminders.send_due(db, MONDAY)
    on_time = reminders.send_due(db, MONDAY + timedelta(minutes=10, seconds=20))
    again = reminders.send_due(db, MONDAY + timedelta(minutes=11))

    assert (early, on_time, again) == (0, 1, 0)
    sent = notices(db, case.patient, "session_reminder")
    assert len(sent) == 1
    assert sent[0].title == "Time for your exercises"
    assert sent[0].body == "Squats is next."
    # Straight to the exercise, not to the home page.
    assert sent[0].link == f"/patient/session/{case.item_id}"
    # The next day it is sent again.
    assert reminders.send_due(db, MONDAY + timedelta(days=1, minutes=10)) == 1


def test_the_patients_own_time_and_clock_are_used(case, db):
    settings(case, time="07:30", utc_offset_minutes=-300)  # New York in winter
    half_past_seven_there = datetime(2026, 10, 12, 12, 30, tzinfo=UTC)

    assert reminders.send_due(db, half_past_seven_there - timedelta(minutes=1)) == 0
    assert reminders.send_due(db, half_past_seven_there) == 1


def test_no_reminder_without_knowing_the_patients_clock(case, db):
    # The app has never reported an offset, so "six in the evening" is unknown.
    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 0
    assert notices(db, case.patient, "session_reminder") == []


def test_reminders_follow_the_prescribed_days(case, db):
    settings(case, utc_offset_minutes=PKT)
    assign(case, "Tuesdays and Thursdays", days=[1, 3])
    six = MONDAY + timedelta(minutes=10)

    by_day = [reminders.send_due(db, six + timedelta(days=day)) for day in range(7)]

    # Monday to Sunday: only Tuesday and Thursday.
    assert by_day == [0, 1, 0, 1, 0, 0, 0]


def test_a_day_is_the_patients_day_not_the_servers(case, db):
    # 01:00 on Tuesday in Pakistan is still Monday evening in UTC.
    settings(case, time="01:00", utc_offset_minutes=PKT)
    assign(case, "Tuesdays", days=[1])
    one_on_tuesday_there = datetime(2026, 10, 12, 20, 0, tzinfo=UTC)

    assert reminders.send_due(db, one_on_tuesday_there) == 1
    row = db.execute(select(SessionReminder)).scalar_one()
    assert row.local_date.isoformat() == "2026-10-13"


def test_switched_off_means_no_reminder(case, db):
    settings(case, utc_offset_minutes=PKT, enabled=False)

    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 0

    settings(case, enabled=True)
    assert reminders.send_due(db, MONDAY + timedelta(minutes=11)) == 1


def test_a_replaced_plan_is_never_reminded_about(case, db):
    settings(case, utc_offset_minutes=PKT)
    old_item = case.item_id
    new_plan = assign(case, "Week 2", exercise=case.make.exercise("Leg Lunge"))

    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 1

    sent = notices(db, case.patient, "session_reminder")
    assert [n.link for n in sent] == [f"/patient/session/{new_plan['items'][0]['id']}"]
    assert old_item not in sent[0].link
    assert sent[0].body == "Leg Lunge is next."


def test_a_deactivated_patient_gets_no_reminder(case, client, db, make):
    settings(case, utc_offset_minutes=PKT)
    admin = bearer(sign_in(client, make.account(Role.admin)))
    response = client.post(f"{USERS}/{case.patient.id}/deactivate", headers=admin)
    assert response.status_code == 200, response.text

    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 0


def test_no_reminder_when_todays_exercises_are_already_done(case, db, time):
    settings(case, utc_offset_minutes=PKT)
    # Monday, ten to six in the evening for the patient: they exercise now.
    time.advance(seconds=(MONDAY - time.now()).total_seconds())
    case.headers = bearer(sign_in(case.client, case.patient))
    session = case.start(good_setup()).json()
    ended = case.client.post(f"/api/v1/patient/sessions/{session['id']}/end", headers=case.headers)
    assert ended.json()["status"] == "completed"

    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 0
    assert notices(db, case.patient, "session_reminder") == []
    # Tomorrow nothing has been done yet, so the reminder is back.
    assert reminders.send_due(db, MONDAY + timedelta(days=1, minutes=10)) == 1


def test_a_session_left_unfinished_does_not_count_as_done(case, db, time):
    settings(case, utc_offset_minutes=PKT)
    time.advance(seconds=(MONDAY - time.now()).total_seconds())
    case.headers = bearer(sign_in(case.client, case.patient))
    assert case.start(good_setup()).status_code == 201  # started, never ended

    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 1


def test_the_scheduler_keeps_going_after_a_pass_fails(monkeypatch):
    import asyncio

    from app import main

    passes = []

    def tick() -> None:
        passes.append(len(passes))
        if len(passes) == 1:
            raise RuntimeError("the database blinked")

    monkeypatch.setattr(reminders, "tick", tick)

    async def run() -> None:
        task = asyncio.create_task(main._remind_every(0.01))
        while len(passes) < 3:
            await asyncio.sleep(0.01)
        task.cancel()

    asyncio.run(asyncio.wait_for(run(), timeout=5))

    assert len(passes) >= 3


def test_the_reminder_names_the_first_exercise_still_to_do(arm, db):
    settings(arm, utc_offset_minutes=PKT)
    lunge = arm.make.exercise("Leg Lunge")
    response = arm.client.post(
        PLANS.format(arm.patient.id),
        json={
            "name": "Three exercises",
            "items": [
                {"exercise_id": str(exercise.id), "sets": 2, "reps": 8}
                for exercise in (arm.squats, arm.exercise, lunge)
            ],
        },
        headers=arm.physio_headers,
    )
    assert response.status_code == 201, response.text

    assert reminders.send_due(db, MONDAY + timedelta(minutes=10)) == 1

    sent = notices(db, arm.patient, "session_reminder")[-1]
    assert sent.body == "3 exercises to do today, starting with Squats."
    assert sent.link == f"/patient/session/{response.json()['items'][0]['id']}"


def test_a_reminder_missed_by_hours_is_not_sent_late(case, db):
    settings(case, utc_offset_minutes=PKT)

    # The server was down over six o'clock and came back near midnight.
    assert reminders.send_due(db, MONDAY + timedelta(hours=4)) == 0
    # A short outage is made up for.
    assert reminders.send_due(db, MONDAY + timedelta(days=1, hours=2)) == 1


# --- Alerts (US 6.2) ---------------------------------------------------------


@pytest.fixture
def arm(client, make) -> Arm:
    return Arm(client, make)


def test_a_note_from_the_physiotherapist_reaches_the_patient(arm, db):
    session = perform(arm, {})
    url = f"/api/v1/physio/sessions/{session['id']}/note"

    arm.client.put(url, json={"note": "Good control today."}, headers=arm.physio_headers)

    sent = notices(db, arm.patient, "session_note")
    assert len(sent) == 1
    assert sent[0].title == "A note from your physiotherapist"
    assert "Arm Abduction" in sent[0].body and sent[0].link == "/patient/history"
    # The words themselves stay in the session, not in the notification.
    assert "Good control" not in sent[0].body

    # Removing the note is not news.
    arm.client.put(url, json={"note": ""}, headers=arm.physio_headers)
    assert len(notices(db, arm.patient, "session_note")) == 1


def test_a_flag_goes_to_the_physiotherapist_assigned_now_and_nobody_else(arm, client, db, make):
    omar = make.account(Role.physiotherapist, full_name="Omar Farooq")
    admin = bearer(sign_in(client, make.account(Role.admin)))
    moved = client.post(
        f"{USERS}/{arm.patient.id}/reassign", json={"physiotherapist_id": str(omar.id)}, headers=admin
    )
    assert moved.status_code == 200, moved.text

    # The session was started under Sarah; the RED happens after the move.
    arm.rep(1, **RED)
    end(arm)

    assert len(notices(db, omar, "session_flagged")) == 1
    assert notices(db, arm.physio, "session_flagged") == []
