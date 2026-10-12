"""The registry of scoring models (US 4.1 and 4.3): which model scores
sessions now, every model that could, how each one did against held-out data,
and every decision to promote or roll back.

The rules it enforces:

- A model is registered only with a held-out evaluation, and only if the
  splits it was trained with keep every subject in a single split.
- A candidate becomes the production model only through an explicit decision
  by an admin, and only if it scores at least as well as the current model on
  the same held-out set. Nothing here promotes by itself.
- Going back to an earlier production model is one request: its weights and
  its records are still here, so no code has to be deployed.
- Evaluation records and decisions are never changed or deleted; the
  database refuses (migration 0013).
"""

import base64
import binascii
import hashlib
import json
import uuid
from typing import Any

from fastapi import status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit, classifier, clock, errors, scoring
from app.model_schemas import (
    EvaluationIn,
    EvaluationOut,
    ModelOut,
    ModelRegistration,
    PromotionOut,
    RegistryOut,
)
from app.models import Account, ModelEvaluation, ModelPromotion, ScoringModel
from app.schemas import PersonRef

RULE, CLASSIFIER = "rule", "classifier"
CANDIDATE, PRODUCTION, RETIRED = "candidate", "production", "retired"
SPLIT_NAMES = ("train", "val", "test")


def _refuse(code: str, message: str, **extra: Any) -> errors.ApiError:
    return errors.ApiError(status.HTTP_422_UNPROCESSABLE_CONTENT, code, message, **extra)


def production(db: Session) -> ScoringModel:
    """The model that scores sessions started now."""
    return db.execute(select(ScoringModel).where(ScoringModel.status == PRODUCTION)).scalar_one()


def get(db: Session, version: str | None) -> ScoringModel | None:
    return db.get(ScoringModel, version) if version else None


def scorer_for(db: Session, exercise_slug: str) -> str:
    """The version that is to score a session of this exercise starting now:
    the production model, or the rule when the production model was not
    trained on this exercise."""
    model = production(db)
    if model.kind == CLASSIFIER and exercise_slug not in model.record["training_data"]["exercises"]:
        return scoring.VERSION
    return model.version


def classifier_of(db: Session, version: str | None) -> classifier.Classifier | None:
    """The classifier registered under this version, ready to run. None for
    the rule and for a version that is not registered."""
    model = get(db, version)
    if model is None or model.kind != CLASSIFIER:
        return None
    return classifier.cached(model.weights_sha256, lambda: model.weights)


def eval_set_of(record: dict[str, Any]) -> str:
    """Names the held-out set a training record was scored on."""
    return classifier.eval_set_name(record["training_data"])


def _subjects(splits_text: str) -> dict[str, list[int]]:
    try:
        subjects = json.loads(splits_text)["subjects"]
        return {name: [int(p) for p in subjects[name]] for name in SPLIT_NAMES}
    except (ValueError, KeyError, TypeError) as exc:
        raise _refuse("splits_unreadable", "The splits file could not be read.") from exc


def _metrics(metrics: dict[str, Any]) -> tuple[float, float | None, int]:
    try:
        agreement = float(metrics["agreement"])
        repetitions = int(metrics["repetitions"])
        balanced = metrics.get("balanced_accuracy")
        balanced = None if balanced is None else float(balanced)
    except (KeyError, TypeError, ValueError) as exc:
        raise _refuse(
            "evaluation_incomplete",
            "The evaluation must say how many repetitions it covers and how often the model agreed.",
        ) from exc
    if not 0 <= agreement <= 1 or repetitions < 1:
        raise _refuse("evaluation_incomplete", "The evaluation's numbers are not usable.")
    return agreement, balanced, repetitions


def register(db: Session, admin: Account, sent: ModelRegistration, ip: str | None) -> ScoringModel:
    record = sent.record
    try:
        version = str(record["model_version"])
        training = record["training_data"]
        splits_sha = str(training["splits_sha256"])
        eval_set = eval_set_of(record)
        test = record["test"]
    except (KeyError, TypeError) as exc:
        # No held-out evaluation, no model: US 4.1's failure criterion.
        raise _refuse(
            "record_incomplete",
            "The record must name the model, the data it was trained on and its held-out test results.",
        ) from exc
    if not version or len(version) > 80:
        raise _refuse("record_incomplete", "The model's version is missing or too long.")
    agreement, balanced, repetitions = _metrics(test)

    # The splits the record points to, checked rather than trusted.
    if hashlib.sha256(sent.splits.encode()).hexdigest() != splits_sha:
        raise _refuse(
            "splits_mismatch",
            "These are not the splits this model was trained with: the checksum in its record differs.",
        )
    subjects = _subjects(sent.splits)
    seen: dict[int, str] = {}
    for name in SPLIT_NAMES:
        for person in subjects[name]:
            if person in seen:
                raise _refuse(
                    "subject_in_two_splits",
                    f"Subject {person} is in both the {seen[person]} and the {name} split. "
                    "A model tested on people it was trained on cannot be registered.",
                )
            seen[person] = name
    if not subjects["train"] or not subjects["test"]:
        raise _refuse("splits_unreadable", "The splits need train and test subjects.")

    try:
        weights = base64.b64decode(sent.weights_b64, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise _refuse("weights_unreadable", "The weights could not be decoded.") from exc
    if classifier.sha256(weights) != sent.weights_sha256:
        raise _refuse("weights_mismatch", "The weights do not match their checksum.")
    try:
        model = classifier.load(weights)
    except classifier.ModelFormatError as exc:
        raise _refuse("weights_unreadable", str(exc)) from exc
    if list(model.channels) != list(training.get("channels", [])) or list(model.exercises) != list(
        training.get("exercises", [])
    ):
        raise _refuse("weights_mismatch", "The weights were not made from the model this record describes.")
    if model.source_sha256 != record.get("weights_sha256") or model.steps != training.get("steps"):
        raise _refuse("weights_mismatch", "The weights were not made from the model this record describes.")

    if db.get(ScoringModel, version) is not None:
        raise errors.conflict("model_exists", f"{version} is already registered.")

    now = clock.utcnow()
    row = ScoringModel(
        version=version,
        kind=CLASSIFIER,
        status=CANDIDATE,
        record=record,
        weights=weights,
        weights_sha256=sent.weights_sha256,
        registered_at=now,
        registered_by=admin.id,
    )
    db.add(row)
    db.flush()
    db.add(
        ModelEvaluation(
            id=uuid.uuid4(),
            model_version=version,
            eval_set=eval_set,
            agreement=agreement,
            balanced_accuracy=balanced,
            repetitions=repetitions,
            metrics=test,
            source="training_record",
            created_at=now,
            recorded_by=admin.id,
        )
    )
    audit.record(
        db,
        "model.registered",
        actor_id=admin.id,
        target_type="scoring_model",
        target_id=version,
        detail={"eval_set": eval_set, "agreement": agreement, "weights_sha256": sent.weights_sha256},
        ip=ip,
    )
    db.commit()
    return row


def add_evaluation(
    db: Session, admin: Account, version: str, sent: EvaluationIn, ip: str | None
) -> ModelEvaluation:
    """Adds one more evaluation of a registered model, for instance of the
    current model on the set a new candidate was tested on."""
    model = db.get(ScoringModel, version)
    if model is None:
        raise errors.not_found("Model not found.")
    if sent.model_version != version:
        raise _refuse(
            "evaluation_of_another_model", f"This evaluation is of {sent.model_version}, not {version}."
        )
    agreement, balanced, repetitions = _metrics(sent.metrics)
    evaluation = ModelEvaluation(
        id=uuid.uuid4(),
        model_version=version,
        eval_set=sent.eval_set,
        agreement=agreement,
        balanced_accuracy=balanced,
        repetitions=repetitions,
        metrics=sent.metrics,
        source="uploaded",
        created_at=clock.utcnow(),
        recorded_by=admin.id,
    )
    db.add(evaluation)
    audit.record(
        db,
        "model.evaluated",
        actor_id=admin.id,
        target_type="scoring_model",
        target_id=version,
        detail={"eval_set": sent.eval_set, "agreement": agreement, "repetitions": repetitions},
        ip=ip,
    )
    db.commit()
    return evaluation


def _latest(db: Session, version: str, eval_set: str | None = None) -> ModelEvaluation | None:
    query = select(ModelEvaluation).where(ModelEvaluation.model_version == version)
    if eval_set is not None:
        query = query.where(ModelEvaluation.eval_set == eval_set)
    return db.execute(query.order_by(ModelEvaluation.created_at.desc()).limit(1)).scalar_one_or_none()


def promote(db: Session, admin: Account, version: str, reason: str, ip: str | None) -> ModelPromotion:
    """Makes a candidate the production model, if it earns it: an admin's
    explicit decision, backed by both models scored on the same held-out
    set."""
    candidate = db.execute(
        select(ScoringModel).where(ScoringModel.version == version).with_for_update()
    ).scalar_one_or_none()
    if candidate is None:
        raise errors.not_found("Model not found.")
    incumbent = db.execute(
        select(ScoringModel).where(ScoringModel.status == PRODUCTION).with_for_update()
    ).scalar_one()
    if candidate.version == incumbent.version:
        raise errors.conflict("already_production", f"{version} is already the production model.")

    evaluation = _latest(db, candidate.version)
    if evaluation is None:
        # Never deployed without a recorded evaluation against held-out data.
        raise errors.conflict(
            "not_evaluated", f"{version} has no evaluation against held-out data, so it cannot be promoted."
        )
    incumbent_evaluation = _latest(db, incumbent.version, evaluation.eval_set)
    if incumbent_evaluation is None:
        raise errors.conflict(
            "incumbent_not_evaluated",
            f"The current model, {incumbent.version}, has not been evaluated on the same held-out set "
            f"({evaluation.eval_set}). Evaluate it there first, so the two can be compared.",
            eval_set=evaluation.eval_set,
        )
    if evaluation.agreement < incumbent_evaluation.agreement:
        raise errors.conflict(
            "not_better",
            f"{version} agrees with the expert labels {evaluation.agreement:.1%} of the time; the current "
            f"model, {incumbent.version}, {incumbent_evaluation.agreement:.1%} on the same set. "
            "A candidate must do at least as well to be promoted.",
            agreement=evaluation.agreement,
            incumbent_agreement=incumbent_evaluation.agreement,
        )

    incumbent.status = RETIRED
    db.flush()
    candidate.status = PRODUCTION
    decision = ModelPromotion(
        id=uuid.uuid4(),
        action="promote",
        model_version=candidate.version,
        previous_version=incumbent.version,
        evaluation_id=evaluation.id,
        incumbent_evaluation_id=incumbent_evaluation.id,
        reason=reason.strip(),
        decided_by=admin.id,
        created_at=clock.utcnow(),
    )
    db.add(decision)
    audit.record(
        db,
        "model.promoted",
        actor_id=admin.id,
        target_type="scoring_model",
        target_id=candidate.version,
        detail={
            "previous": incumbent.version,
            "eval_set": evaluation.eval_set,
            "agreement": evaluation.agreement,
            "incumbent_agreement": incumbent_evaluation.agreement,
            "reason": reason.strip(),
        },
        ip=ip,
    )
    db.commit()
    return decision


def rollback(
    db: Session, admin: Account, reason: str, to_version: str | None, ip: str | None
) -> ModelPromotion:
    """Puts an earlier production model back. Everything it needs is already
    stored, so this is immediate and needs no deployment."""
    current = db.execute(
        select(ScoringModel).where(ScoringModel.status == PRODUCTION).with_for_update()
    ).scalar_one()
    if to_version is None:
        last = db.execute(
            select(ModelPromotion)
            .where(ModelPromotion.model_version == current.version)
            .order_by(ModelPromotion.created_at.desc())
            .limit(1)
        ).scalar_one_or_none()
        to_version = last.previous_version if last else None
        if to_version is None:
            raise errors.conflict(
                "nothing_to_roll_back_to", "There is no earlier production model to go back to."
            )
    target = db.execute(
        select(ScoringModel).where(ScoringModel.version == to_version).with_for_update()
    ).scalar_one_or_none()
    if target is None:
        raise errors.not_found("Model not found.")
    if target.version == current.version:
        raise errors.conflict("already_production", f"{to_version} is already the production model.")
    if target.status != RETIRED:
        # A candidate has to pass the gate; only a model that was production
        # before can be put back without it.
        raise errors.conflict(
            "never_production",
            f"{to_version} has never been the production model. Promote it instead; that compares it "
            "with the current one first.",
        )

    current.status = RETIRED
    db.flush()
    target.status = PRODUCTION
    decision = ModelPromotion(
        id=uuid.uuid4(),
        action="rollback",
        model_version=target.version,
        previous_version=current.version,
        reason=reason.strip(),
        decided_by=admin.id,
        created_at=clock.utcnow(),
    )
    db.add(decision)
    audit.record(
        db,
        "model.rolled_back",
        actor_id=admin.id,
        target_type="scoring_model",
        target_id=target.version,
        detail={"previous": current.version, "reason": reason.strip()},
        ip=ip,
    )
    db.commit()
    return decision


def _people(db: Session, ids: set[uuid.UUID | None]) -> dict[uuid.UUID, PersonRef]:
    wanted = {i for i in ids if i is not None}
    if not wanted:
        return {}
    return {
        account.id: PersonRef.model_validate(account)
        for account in db.execute(select(Account).where(Account.id.in_(wanted))).scalars()
    }


def overview(db: Session) -> RegistryOut:
    models = list(db.execute(select(ScoringModel).order_by(ScoringModel.registered_at.desc())).scalars())
    evaluations = list(
        db.execute(select(ModelEvaluation).order_by(ModelEvaluation.created_at.desc())).scalars()
    )
    decisions = list(db.execute(select(ModelPromotion).order_by(ModelPromotion.created_at.desc())).scalars())
    people = _people(
        db,
        {m.registered_by for m in models}
        | {e.recorded_by for e in evaluations}
        | {d.decided_by for d in decisions},
    )
    by_id = {e.id: e for e in evaluations}

    def evaluation_out(e: ModelEvaluation) -> EvaluationOut:
        return EvaluationOut(
            id=e.id,
            eval_set=e.eval_set,
            agreement=e.agreement,
            balanced_accuracy=e.balanced_accuracy,
            repetitions=e.repetitions,
            source=e.source,
            created_at=e.created_at,
            recorded_by=people.get(e.recorded_by),
        )

    def decision_out(d: ModelPromotion) -> PromotionOut:
        own = by_id.get(d.evaluation_id)
        other = by_id.get(d.incumbent_evaluation_id)
        return PromotionOut(
            id=d.id,
            action=d.action,
            model_version=d.model_version,
            previous_version=d.previous_version,
            reason=d.reason,
            decided_by=people.get(d.decided_by),
            created_at=d.created_at,
            eval_set=own.eval_set if own else None,
            agreement=own.agreement if own else None,
            incumbent_agreement=other.agreement if other else None,
        )

    return RegistryOut(
        production=next(m.version for m in models if m.status == PRODUCTION),
        models=[
            ModelOut(
                version=m.version,
                kind=m.kind,
                status=m.status,
                registered_at=m.registered_at,
                registered_by=people.get(m.registered_by),
                description=m.record.get("description") or m.record.get("architecture"),
                training_data=m.record.get("training_data"),
                target_agreement=m.record.get("target_agreement"),
                evaluations=[evaluation_out(e) for e in evaluations if e.model_version == m.version],
            )
            for m in models
        ],
        history=[decision_out(d) for d in decisions],
    )
