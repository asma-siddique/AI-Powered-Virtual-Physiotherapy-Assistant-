import enum
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    CheckConstraint,
    DateTime,
    Enum,
    ForeignKey,
    Identity,
    Index,
    Integer,
    String,
    Text,
    UniqueConstraint,
    text,
    true,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class Role(enum.StrEnum):
    patient = "patient"
    physiotherapist = "physiotherapist"
    admin = "admin"


class Account(Base):
    __tablename__ = "accounts"
    __table_args__ = (
        CheckConstraint("email IS NOT NULL OR mobile IS NOT NULL", name="ck_accounts_has_identifier"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    full_name: Mapped[str] = mapped_column(String(120))
    email: Mapped[str | None] = mapped_column(String(254), unique=True)
    mobile: Mapped[str | None] = mapped_column(String(20), unique=True)
    password_hash: Mapped[str] = mapped_column(String(255))
    # Exactly one role per account: a single NOT NULL column, never a join table.
    role: Mapped[Role] = mapped_column(
        Enum(Role, name="account_role", values_callable=lambda e: [m.value for m in e])
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=true())
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class PatientAssignment(Base):
    """Which physiotherapist is responsible for a patient. Rows are closed with
    ended_at instead of being overwritten, so reassignment keeps its history."""

    __tablename__ = "patient_assignments"
    __table_args__ = (
        Index(
            "uq_patient_assignments_active",
            "patient_id",
            unique=True,
            postgresql_where=text("ended_at IS NULL"),
        ),
        Index("ix_patient_assignments_physiotherapist", "physiotherapist_id"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    patient_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    physiotherapist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    assigned_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ended_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class InviteCode(Base):
    __tablename__ = "invite_codes"
    __table_args__ = (Index("ix_invite_codes_physiotherapist", "physiotherapist_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    code: Mapped[str] = mapped_column(String(16), unique=True)
    physiotherapist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    redeemed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    redeemed_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("accounts.id"))


class ConsentRecord(Base):
    """A patient's explicit acknowledgment of one version of the advisory.
    Rows are only ever added: a new version of the wording gets a new row."""

    __tablename__ = "consents"
    __table_args__ = (
        UniqueConstraint("account_id", "disclaimer_version", name="uq_consents_account_version"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    account_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    disclaimer_version: Mapped[str] = mapped_column(String(20))
    acknowledged_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    ip: Mapped[str | None] = mapped_column(String(45))
    user_agent: Mapped[str | None] = mapped_column(String(255))


class AuthSession(Base):
    """One signed-in device. Holds the hash of the current refresh token and the
    one it replaced, so a replayed old token can be detected."""

    __tablename__ = "auth_sessions"
    __table_args__ = (
        Index("ix_auth_sessions_account", "account_id"),
        Index("ix_auth_sessions_previous_hash", "previous_refresh_token_hash"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    account_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    refresh_token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    previous_refresh_token_hash: Mapped[str | None] = mapped_column(String(64))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    last_seen_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    user_agent: Mapped[str | None] = mapped_column(String(255))
    ip: Mapped[str | None] = mapped_column(String(45))


class LoginAttempt(Base):
    __tablename__ = "login_attempts"
    __table_args__ = (Index("ix_login_attempts_subject_time", "subject_key", "created_at"),)

    id: Mapped[int] = mapped_column(BigInteger, Identity(), primary_key=True)
    # "acct:<uuid>" for a real account, "ident:<sha256>" otherwise, so lockout
    # follows the account (not the IP) and behaves the same for unknown identifiers.
    subject_key: Mapped[str] = mapped_column(String(80))
    succeeded: Mapped[bool] = mapped_column(Boolean)
    ip: Mapped[str | None] = mapped_column(String(45))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class AuditLog(Base):
    __tablename__ = "audit_log"
    __table_args__ = (Index("ix_audit_log_created", "created_at"),)

    id: Mapped[int] = mapped_column(BigInteger, Identity(), primary_key=True)
    actor_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("accounts.id"))
    action: Mapped[str] = mapped_column(String(80), index=True)
    target_type: Mapped[str | None] = mapped_column(String(40))
    target_id: Mapped[str | None] = mapped_column(String(64))
    detail: Mapped[dict[str, Any]] = mapped_column(JSON, default=dict)
    ip: Mapped[str | None] = mapped_column(String(45))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Difficulty(enum.StrEnum):
    easy = "easy"
    medium = "medium"
    hard = "hard"


class ExerciseTemplate(Base):
    """One exercise the system can score: its clinical profile and the checks
    that decide RED / AMBER / INFO feedback. `version` goes up on every edit, so
    a session can record which version of the thresholds it was scored with and
    is never rescored when they change."""

    __tablename__ = "exercise_templates"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    slug: Mapped[str] = mapped_column(String(60), unique=True)
    name: Mapped[str] = mapped_column(String(80))
    domain: Mapped[str] = mapped_column(String(80))
    body_area: Mapped[str] = mapped_column(String(30))
    primary_targets: Mapped[str] = mapped_column(String(160))
    target_joints: Mapped[list[str]] = mapped_column(JSON)
    movement_pattern: Mapped[str] = mapped_column(Text)
    instructions: Mapped[str] = mapped_column(Text)
    checks: Mapped[list[dict[str, Any]]] = mapped_column(JSON)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, server_default=true())
    version: Mapped[int] = mapped_column(Integer, default=1, server_default="1")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ExercisePlan(Base):
    """A plan assigned to one patient. Assigning a new plan archives the old one
    (archived_at) instead of changing it, so the plan in force on any past date
    can be reconstructed."""

    __tablename__ = "exercise_plans"
    __table_args__ = (
        Index(
            "uq_exercise_plans_active",
            "patient_id",
            unique=True,
            postgresql_where=text("archived_at IS NULL"),
        ),
        Index("ix_exercise_plans_patient", "patient_id", "created_at"),
    )

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    patient_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    physiotherapist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    name: Mapped[str] = mapped_column(String(80))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class PlanExercise(Base):
    __tablename__ = "plan_exercises"
    __table_args__ = (UniqueConstraint("plan_id", "position", name="uq_plan_exercises_position"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    plan_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("exercise_plans.id"))
    exercise_template_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("exercise_templates.id"))
    position: Mapped[int] = mapped_column(Integer)
    sets: Mapped[int] = mapped_column(Integer)
    reps: Mapped[int] = mapped_column(Integer)
    rest_seconds: Mapped[int] = mapped_column(Integer)
    difficulty: Mapped[Difficulty] = mapped_column(
        Enum(Difficulty, name="plan_difficulty", values_callable=lambda e: [m.value for m in e])
    )
    note: Mapped[str | None] = mapped_column(String(200))


class Notification(Base):
    """Something a person should know about, shown in the app's notification
    list. Unread while read_at is empty."""

    __tablename__ = "notifications"
    __table_args__ = (Index("ix_notifications_recipient", "recipient_id", "created_at"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    recipient_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("accounts.id"))
    kind: Mapped[str] = mapped_column(String(40))
    title: Mapped[str] = mapped_column(String(120))
    body: Mapped[str] = mapped_column(String(400))
    # Where in the app this notification leads, e.g. "/patient/plan".
    link: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
