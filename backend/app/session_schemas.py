import math
import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator, model_validator

from app import pose
from app.exercise_schemas import ExerciseBrief, SeverityCheck
from app.schemas import PersonRef

# Longest session the app will describe a repetition in: six hours.
MAX_SESSION_MS = 6 * 60 * 60 * 1000


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


class FeedbackItem(BaseModel):
    """What one check found in a repetition, at INFO or above."""

    check: str
    label: str
    # info | amber | red
    tier: str
    value: float
    unit: str
    message: str


class PauseOut(BaseModel):
    """Why a session is paused. It resumes when this repetition is acknowledged."""

    repetition_id: uuid.UUID
    check: str
    message: str


class SessionTotals(BaseModel):
    repetitions: int = 0
    ok: int = 0
    info: int = 0
    amber: int = 0
    red: int = 0


class RepetitionIn(BaseModel):
    """One repetition the app counted. It carries measurements only: the
    server decides how serious they are."""

    # Made by the app once per repetition, so a retry stores nothing new.
    client_key: uuid.UUID
    set_number: int = Field(ge=1, le=50)
    rep_number: int = Field(ge=1, le=200)
    # Milliseconds since the session started, on the device's clock.
    started_ms: int = Field(ge=0, le=MAX_SESSION_MS)
    ended_ms: int = Field(ge=0, le=MAX_SESSION_MS)
    # Check key -> worst value seen during the repetition, in the check's own
    # unit; null when the body parts it needs were not clearly in view.
    measures: dict[str, float | None] = Field(max_length=20)

    @field_validator("measures")
    @classmethod
    def _real_numbers(cls, value: dict[str, float | None]) -> dict[str, float | None]:
        for key, measured in value.items():
            if measured is not None and (not math.isfinite(measured) or abs(measured) > 10_000):
                raise ValueError(f"The measure for {key} is not a usable number.")
        return value

    @model_validator(mode="after")
    def _ends_after_it_starts(self) -> "RepetitionIn":
        if self.ended_ms < self.started_ms:
            raise ValueError("A repetition cannot end before it starts.")
        return self


class RepetitionOut(BaseModel):
    id: uuid.UUID
    set_number: int
    rep_number: int
    started_ms: int
    ended_ms: int
    # ok | info | amber | red: the worst of the repetition's checks.
    tier: str
    feedback: list[FeedbackItem]
    # Checks that could not be measured in this repetition.
    unmeasured: list[str]
    # active | paused
    session_status: str
    pause: PauseOut | None


class Acknowledge(BaseModel):
    repetition_id: uuid.UUID


class PreviousSession(BaseModel):
    """The session of the same exercise before this one, for the comparison."""

    id: uuid.UUID
    ended_at: datetime
    repetitions: int
    # None when that session had nothing to score.
    form_score: int | None


class SessionSummary(BaseModel):
    """What a finished session came to (US 4.2). It is built only once the
    session has ended, from repetitions the server has already classified."""

    duration_seconds: int
    totals: SessionTotals
    # 0 to 100. None, never 0, when no repetition could be scored.
    form_score: int | None
    # How many repetitions the score is based on.
    scored_repetitions: int
    # Which rule or model produced the score.
    scoring_version: str | None
    previous: PreviousSession | None
    # This score minus the previous one; None when either is missing.
    score_change: int | None


class SessionBrief(BaseModel):
    """One finished session in a list: the history (US 5.1) and the
    physiotherapist's views (US 5.2)."""

    id: uuid.UUID
    # completed | abandoned, or active | paused in a physiotherapist's queue
    # when a RED repetition flagged a session the patient is still in.
    status: str
    started_at: datetime
    ended_at: datetime | None
    exercise: ExerciseBrief
    sets: int
    reps: int
    duration_seconds: int
    totals: SessionTotals
    form_score: int | None
    scoring_version: str | None
    # red | low_score; empty when the session was not flagged.
    flag_reasons: list[str]
    reviewed_at: datetime | None


class RepetitionDetail(BaseModel):
    set_number: int
    rep_number: int
    started_ms: int
    ended_ms: int
    tier: str
    feedback: list[FeedbackItem]
    unmeasured: list[str]


class SessionDetail(SessionBrief):
    """Everything about one finished session."""

    difficulty: str
    rest_seconds: int
    checks: list[SeverityCheck]
    scored_repetitions: int | None
    repetitions: list[RepetitionDetail]


class FlaggedSession(BaseModel):
    """A session in a physiotherapist's flagged queue (US 5.2)."""

    session: SessionBrief
    patient: PersonRef
    flagged_at: datetime
    # The score threshold in force when it was flagged for a low score.
    flag_threshold: int | None
    reviewed_by: PersonRef | None


class SessionOut(BaseModel):
    id: uuid.UUID
    # active | paused | completed | abandoned
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
    # The thresholds this session is judged against: its own copy, taken when
    # it started.
    checks: list[SeverityCheck]
    totals: SessionTotals
    pause: PauseOut | None
    # Set once the session has ended.
    summary: SessionSummary | None = None
