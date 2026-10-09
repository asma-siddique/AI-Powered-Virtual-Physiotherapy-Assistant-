import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator

from app import pose
from app.exercise_schemas import ExerciseBrief


class PrecheckRequirements(BaseModel):
    """What the camera has to show before a session with this exercise starts."""

    item_id: uuid.UUID
    exercise: ExerciseBrief
    sets: int
    reps: int
    rest_seconds: int
    difficulty: str
    # Pose landmarks that must be in view, by the pose model's names.
    required_landmarks: list[str]
    min_visibility: float
    min_brightness: float
    hold_ms: int


class PrecheckEvidence(BaseModel):
    """What the app measured while the setup held steady. The server judges it
    against the same thresholds; there is no "passed" flag to send."""

    # Average brightness of the picture, 0 (black) to 1 (white).
    brightness: float = Field(ge=0, le=1)
    # Landmark name to the lowest visibility seen during the hold, 0 to 1.
    visibility: dict[str, float] = Field(max_length=len(pose.LANDMARKS))
    # How long the setup stayed good, in milliseconds.
    held_ms: int = Field(ge=0, le=600_000)

    @field_validator("visibility")
    @classmethod
    def _known_landmarks(cls, value: dict[str, float]) -> dict[str, float]:
        for name, score in value.items():
            if name not in pose.LANDMARKS:
                raise ValueError(f"Unknown landmark: {name}")
            if not 0 <= score <= 1:
                raise ValueError("Visibility is a number from 0 to 1.")
        return value


class SessionStart(BaseModel):
    plan_exercise_id: uuid.UUID
    precheck: PrecheckEvidence


class SessionOut(BaseModel):
    id: uuid.UUID
    # active | completed | abandoned
    status: str
    started_at: datetime
    ended_at: datetime | None
    exercise: ExerciseBrief
    # The prescription as it was when the session started.
    sets: int
    reps: int
    rest_seconds: int
    difficulty: str
    prescription_revision: int
    template_version: int
    required_landmarks: list[str]
