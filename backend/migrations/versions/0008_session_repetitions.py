"""session repetitions and the paused state

Revision ID: 0008
Revises: 0007
Create Date: 2026-10-10

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0008"
down_revision: Union[str, Sequence[str], None] = "0007"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "session_repetitions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("client_key", sa.Uuid(), nullable=False),
        sa.Column("set_number", sa.Integer(), nullable=False),
        sa.Column("rep_number", sa.Integer(), nullable=False),
        sa.Column("started_ms", sa.Integer(), nullable=False),
        sa.Column("ended_ms", sa.Integer(), nullable=False),
        sa.Column("measures", sa.JSON(), nullable=False),
        sa.Column("tier", sa.String(length=8), nullable=False),
        sa.Column("feedback", sa.JSON(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("tier IN ('ok', 'info', 'amber', 'red')", name="ck_session_repetitions_tier"),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["exercise_sessions.id"],
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("session_id", "client_key", name="uq_session_repetitions_key"),
        sa.UniqueConstraint("session_id", "set_number", "rep_number", name="uq_session_repetitions_place"),
    )
    op.create_index(
        "ix_session_repetitions_session", "session_repetitions", ["session_id", "created_at"], unique=False
    )

    # A session can now be paused by a RED repetition. A paused session is
    # still the patient's one session under way.
    op.drop_constraint("ck_exercise_sessions_status", "exercise_sessions", type_="check")
    op.create_check_constraint(
        "ck_exercise_sessions_status",
        "exercise_sessions",
        "status IN ('active', 'paused', 'completed', 'abandoned')",
    )
    op.drop_index(
        "uq_exercise_sessions_active",
        table_name="exercise_sessions",
        postgresql_where=sa.text("status = 'active'"),
    )
    op.create_index(
        "uq_exercise_sessions_active",
        "exercise_sessions",
        ["patient_id"],
        unique=True,
        postgresql_where=sa.text("status IN ('active', 'paused')"),
    )


def downgrade() -> None:
    """Downgrade schema."""
    # A paused session has no meaning without the repetitions that paused it.
    op.execute(
        "UPDATE exercise_sessions SET status = 'abandoned', ended_at = COALESCE(ended_at, now()) WHERE status = 'paused'"
    )
    op.drop_index(
        "uq_exercise_sessions_active",
        table_name="exercise_sessions",
        postgresql_where=sa.text("status IN ('active', 'paused')"),
    )
    op.create_index(
        "uq_exercise_sessions_active",
        "exercise_sessions",
        ["patient_id"],
        unique=True,
        postgresql_where=sa.text("status = 'active'"),
    )
    op.drop_constraint("ck_exercise_sessions_status", "exercise_sessions", type_="check")
    op.create_check_constraint(
        "ck_exercise_sessions_status",
        "exercise_sessions",
        "status IN ('active', 'completed', 'abandoned')",
    )
    op.drop_index("ix_session_repetitions_session", table_name="session_repetitions")
    op.drop_table("session_repetitions")
