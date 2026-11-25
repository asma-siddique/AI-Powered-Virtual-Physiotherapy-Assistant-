"""Judging a patient against their own reference (app.personal): the
physiotherapist makes it from two repetitions they saw done correctly, and
later sessions of that exercise are scored by how far each repetition is
from it."""

import copy
import json
import uuid
from pathlib import Path

import numpy as np
import pytest
from sqlalchemy import select

from app import personal, scoring
from app.models import ExerciseReference, ExerciseSession, Role
from tests.conftest import bearer, sign_in
from tests.test_repetitions import Arm, audited
from tests.test_sessions import SESSIONS

ML_EVALUATION = Path(__file__).resolve().parents[2] / "ml" / "evaluations" / "personal-2.json"
WIDTH = len(personal.CHANNELS)


def frames(angle: float = 90.0, count: int = 6) -> list[list[float | None]]:
    """A repetition measured at the same angle on every channel."""
    return [[angle] * WIDTH for _ in range(count)]


def send(arm: Arm, number: int, sent=None, *, set_number: int = 1, **measures):
    body = {
        "client_key": str(uuid.uuid4()),
        "set_number": set_number,
        "rep_number": number,
        "started_ms": (set_number * 100 + number) * 3000,
        "ended_ms": (set_number * 100 + number) * 3000 + 2400,
        "measures": {"trunk_lean": 1.0, "elbow_bend": 2.0, **measures},
    }
    if sent is not None:
        body["frames"] = sent
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/repetitions", json=body, headers=arm.headers)
    assert response.status_code == 201, response.text
    return response.json()


def end(arm: Arm) -> dict:
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/end", headers=arm.headers)
    assert response.status_code == 200, response.text
    return response.json()


def references_url(arm: Arm) -> str:
    return f"/api/v1/physio/patients/{arm.patient.id}/references"


def make_reference(arm: Arm, repetition_ids, headers=None):
    return arm.client.post(
        references_url(arm),
        json={"repetition_ids": [str(i) for i in repetition_ids]},
        headers=headers or arm.physio_headers,
    )


def detail(arm: Arm, session_id: str) -> dict:
    response = arm.client.get(f"/api/v1/physio/sessions/{session_id}", headers=arm.physio_headers)
    assert response.status_code == 200, response.text
    return response.json()


@pytest.fixture
def arm(client, make) -> Arm:
    return Arm(client, make)


def with_reference(arm: Arm) -> list[str]:
    """A first session whose first two repetitions become the reference; the
    next session is started."""
    ids = [send(arm, n, frames(90.0))["id"] for n in (1, 2)]
    end(arm)
    made = make_reference(arm, ids)
    assert made.status_code == 201, made.text
    arm.session_id = arm.begin()
    return ids


# --- The distance itself -------------------------------------------------------


def test_the_shipped_model_is_the_one_learned_from_rehab24_6():
    derived = json.loads(ML_EVALUATION.read_text())
    assert derived["model"] == personal.MODEL
    assert derived["reference_repetitions"] == personal.REFERENCE_REPETITIONS
    assert sorted(personal.CUTS) == ["arm-abduction", "leg-abduction", "leg-lunge", "push-ups", "squats"]
    for entry in personal.MODEL["exercises"].values():
        assert set(entry["spreads"]) <= set(personal.CHANNELS)
        assert min(entry["spreads"].values()) >= personal.MIN_SPREAD


def test_distance_counts_each_channel_in_units_of_its_spread():
    values, mask = personal.series_of(frames(90.0))
    reference, reference_mask = personal.series_of(frames(100.0))
    # Two channels, 10 degrees off on both: one spreads 2 degrees, one 5.
    assert personal.distance(values, mask, reference, reference_mask, [0, 1], [2.0, 5.0]) == pytest.approx(
        (10 / 2 + 10 / 5) / 2, abs=1e-3
    )
    # Only the channels asked for count, and only what both measured.
    reference_mask[0] = 0
    assert personal.distance(values, mask, reference, reference_mask, [0, 1], [2.0, 5.0]) == pytest.approx(
        2.0, abs=1e-3
    )
    assert personal.distance(values, mask * 0, reference, reference_mask, [0, 1], [2.0, 5.0]) is None


def test_the_shipped_distance_uses_the_exercises_own_channels():
    values, mask = personal.series_of(frames(90.0))
    reference, reference_mask = personal.series_of(frames(90.0))
    far = personal.CHANNELS.index("left_ankle")  # not an arm abduction channel
    values[far] += 0.5
    assert personal.distance_for("arm-abduction", values, mask, reference, reference_mask) == 0.0
    assert personal.distance_for("wall-sit", values, mask, reference, reference_mask) is None


def test_a_spread_is_the_median_difference_but_never_below_the_noise_floor():
    assert personal.spread([1.0, 2.0, 9.0]) == 2.0
    assert personal.spread([0.1, 0.2]) == personal.MIN_SPREAD


def test_a_reference_keeps_only_what_every_repetition_measured():
    first = personal.series_of(frames(80.0))
    gap = frames(100.0)
    for frame in gap:
        frame[3] = None
    second = personal.series_of(gap)

    values, mask = personal.reference_of([first, second])

    assert mask[3].sum() == 0
    assert values[0] * 180 == pytest.approx(np.full(personal.STEPS, 90.0), abs=1e-3)


def test_stored_series_round_trip_to_a_tenth_of_a_degree():
    values, mask = personal.series_of([[12.34] * WIDTH, [None] * (WIDTH - 1) + [56.78]])
    back_values, back_mask = personal.decode(personal.encode(values, mask))
    assert (back_mask == mask).all()
    assert np.abs(back_values - values)[mask > 0].max() * 180 <= 0.05


@pytest.mark.parametrize("slug", sorted(personal.CUTS))
def test_within_the_cut_is_exactly_what_counts_as_correct(slug):
    cut = personal.CUTS[slug]
    assert personal.probability_correct(cut, slug) == pytest.approx(scoring.CORRECT_FROM)
    assert personal.probability_correct(cut * 0.9, slug) > scoring.CORRECT_FROM
    assert personal.probability_correct(cut * 1.1, slug) < scoring.CORRECT_FROM
    assert personal.probability_correct(1.0, "wall-sit") is None


# --- Making a reference ---------------------------------------------------------


def test_the_first_repetitions_of_a_session_keep_their_angles_for_a_reference(arm, db):
    for n in range(1, personal.STORED_SERIES + 2):
        send(arm, n, frames(90.0))
    send(arm, 1, None, set_number=2)  # no frames: nothing to keep

    reps = detail(arm, arm.session_id)["repetitions"]

    kept = [r["can_be_reference"] for r in reps]
    assert kept == [True] * personal.STORED_SERIES + [False, False]
    assert detail(arm, arm.session_id)["reference_supported"] is True


def test_a_physiotherapist_makes_the_reference_from_two_repetitions(arm, db):
    ids = [send(arm, n, frames(90.0))["id"] for n in (1, 2)]
    end(arm)

    made = make_reference(arm, ids)

    assert made.status_code == 201, made.text
    body = made.json()
    assert body["exercise"]["slug"] == "arm-abduction"
    assert [r["rep_number"] for r in body["repetitions"]] == [1, 2]
    assert body["created_by"]["full_name"] == "Sarah Malik"
    assert body["sessions_judged"] == 0
    listed = arm.client.get(references_url(arm), headers=arm.physio_headers).json()
    assert [r["id"] for r in listed] == [body["id"]]
    assert all(r["in_reference"] for r in detail(arm, arm.session_id)["repetitions"])
    entry = audited(db, "exercise_reference.set")[0]
    assert entry.detail["repetition_ids"] == ids and entry.detail["replaced"] is None


def test_sessions_after_it_are_judged_against_it(arm, db):
    with_reference(arm)

    same = send(arm, 1, frames(90.0))
    off = send(arm, 2, frames(120.0))
    assert (same["judged_correct"], off["judged_correct"]) == (True, False)

    summary = end(arm)["summary"]
    assert summary["scoring_version"] == personal.VERSION
    assert (summary["form_score"], summary["scored_repetitions"]) == (50, 2)
    reps = detail(arm, arm.session_id)["repetitions"]
    near, far = (r["reference_distance"] for r in reps)
    assert near == pytest.approx(0, abs=0.01)
    assert far > personal.CUTS["arm-abduction"]
    session = db.get(ExerciseSession, uuid.UUID(arm.session_id))
    db.refresh(session)
    assert session.reference_id is not None


def test_the_thresholds_still_decide_the_tier_and_the_pause(arm):
    with_reference(arm)

    # Exactly like the reference, but over the RED threshold: the pause stands.
    red = send(arm, 1, frames(90.0), trunk_lean=25.0)

    assert red["judged_correct"] is True
    assert red["tier"] == "red"
    assert red["session_status"] == "paused"


def test_a_session_without_frames_falls_back_to_the_rule(arm):
    with_reference(arm)
    send(arm, 1, None)

    summary = end(arm)["summary"]

    assert summary["scoring_version"] == scoring.VERSION


def test_a_new_reference_retires_the_old_one_which_is_kept(arm, db):
    first = with_reference(arm)
    send(arm, 1, frames(90.0))
    end(arm)
    judged_by_first = arm.session_id
    arm.session_id = arm.begin()
    second = [send(arm, n, frames(95.0))["id"] for n in (1, 2)]
    end(arm)

    made = make_reference(arm, second)

    assert made.status_code == 201, made.text
    db.expire_all()
    rows = list(db.execute(select(ExerciseReference).order_by(ExerciseReference.created_at)).scalars())
    assert [r.repetition_ids for r in rows] == [first, second]
    assert rows[0].retired_at is not None and rows[1].retired_at is None
    # The session the first one judged still points at it.
    assert db.get(ExerciseSession, uuid.UUID(judged_by_first)).reference_id == rows[0].id
    assert audited(db, "exercise_reference.set")[1].detail["replaced"] == str(rows[0].id)
    listed = arm.client.get(references_url(arm), headers=arm.physio_headers).json()
    assert [r["id"] for r in listed] == [str(rows[1].id)]


def test_retiring_the_reference_goes_back_to_the_usual_scorer(arm, db):
    with_reference(arm)
    end(arm)
    reference = arm.client.get(references_url(arm), headers=arm.physio_headers).json()[0]

    retired = arm.client.delete(f"{references_url(arm)}/{reference['id']}", headers=arm.physio_headers)

    assert retired.status_code == 204, retired.text
    arm.session_id = arm.begin()
    send(arm, 1, frames(90.0))
    assert end(arm)["summary"]["scoring_version"] == scoring.VERSION
    assert arm.client.get(references_url(arm), headers=arm.physio_headers).json() == []
    assert len(audited(db, "exercise_reference.retired")) == 1


# --- What cannot be a reference -------------------------------------------------


def test_repetitions_without_kept_angles_cannot_be_a_reference(arm):
    ids = [send(arm, 1, None)["id"], send(arm, 2, frames())["id"]]

    refused = make_reference(arm, ids)

    assert refused.status_code == 422
    assert refused.json()["detail"]["code"] == "reference_no_series"


def test_a_repetition_over_a_safety_threshold_cannot_be_a_reference(arm):
    clean = send(arm, 1, frames())["id"]
    red = send(arm, 2, frames(), trunk_lean=25.0)["id"]

    refused = make_reference(arm, [clean, red])

    assert refused.status_code == 422
    assert refused.json()["detail"]["code"] == "reference_red"


def test_two_exercises_cannot_make_one_reference(arm, make):
    arm_rep = send(arm, 1, frames())["id"]
    end(arm)
    leg = make.exercise(
        "Leg Abduction", target_joints=["shoulder", "elbow", "hip"], checks=arm.exercise.checks
    )
    arm.plan = arm.assign("Leg plan", leg)
    arm.session_id = arm.begin()
    leg_rep = send(arm, 1, frames())["id"]

    refused = make_reference(arm, [arm_rep, leg_rep])

    assert refused.status_code == 422
    assert refused.json()["detail"]["code"] == "reference_mixed_exercises"


def test_the_same_repetition_twice_is_refused(arm):
    rep = send(arm, 1, frames())["id"]
    assert make_reference(arm, [rep, rep]).status_code == 422


def test_only_the_patients_own_physiotherapist_can_make_it(arm, client, make):
    ids = [send(arm, n, frames())["id"] for n in (1, 2)]
    colleague = bearer(sign_in(client, make.account(Role.physiotherapist)))

    assert make_reference(arm, ids, headers=colleague).status_code == 404
    assert make_reference(arm, ids, headers=arm.headers).status_code == 403
    assert client.get(references_url(arm), headers=colleague).status_code == 404


def test_another_patients_repetitions_are_not_found(arm, client, make):
    # A second patient of the same physiotherapist, doing the same exercise.
    other = copy.copy(arm)
    other.patient = make.patient_of(arm.physio)
    other.headers = bearer(sign_in(client, other.patient))
    other.acknowledge()
    other.plan = other.assign("Shoulder plan", arm.exercise)
    other.session_id = other.begin()
    theirs = [send(other, n, frames())["id"] for n in (1, 2)]

    refused = make_reference(arm, theirs)

    assert refused.status_code == 404
