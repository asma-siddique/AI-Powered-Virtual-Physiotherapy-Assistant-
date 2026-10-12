"""US 4.1 and 4.3 - registering a trained classifier, evaluating it against
held-out data, promoting it only when it earns it, rolling back, and scoring
sessions with whichever model was in production when they started."""

import base64
import hashlib
import io
import json
import uuid

import numpy as np
import pytest
from sqlalchemy import select, text
from sqlalchemy.exc import DBAPIError

from app import classifier, scoring
from app.models import (
    AuditLog,
    ExerciseSession,
    ModelEvaluation,
    ModelPromotion,
    Role,
    ScoringModel,
    SessionRepetition,
)
from tests.conftest import bearer, sign_in
from tests.test_repetitions import ARM_JOINTS, Arm
from tests.test_sessions import SESSIONS

MODELS = "/api/v1/admin/models"
CHANNELS = ["left_shoulder", "right_shoulder", "left_elbow", "right_elbow", "trunk_lean", "elbow_bend"]
EXERCISES = ["arm-abduction", "squats"]
STEPS = 8
SPLITS = {"subjects": {"train": [1, 3, 5], "val": [6], "test": [2, 4]}}
REASON = "Agrees with the expert labels more often on the held-out subjects."


def weights(*, says_correct: bool = True, source: str = "0" * 64, hidden: int = 4) -> bytes:
    """A complete model of the served format that gives every repetition the
    same answer, so a test knows what it will say."""
    arrays = {
        "conv1_weight": np.zeros((hidden, 2 * len(CHANNELS), 5)),
        "conv1_bias": np.zeros(hidden),
        "bn1_scale": np.ones(hidden),
        "bn1_shift": np.zeros(hidden),
        "conv2_weight": np.zeros((hidden, hidden, 5)),
        "conv2_bias": np.zeros(hidden),
        "bn2_scale": np.ones(hidden),
        "bn2_shift": np.zeros(hidden),
        "fc1_weight": np.zeros((hidden, 2 * hidden + len(EXERCISES))),
        "fc1_bias": np.zeros(hidden),
        "fc2_weight": np.zeros((1, hidden)),
        "fc2_bias": np.array([4.0 if says_correct else -4.0]),
    }
    meta = {"channels": CHANNELS, "exercises": EXERCISES, "steps": STEPS, "source_weights_sha256": source}
    out = io.BytesIO()
    np.savez(out, meta=np.array(json.dumps(meta)), **{k: v.astype(np.float32) for k, v in arrays.items()})
    return out.getvalue()


def package(
    version: str = "rehab-cnn-202610111200-aaaaaaaa",
    *,
    agreement: float = 0.9,
    says_correct: bool = True,
    splits: dict | None = None,
    dataset: str = "d" * 64,
) -> dict:
    """What `python -m rehab.package` writes for one trained model."""
    splits_text = json.dumps(splits or SPLITS, indent=2) + "\n"
    source = hashlib.sha256(version.encode()).hexdigest()
    blob = weights(says_correct=says_correct, source=source)
    record = {
        "model_version": version,
        "architecture": "1-D CNN over resampled joint angles and checks, with mask and exercise",
        "weights_sha256": source,
        "training_data": {
            "dataset": "REHAB24-6",
            "splits_sha256": hashlib.sha256(splits_text.encode()).hexdigest(),
            "dataset_sha256": dataset,
            "channels": CHANNELS,
            "steps": STEPS,
            "exercises": EXERCISES,
        },
        "test": {"repetitions": 180, "agreement": agreement, "balanced_accuracy": agreement - 0.02},
        "target_agreement": 0.85,
    }
    return {
        "record": record,
        "splits": splits_text,
        "weights_b64": base64.b64encode(blob).decode(),
        "weights_sha256": hashlib.sha256(blob).hexdigest(),
    }


def rule_evaluation(sent: dict, agreement: float) -> dict:
    """The rule scored on the set a candidate was tested on, as
    `python -m rehab.evaluate --rule` writes it."""
    return {
        "model_version": scoring.VERSION,
        "eval_set": classifier.eval_set_name(sent["record"]["training_data"]),
        "metrics": {"repetitions": 180, "agreement": agreement, "balanced_accuracy": agreement},
    }


class Admin:
    def __init__(self, client, make) -> None:
        self.client = client
        self.account = make.account(Role.admin)
        self.headers = bearer(sign_in(client, self.account))

    def get(self) -> dict:
        response = self.client.get(MODELS, headers=self.headers)
        assert response.status_code == 200, response.text
        return response.json()

    def register(self, sent: dict):
        return self.client.post(MODELS, json=sent, headers=self.headers)

    def evaluate(self, version: str, body: dict):
        return self.client.post(f"{MODELS}/{version}/evaluations", json=body, headers=self.headers)

    def promote(self, version: str, reason: str = REASON):
        return self.client.post(f"{MODELS}/{version}/promote", json={"reason": reason}, headers=self.headers)

    def rollback(self, reason: str = "Scores looked wrong in clinic.", to: str | None = None):
        body = {"reason": reason} | ({"to_version": to} if to else {})
        return self.client.post(f"{MODELS}/rollback", json=body, headers=self.headers)

    def in_production(self, sent: dict, *, rule_agreement: float = 0.7) -> str:
        """Registers a model and takes it all the way to production."""
        version = sent["record"]["model_version"]
        assert self.register(sent).status_code == 201
        assert self.evaluate(scoring.VERSION, rule_evaluation(sent, rule_agreement)).status_code == 201
        response = self.promote(version)
        assert response.status_code == 200, response.text
        return version


@pytest.fixture
def admin(client, make) -> Admin:
    return Admin(client, make)


def model(registry: dict, version: str) -> dict:
    return next(m for m in registry["models"] if m["version"] == version)


def code(response) -> str:
    return response.json()["detail"]["code"]


# --- The registry as it starts -------------------------------------------------


def test_the_rule_is_the_production_model_until_something_is_promoted(admin):
    registry = admin.get()

    assert registry["production"] == scoring.VERSION
    assert [(m["version"], m["kind"], m["status"]) for m in registry["models"]] == [
        (scoring.VERSION, "rule", "production")
    ]
    assert registry["history"] == []


# --- Registering (US 4.1) ------------------------------------------------------


def test_a_registered_model_is_a_candidate_with_its_held_out_evaluation(admin, db):
    sent = package(agreement=0.91)

    response = admin.register(sent)

    assert response.status_code == 201, response.text
    registry = response.json()
    # Registering alone never changes what scores sessions.
    assert registry["production"] == scoring.VERSION
    entry = model(registry, "rehab-cnn-202610111200-aaaaaaaa")
    assert (entry["kind"], entry["status"]) == ("classifier", "candidate")
    assert entry["registered_by"]["id"] == str(admin.account.id)
    assert entry["training_data"]["splits_sha256"] == sent["record"]["training_data"]["splits_sha256"]
    assert entry["target_agreement"] == 0.85
    [evaluation] = entry["evaluations"]
    assert evaluation["agreement"] == 0.91
    assert evaluation["repetitions"] == 180
    assert evaluation["source"] == "training_record"
    assert evaluation["eval_set"] == classifier.eval_set_name(sent["record"]["training_data"])
    stored = db.get(ScoringModel, entry["version"])
    assert stored.weights_sha256 == sent["weights_sha256"]
    assert hashlib.sha256(stored.weights).hexdigest() == sent["weights_sha256"]
    [entry] = db.execute(select(AuditLog).where(AuditLog.action == "model.registered")).scalars()
    assert entry.actor_id == admin.account.id


def test_a_model_without_a_held_out_evaluation_is_refused(admin, db):
    sent = package()
    del sent["record"]["test"]

    response = admin.register(sent)

    assert (response.status_code, code(response)) == (422, "record_incomplete")
    assert db.execute(select(ScoringModel)).scalars().all() == [db.get(ScoringModel, scoring.VERSION)]


def test_a_model_is_refused_when_a_subject_is_in_two_splits(admin, db):
    leaking = {"subjects": {"train": [1, 3, 5], "val": [6], "test": [2, 3]}}

    response = admin.register(package(splits=leaking))

    assert (response.status_code, code(response)) == (422, "subject_in_two_splits")
    assert "Subject 3" in response.json()["detail"]["message"]
    assert db.get(ScoringModel, "rehab-cnn-202610111200-aaaaaaaa") is None


def test_the_splits_sent_must_be_the_ones_in_the_record(admin):
    sent = package()
    sent["splits"] = json.dumps({"subjects": {"train": [1], "val": [6], "test": [2]}})

    response = admin.register(sent)

    assert (response.status_code, code(response)) == (422, "splits_mismatch")


@pytest.mark.parametrize(
    ("change", "expected"),
    [
        (lambda s: s.update(weights_b64=base64.b64encode(b"not a model").decode()), "weights_mismatch"),
        (
            lambda s: s.update(
                weights_b64=base64.b64encode(b"not a model").decode(),
                weights_sha256=hashlib.sha256(b"not a model").hexdigest(),
            ),
            "weights_unreadable",
        ),
        (lambda s: s.update(weights_b64="***"), "weights_unreadable"),
        # Weights exported from some other model than the record describes.
        (lambda s: s["record"].update(weights_sha256="f" * 64), "weights_mismatch"),
        (lambda s: s["record"]["training_data"].update(exercises=["squats"]), "weights_mismatch"),
    ],
)
def test_weights_that_are_not_this_model_are_refused(admin, change, expected):
    sent = package()
    change(sent)

    response = admin.register(sent)

    assert (response.status_code, code(response)) == (422, expected)


def test_a_version_is_registered_once(admin):
    assert admin.register(package()).status_code == 201

    response = admin.register(package())

    assert (response.status_code, code(response)) == (409, "model_exists")


def test_weights_holding_code_instead_of_numbers_are_never_loaded():
    out = io.BytesIO()
    np.savez(out, meta=np.array({"channels": CHANNELS}, dtype=object))  # needs pickle to read

    with pytest.raises(classifier.ModelFormatError):
        classifier.load(out.getvalue())


# --- Promotion (US 4.3) --------------------------------------------------------


def test_a_candidate_is_not_promoted_until_the_current_model_is_scored_on_the_same_set(admin):
    sent = package()
    admin.register(sent)

    response = admin.promote(sent["record"]["model_version"])

    assert (response.status_code, code(response)) == (409, "incumbent_not_evaluated")
    assert admin.get()["production"] == scoring.VERSION


def test_an_evaluation_on_another_set_does_not_count(admin):
    sent = package()
    admin.register(sent)
    elsewhere = rule_evaluation(package(dataset="e" * 64), 0.5)
    assert admin.evaluate(scoring.VERSION, elsewhere).status_code == 201

    response = admin.promote(sent["record"]["model_version"])

    assert (response.status_code, code(response)) == (409, "incumbent_not_evaluated")


def test_a_candidate_that_does_worse_than_the_current_model_is_refused(admin, db):
    sent = package(agreement=0.8)
    admin.register(sent)
    admin.evaluate(scoring.VERSION, rule_evaluation(sent, 0.82))

    response = admin.promote(sent["record"]["model_version"])

    assert (response.status_code, code(response)) == (409, "not_better")
    detail = response.json()["detail"]
    assert (detail["agreement"], detail["incumbent_agreement"]) == (0.8, 0.82)
    assert admin.get()["production"] == scoring.VERSION
    assert db.execute(select(ModelPromotion)).scalars().all() == []


def test_promotion_is_an_admins_recorded_decision(admin, db):
    sent = package(agreement=0.9)
    version = sent["record"]["model_version"]
    admin.register(sent)
    admin.evaluate(scoring.VERSION, rule_evaluation(sent, 0.7))

    response = admin.promote(version)

    assert response.status_code == 200, response.text
    registry = response.json()
    assert registry["production"] == version
    assert model(registry, version)["status"] == "production"
    assert model(registry, scoring.VERSION)["status"] == "retired"
    [decision] = registry["history"]
    assert (decision["action"], decision["model_version"], decision["previous_version"]) == (
        "promote",
        version,
        scoring.VERSION,
    )
    assert (decision["agreement"], decision["incumbent_agreement"]) == (0.9, 0.7)
    assert decision["reason"] == REASON
    assert decision["decided_by"]["id"] == str(admin.account.id)
    [entry] = db.execute(select(AuditLog).where(AuditLog.action == "model.promoted")).scalars()
    assert entry.detail["previous"] == scoring.VERSION


def test_a_decision_needs_a_reason(admin):
    sent = package()
    admin.register(sent)
    admin.evaluate(scoring.VERSION, rule_evaluation(sent, 0.7))

    response = admin.client.post(
        f"{MODELS}/{sent['record']['model_version']}/promote", json={"reason": ""}, headers=admin.headers
    )

    assert response.status_code == 422
    assert admin.get()["production"] == scoring.VERSION


def test_only_one_model_is_ever_in_production(admin, db):
    first = admin.in_production(package("rehab-cnn-1", agreement=0.86))
    second = package("rehab-cnn-2", agreement=0.9)
    admin.register(second)

    response = admin.promote("rehab-cnn-2")

    assert response.status_code == 200, response.text
    rows = {m.version: m.status for m in db.execute(select(ScoringModel)).scalars()}
    assert rows == {scoring.VERSION: "retired", first: "retired", "rehab-cnn-2": "production"}
    with pytest.raises(DBAPIError):
        db.execute(text("UPDATE scoring_models SET status = 'production' WHERE version = 'rehab-cnn-1'"))
    db.rollback()


def test_evaluations_and_decisions_can_never_be_changed_or_deleted(admin, db):
    admin.in_production(package())

    for statement in (
        "UPDATE model_evaluations SET agreement = 1",
        "DELETE FROM model_evaluations",
        "UPDATE model_promotions SET reason = 'changed'",
        "DELETE FROM model_promotions",
    ):
        with pytest.raises(DBAPIError, match="append-only"):
            db.execute(text(statement))
        db.rollback()
    assert len(db.execute(select(ModelEvaluation)).scalars().all()) == 2
    assert len(db.execute(select(ModelPromotion)).scalars().all()) == 1


def test_an_evaluation_must_be_of_the_model_it_is_filed_under(admin):
    sent = package()
    admin.register(sent)

    response = admin.evaluate(sent["record"]["model_version"], rule_evaluation(sent, 0.99))

    assert (response.status_code, code(response)) == (422, "evaluation_of_another_model")


# --- Rollback ------------------------------------------------------------------


def test_there_is_nothing_to_roll_back_to_at_first(admin):
    response = admin.rollback()

    assert (response.status_code, code(response)) == (409, "nothing_to_roll_back_to")


def test_rolling_back_puts_the_previous_model_back_at_once(admin, db):
    version = admin.in_production(package())

    response = admin.rollback("Scores looked wrong in clinic.")

    assert response.status_code == 200, response.text
    registry = response.json()
    assert registry["production"] == scoring.VERSION
    assert model(registry, version)["status"] == "retired"
    assert [(d["action"], d["model_version"], d["previous_version"]) for d in registry["history"]] == [
        ("rollback", scoring.VERSION, version),
        ("promote", version, scoring.VERSION),
    ]
    # Its weights and its records are all still there.
    assert db.get(ScoringModel, version).weights is not None
    [entry] = db.execute(select(AuditLog).where(AuditLog.action == "model.rolled_back")).scalars()
    assert entry.detail == {"previous": version, "reason": "Scores looked wrong in clinic."}


def test_a_model_that_was_never_in_production_cannot_be_rolled_back_to(admin):
    admin.in_production(package("rehab-cnn-1"))
    admin.register(package("rehab-cnn-2", agreement=0.5))

    response = admin.rollback(to="rehab-cnn-2")

    # That would be a promotion without the comparison.
    assert (response.status_code, code(response)) == (409, "never_production")
    assert admin.get()["production"] == "rehab-cnn-1"


# --- Scoring sessions with the production model --------------------------------


FRAMES = [[150.0, 20.0, 170.0, 175.0, 2.0, None]] * 5 + [[90.0, 20.0, 172.0, None, 3.0, 4.0]] * 5


def rep(arm: Arm, number: int, frames=FRAMES, **measures):
    body = {
        "client_key": str(uuid.uuid4()),
        "set_number": 1,
        "rep_number": number,
        "started_ms": number * 3000,
        "ended_ms": number * 3000 + 2400,
        "measures": {"trunk_lean": 1.0, "elbow_bend": 2.0, **measures},
    }
    if frames is not None:
        body["frames"] = frames
    return arm.client.post(f"{SESSIONS}/{arm.session_id}/repetitions", json=body, headers=arm.headers)


def end(arm: Arm) -> dict:
    response = arm.client.post(f"{SESSIONS}/{arm.session_id}/end", headers=arm.headers)
    assert response.status_code == 200, response.text
    return response.json()


@pytest.fixture
def arm(client, make) -> Arm:
    return Arm(client, make)


def test_a_session_under_the_rule_asks_for_no_frames(arm):
    assert arm.session()["series"] is None

    judged = rep(arm, 1).json()

    # Frames sent anyway are not judged by anything.
    assert judged["judged_correct"] is None
    assert end(arm)["summary"]["scoring_version"] == scoring.VERSION


def test_a_session_started_after_promotion_is_scored_by_the_classifier(arm, admin, db):
    version = admin.in_production(package(says_correct=True))
    arm.session_id = arm.begin()

    series = arm.session()["series"]
    assert series["channels"] == CHANNELS
    assert (series["joints"], series["checks"]) == (["shoulder", "elbow"], ["trunk_lean", "elbow_bend"])
    first = rep(arm, 1)
    assert first.status_code == 201, first.text
    assert first.json()["judged_correct"] is True
    rep(arm, 2, trunk_lean=12.0)  # AMBER by the thresholds, whatever the model says
    summary = end(arm)["summary"]

    assert summary["scoring_version"] == version
    assert (summary["form_score"], summary["scored_repetitions"]) == (100, 2)
    assert summary["totals"]["amber"] == 1
    db.expire_all()
    stored = db.execute(
        select(SessionRepetition).where(SessionRepetition.session_id == uuid.UUID(arm.session_id))
    ).scalars()
    for repetition in stored:
        assert repetition.model_version == version
        assert repetition.correct_probability == pytest.approx(1 / (1 + np.exp(-4.0)), abs=1e-6)


def test_the_score_is_the_share_of_repetitions_the_classifier_found_correct(arm, admin):
    admin.in_production(package(says_correct=False))
    arm.session_id = arm.begin()

    assert rep(arm, 1).json()["judged_correct"] is False
    rep(arm, 2)
    summary = end(arm)["summary"]

    assert (summary["form_score"], summary["scored_repetitions"]) == (0, 2)


def test_a_session_keeps_the_model_it_started_with(arm, admin, db):
    version = admin.in_production(package())
    arm.session_id = arm.begin()
    rep(arm, 1)

    assert admin.rollback().status_code == 200
    # Still judged by the model the session started with.
    assert rep(arm, 2).json()["judged_correct"] is True
    summary = end(arm)["summary"]

    assert summary["scoring_version"] == version
    arm.session_id = arm.begin()
    assert arm.session()["series"] is None
    rep(arm, 1)
    assert end(arm)["summary"]["scoring_version"] == scoring.VERSION


def test_a_session_under_way_is_not_moved_to_a_newly_promoted_model(arm, admin):
    rep(arm, 1, frames=None)

    admin.in_production(package())
    rep(arm, 2)
    summary = end(arm)["summary"]

    assert summary["scoring_version"] == scoring.VERSION


def test_the_safety_pause_does_not_depend_on_the_classifier(arm, admin):
    admin.in_production(package(says_correct=True))
    arm.session_id = arm.begin()

    response = rep(arm, 1, trunk_lean=25.0).json()

    # The model calls it correct; the thresholds still stop the session.
    assert response["judged_correct"] is True
    assert (response["tier"], response["session_status"]) == ("red", "paused")


def test_an_exercise_the_model_was_not_trained_on_is_scored_by_the_rule(admin, client, make, db):
    admin.in_production(package())
    arm = Arm(client, make)
    lunge = make.exercise("Leg Lunge", target_joints=ARM_JOINTS, checks=arm.exercise.checks)
    arm.exercise = lunge
    arm.plan = arm.assign("Leg plan", lunge)
    arm.session_id = arm.begin()

    assert arm.session()["series"] is None
    rep(arm, 1)
    assert end(arm)["summary"]["scoring_version"] == scoring.VERSION


def test_without_frames_the_rule_scores_the_session_and_says_so(arm, admin, db):
    admin.in_production(package(says_correct=False))
    arm.session_id = arm.begin()

    assert rep(arm, 1, frames=None).json()["judged_correct"] is None
    summary = end(arm)["summary"]

    # Never a score of 0 because nothing was judged: the rule's score, named as such.
    assert (summary["form_score"], summary["scoring_version"]) == (100, scoring.VERSION)
    stored = db.get(ExerciseSession, uuid.UUID(arm.session_id))
    assert stored.scoring_version == scoring.VERSION


@pytest.mark.parametrize(
    "frames",
    [
        [[1.0, 2.0]] * 4,  # not the channels the session asked for
        [[1.0] * 6, [1.0] * 5],
    ],
)
def test_frames_of_the_wrong_shape_are_refused(arm, admin, db, frames):
    admin.in_production(package())
    arm.session_id = arm.begin()

    response = rep(arm, 1, frames=frames)

    assert (response.status_code, code(response)) == (422, "frames_malformed")
    assert db.execute(select(SessionRepetition)).scalars().all() == []


def test_a_repetition_never_measured_is_still_judged_from_its_mask(arm, admin):
    admin.in_production(package())
    arm.session_id = arm.begin()

    response = rep(arm, 1, frames=[[None] * 6] * 3)

    assert response.status_code == 201, response.text


# --- The network itself --------------------------------------------------------


def test_resampling_keeps_what_was_measured_apart_from_what_was_not():
    series = np.array([[0.0, np.nan], [90.0, np.nan], [180.0, 45.0]], dtype=np.float32)

    values, mask = classifier.resample(series, 5)

    assert values[0].tolist() == pytest.approx([0, 0.25, 0.5, 0.75, 1.0])
    assert mask[0].tolist() == [1, 1, 1, 1, 1]
    # Filled for the network's sake, but marked as not measured where it was not.
    assert values[1].tolist() == pytest.approx([0.25] * 5)
    # Steps 0.0, 0.5, 1.0, 1.5, 2.0 take the mask of frames 0, 0, 1, 2, 2.
    assert mask[1].tolist() == [0, 0, 0, 1, 1]


def test_the_forward_pass_matches_a_hand_worked_network():
    """One filter, one channel, so every step can be followed by hand."""
    arrays = {
        "conv1_weight": np.array([[[0, 1, 0], [0, 0, 0]]], dtype=np.float32),  # passes the value through
        "conv1_bias": np.array([0.5], dtype=np.float32),
        "bn1_scale": np.array([2.0], dtype=np.float32),
        "bn1_shift": np.array([-1.0], dtype=np.float32),
        "conv2_weight": np.array([[[1, 1, 1]]], dtype=np.float32),  # sums three neighbours
        "conv2_bias": np.array([0.0], dtype=np.float32),
        "bn2_scale": np.array([1.0], dtype=np.float32),
        "bn2_shift": np.array([0.0], dtype=np.float32),
        "fc1_weight": np.array([[1.0, 1.0, 10.0]], dtype=np.float32),  # mean + max + 10 x exercise
        "fc1_bias": np.array([0.0], dtype=np.float32),
        "fc2_weight": np.array([[1.0]], dtype=np.float32),
        "fc2_bias": np.array([-3.0], dtype=np.float32),
    }
    model = classifier.Classifier(arrays=arrays, channels=("a",), exercises=("squats",), steps=3)
    values = np.array([[0.0, 1.0, 2.0]], dtype=np.float32)

    probability = model.probability_correct(values, np.ones_like(values), "squats")

    # conv1+bn1: (v + 0.5) * 2 - 1 = [0, 2, 4]; conv2 sums neighbours: [2, 6, 6];
    # mean 14/3, max 6, exercise 10 -> 20.667; minus 3 -> logit 17.667.
    assert probability == pytest.approx(1 / (1 + np.exp(-(14 / 3 + 6 + 10 - 3))), abs=1e-6)
    assert model.probability_correct(values, np.ones_like(values), "push-ups") is None
