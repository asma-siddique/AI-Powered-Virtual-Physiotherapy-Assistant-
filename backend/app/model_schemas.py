import uuid
from datetime import datetime
from typing import Any

from pydantic import BaseModel, Field

from app.schemas import PersonRef


class ModelRegistration(BaseModel):
    """A trained model as `python -m rehab.export` writes it (ml/): its
    training record, the subject-wise splits it was trained with, and the
    weights the API runs."""

    record: dict[str, Any]
    # The splits file exactly as it is on disk, so its checksum can be
    # compared with the one in the record.
    splits: str = Field(max_length=200_000)
    weights_b64: str = Field(max_length=8_000_000)
    weights_sha256: str = Field(min_length=64, max_length=64)


class EvaluationIn(BaseModel):
    """A model scored against a held-out set, as `python -m rehab.evaluate`
    writes it."""

    model_version: str = Field(max_length=80)
    # Names the held-out set, so two models can be compared on the same one.
    eval_set: str = Field(min_length=8, max_length=160)
    metrics: dict[str, Any]


class EvaluationOut(BaseModel):
    id: uuid.UUID
    eval_set: str
    # Share of repetitions where the model agreed with the expert label.
    agreement: float
    balanced_accuracy: float | None
    repetitions: int
    # training_record | uploaded
    source: str
    created_at: datetime
    recorded_by: PersonRef | None


class ModelOut(BaseModel):
    version: str
    # rule | classifier
    kind: str
    # candidate | production | retired
    status: str
    registered_at: datetime
    registered_by: PersonRef | None
    description: str | None
    # From the training record: the data it was trained on.
    training_data: dict[str, Any] | None
    target_agreement: float | None
    evaluations: list[EvaluationOut]


class PromotionIn(BaseModel):
    reason: str = Field(min_length=5, max_length=300)


class RollbackIn(BaseModel):
    reason: str = Field(min_length=5, max_length=300)
    # The earlier production model to go back to; the last one when not given.
    to_version: str | None = Field(default=None, max_length=80)


class PromotionOut(BaseModel):
    id: uuid.UUID
    # promote | rollback
    action: str
    model_version: str
    previous_version: str | None
    reason: str
    decided_by: PersonRef | None
    created_at: datetime
    # What the decision rested on: both models on the same held-out set.
    eval_set: str | None
    agreement: float | None
    incumbent_agreement: float | None


class RegistryOut(BaseModel):
    production: str
    models: list[ModelOut]
    history: list[PromotionOut]
