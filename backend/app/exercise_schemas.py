import re
import uuid
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app import pose
from app.models import Difficulty
from app.schemas import PersonRef


class SeverityCheck(BaseModel):
    """One thing the system watches during an exercise, and how far it may
    deviate before feedback is INFO, AMBER or RED."""

    key: str = Field(pattern=r"^[a-z][a-z0-9_]{1,39}$")
    label: str = Field(min_length=2, max_length=60)
    measure: str = Field(min_length=2, max_length=160)
    unit: str = Field(min_length=1, max_length=20)
    info: float = Field(ge=0)
    amber: float
    # RED pauses the session, so it is left empty for checks that are never a
    # safety matter (for example not reaching full depth).
    red: float | None = None
    corrective_message: str = Field(min_length=5, max_length=200)

    @model_validator(mode="after")
    def _thresholds_increase(self) -> "SeverityCheck":
        if not self.info < self.amber or (self.red is not None and not self.amber < self.red):
            raise ValueError("Thresholds must increase: INFO below AMBER below RED.")
        return self


def _unique_check_keys(checks: list[SeverityCheck]) -> list[SeverityCheck]:
    keys = [check.key for check in checks]
    if len(keys) != len(set(keys)):
        raise ValueError("Each check needs its own key.")
    return checks


def _clean_joints(joints: list[str]) -> list[str]:
    cleaned = list(dict.fromkeys(joint.strip().lower() for joint in joints if joint.strip()))
    if not cleaned:
        raise ValueError("Name at least one target joint.")
    # The camera check looks for exactly these joints, so a name the pose model
    # does not have would quietly never be checked.
    unknown = [joint for joint in cleaned if joint not in pose.KNOWN_JOINTS]
    if unknown:
        raise ValueError(f"Choose target joints from: {', '.join(pose.KNOWN_JOINTS)}.")
    return cleaned


class ExerciseCreate(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    domain: str = Field(min_length=2, max_length=80)
    body_area: str = Field(min_length=2, max_length=30)
    primary_targets: str = Field(min_length=2, max_length=160)
    target_joints: list[str] = Field(min_length=1, max_length=12)
    movement_pattern: str = Field(min_length=10, max_length=600)
    instructions: str = Field(min_length=10, max_length=800)
    checks: list[SeverityCheck] = Field(min_length=1, max_length=8)

    @field_validator("target_joints")
    @classmethod
    def _joints(cls, value: list[str]) -> list[str]:
        return _clean_joints(value)

    @field_validator("checks")
    @classmethod
    def _checks(cls, value: list[SeverityCheck]) -> list[SeverityCheck]:
        return _unique_check_keys(value)


class ExerciseUpdate(BaseModel):
    """Only the fields that are sent are changed."""

    name: str | None = Field(default=None, min_length=2, max_length=80)
    domain: str | None = Field(default=None, min_length=2, max_length=80)
    body_area: str | None = Field(default=None, min_length=2, max_length=30)
    primary_targets: str | None = Field(default=None, min_length=2, max_length=160)
    target_joints: list[str] | None = Field(default=None, min_length=1, max_length=12)
    movement_pattern: str | None = Field(default=None, min_length=10, max_length=600)
    instructions: str | None = Field(default=None, min_length=10, max_length=800)
    checks: list[SeverityCheck] | None = Field(default=None, min_length=1, max_length=8)

    @field_validator("target_joints")
    @classmethod
    def _joints(cls, value: list[str] | None) -> list[str] | None:
        return None if value is None else _clean_joints(value)

    @field_validator("checks")
    @classmethod
    def _checks(cls, value: list[SeverityCheck] | None) -> list[SeverityCheck] | None:
        return None if value is None else _unique_check_keys(value)


class ExerciseOut(BaseModel):
    """Full template, including thresholds. Admins only."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    slug: str
    name: str
    domain: str
    body_area: str
    primary_targets: str
    target_joints: list[str]
    movement_pattern: str
    instructions: str
    checks: list[SeverityCheck]
    is_active: bool
    version: int
    updated_at: datetime


class ExerciseBrief(BaseModel):
    """What a physiotherapist picks from and a patient reads: no thresholds."""

    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    domain: str
    body_area: str
    primary_targets: str
    target_joints: list[str]
    instructions: str
    is_active: bool


class PlanItemIn(BaseModel):
    exercise_id: uuid.UUID
    sets: int = Field(ge=1, le=10)
    reps: int = Field(ge=1, le=50)
    rest_seconds: int = Field(default=60, ge=0, le=600)
    difficulty: Difficulty = Difficulty.medium
    note: str | None = Field(default=None, max_length=200)

    @field_validator("note")
    @classmethod
    def _blank_note_is_none(cls, value: str | None) -> str | None:
        return (value or "").strip() or None


class PlanCreate(BaseModel):
    name: str = Field(default="Exercise plan", min_length=2, max_length=80)
    items: list[PlanItemIn] = Field(min_length=1, max_length=12)

    @field_validator("name")
    @classmethod
    def _tidy_name(cls, value: str) -> str:
        return re.sub(r"\s+", " ", value).strip()

    @field_validator("items")
    @classmethod
    def _each_exercise_once(cls, items: list[PlanItemIn]) -> list[PlanItemIn]:
        ids = [item.exercise_id for item in items]
        if len(ids) != len(set(ids)):
            raise ValueError("Add each exercise to a plan only once.")
        return items


class PrescriptionUpdate(BaseModel):
    """An edit to one exercise of a patient's current plan. Only the fields
    that are sent change; an empty note removes the note."""

    sets: int | None = Field(default=None, ge=1, le=10)
    reps: int | None = Field(default=None, ge=1, le=50)
    rest_seconds: int | None = Field(default=None, ge=0, le=600)
    difficulty: Difficulty | None = None
    note: str | None = Field(default=None, max_length=200)

    @field_validator("note")
    @classmethod
    def _blank_note_is_none(cls, value: str | None) -> str | None:
        return (value or "").strip() or None

    @model_validator(mode="after")
    def _numbers_cannot_be_removed(self) -> "PrescriptionUpdate":
        for field in ("sets", "reps", "rest_seconds", "difficulty"):
            if field in self.model_fields_set and getattr(self, field) is None:
                raise ValueError(f"{field} cannot be empty.")
        return self


class PlanItemOut(BaseModel):
    id: uuid.UUID
    position: int
    exercise: ExerciseBrief
    sets: int
    reps: int
    rest_seconds: int
    difficulty: Difficulty
    note: str | None
    # 1 as assigned, one higher for every edit since.
    revision: int
    # When the prescription was last edited; empty if it never was.
    updated_at: datetime | None


class FieldChange(BaseModel):
    # sets | reps | rest_seconds | difficulty | note
    field: str
    before: int | str | None
    after: int | str | None


class PrescriptionEditOut(BaseModel):
    id: int
    item_id: uuid.UUID
    exercise_name: str
    edited_at: datetime
    edited_by: PersonRef
    # The revision of the prescription this edit produced.
    revision: int
    changes: list[FieldChange]


class PlanOut(BaseModel):
    id: uuid.UUID
    name: str
    created_at: datetime
    archived_at: datetime | None
    is_active: bool
    assigned_by: PersonRef
    items: list[PlanItemOut]
    # True when an exercise in this plan has since been deactivated by an admin.
    has_inactive_exercise: bool
