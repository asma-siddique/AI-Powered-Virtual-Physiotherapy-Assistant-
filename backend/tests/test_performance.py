"""US 9.2 - the core screens stay within the performance budget.

The budget is the project's own: what Home, My Plan and a live session ask
the API for must each be answered within 300 ms, the figure the user stories
give for feedback on a repetition and for opening the history. It is measured
here inside the API (no network), on a patient who already has a history, so
a query that grows with the data shows up as a failure.

A slow machine can make any single request slow, so each one is repeated and
the middle time is what is judged.
"""

import statistics
import time
import uuid

import pytest

from tests.test_repetitions import Arm
from tests.test_sessions import SESSIONS

# Milliseconds the API may take to answer one request of a core screen.
BUDGET_MS = 300
REPEATS = 5
# Finished sessions the patient already has when the screens are timed.
PAST_SESSIONS = 30


def middle_ms(call) -> float:
    times = []
    for _ in range(REPEATS):
        started = time.perf_counter()
        response = call()
        times.append((time.perf_counter() - started) * 1000)
        assert response.status_code < 300, response.text
    return statistics.median(times)


@pytest.fixture
def arm(client, make) -> Arm:
    """A patient with a month of sessions behind them and one under way."""
    patient = Arm(client, make)
    for _ in range(PAST_SESSIONS):
        for number in range(1, 4):
            patient.rep(number)
        ended = client.post(f"{SESSIONS}/{patient.session_id}/end", headers=patient.headers)
        assert ended.status_code == 200, ended.text
        patient.session_id = patient.begin()
    return patient


def test_home_and_my_plan_load_within_the_budget(arm):
    get = arm.client.get
    screens = {
        "the plan": lambda: get("/api/v1/patient/plan", headers=arm.headers),
        "the session history": lambda: get(SESSIONS, headers=arm.headers),
        "notifications": lambda: get("/api/v1/notifications", headers=arm.headers),
        "reminder settings": lambda: get("/api/v1/patient/reminders", headers=arm.headers),
    }

    taken = {name: middle_ms(call) for name, call in screens.items()}

    assert all(ms < BUDGET_MS for ms in taken.values()), taken


def test_a_live_session_answers_within_the_budget(arm):
    numbers = iter(range(1, 100))

    def repetition():
        number = next(numbers)
        return arm.client.post(
            f"{SESSIONS}/{arm.session_id}/repetitions",
            json={
                "client_key": str(uuid.uuid4()),
                "set_number": 1,
                "rep_number": number,
                "started_ms": number * 3000,
                "ended_ms": number * 3000 + 2400,
                "measures": {"trunk_lean": 7.0, "elbow_bend": 2.0},
            },
            headers=arm.headers,
        )

    taken = {
        # The patient waits for this one before feedback is shown.
        "storing and judging a repetition": middle_ms(repetition),
        "the session itself": middle_ms(
            lambda: arm.client.get(f"{SESSIONS}/{arm.session_id}", headers=arm.headers)
        ),
        "the camera check's requirements": middle_ms(
            lambda: arm.client.get(f"/api/v1/patient/plan/items/{arm.item_id}/precheck", headers=arm.headers)
        ),
    }

    assert all(ms < BUDGET_MS for ms in taken.values()), taken


def test_ending_a_session_and_its_summary_stay_within_three_seconds(arm):
    for number in range(1, 4):
        arm.rep(number)

    started = time.perf_counter()
    ended = arm.client.post(f"{SESSIONS}/{arm.session_id}/end", headers=arm.headers)
    seconds = time.perf_counter() - started

    assert ended.status_code == 200, ended.text
    assert ended.json()["summary"]["form_score"] is not None
    # The user stories give the summary three seconds.
    assert seconds < 3
