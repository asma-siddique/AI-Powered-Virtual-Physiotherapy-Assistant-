"""US 8.2 - Data minimization: what one session leaves in the database.

A session stores the camera check's measurements, its own copy of the
prescription and thresholds, and for each repetition the angles measured
during it, its tier and its feedback. Never a picture. These tests measure
what that comes to and guard the story's two promises: less than 500 KB per
session, and no column that could hold video.

Sizes are the bytes PostgreSQL stores for each row (`pg_column_size`), so
indexes are not counted. Run with `pytest -s tests/test_data_minimization.py`
to see the measured numbers.
"""

import uuid

from sqlalchemy import text

from app.exercise_schemas import PlanItemIn
from app.session_schemas import RepetitionIn
from tests.test_repetitions import Arm
from tests.test_sessions import SESSIONS

# The success criterion of US 8.2.
LIMIT_BYTES = 500_000

# Binary columns that are allowed, each with its reason. Any other column
# that could hold a picture or a video fails the guard at the bottom.
BINARY_ALLOWED = {
    ("scoring_models", "weights"): "the trained classifier's weights, not patient data",
}


def upper_limit(model, field: str) -> int:
    """The largest value a request schema accepts for a field (its `le=`)."""
    return next(m.le for m in model.model_fields[field].metadata if getattr(m, "le", None) is not None)


def stored_bytes(db, session_id: str) -> tuple[int, list[int]]:
    """Bytes stored for one session's own row and for each of its repetitions."""
    key = {"id": uuid.UUID(session_id)}
    session = db.execute(
        text("SELECT pg_column_size(s.*) FROM exercise_sessions s WHERE s.id = :id"), key
    ).scalar_one()
    repetitions = list(
        db.execute(
            text("SELECT pg_column_size(r.*) FROM session_repetitions r WHERE r.session_id = :id"), key
        ).scalars()
    )
    return session, repetitions


def test_a_typical_session_is_stored_in_far_less_than_500_kb(client, make, db):
    arm = Arm(client, make)  # Arm Abduction, 3 sets of 12
    # Every third repetition with a bent elbow (AMBER), as a real session might go.
    for set_number in (1, 2, 3):
        for number in range(1, 13):
            elbow = 25.0 if number % 3 == 0 else 2.0
            response = arm.rep(number, set_number=set_number, elbow_bend=elbow)
            assert response.status_code == 201, response.text
    ended = client.post(f"{SESSIONS}/{arm.session_id}/end", headers=arm.headers)
    assert ended.status_code == 200, ended.text

    session, repetitions = stored_bytes(db, arm.session_id)
    total = session + sum(repetitions)
    print(
        f"\nTypical session, 36 repetitions: {total:,} bytes "
        f"(session row {session:,}, largest repetition {max(repetitions):,})"
    )

    assert len(repetitions) == 36
    assert total < LIMIT_BYTES


def test_the_largest_prescription_a_plan_allows_fits_under_500_kb(client, make, db):
    max_sets = upper_limit(PlanItemIn, "sets")
    max_reps = upper_limit(PlanItemIn, "reps")
    arm = Arm(client, make)
    plan = client.post(
        f"/api/v1/physio/patients/{arm.patient.id}/plans",
        json={
            "name": "Largest plan",
            "items": [{"exercise_id": str(arm.exercise.id), "sets": max_sets, "reps": max_reps}],
        },
        headers=arm.physio_headers,
    )
    assert plan.status_code == 201, plan.text
    arm.plan = plan.json()
    arm.session_id = arm.begin()

    # A sample of the heaviest repetition there can be without a pause: both
    # checks at AMBER, so each carries two feedback entries.
    for number in range(1, 7):
        response = arm.rep(number, trunk_lean=15.0, elbow_bend=25.0)
        assert response.status_code == 201, response.text
        assert response.json()["tier"] == "amber"

    session, repetitions = stored_bytes(db, arm.session_id)
    heaviest = max(repetitions)
    projected = session + max_sets * max_reps * heaviest
    # For information only: the API itself takes up to this many repetitions
    # in a set, more than any plan prescribes.
    api_reps = upper_limit(RepetitionIn, "rep_number")
    print(
        f"\nHeaviest repetition: {heaviest:,} bytes. "
        f"{max_sets} sets of {max_reps}: {projected:,} bytes. "
        f"{max_sets} sets of {api_reps} (the API's own limit): "
        f"{session + max_sets * api_reps * heaviest:,} bytes."
    )

    assert projected < LIMIT_BYTES


def test_no_column_can_hold_a_picture_or_a_video(db):
    rows = db.execute(
        text(
            "SELECT table_name, column_name FROM information_schema.columns "
            "WHERE table_schema = 'public' AND data_type = 'bytea'"
        )
    ).all()

    # Equal, not just a subset: an allowed column that disappears is noticed too.
    assert {(table, column) for table, column in rows} == set(BINARY_ALLOWED)
