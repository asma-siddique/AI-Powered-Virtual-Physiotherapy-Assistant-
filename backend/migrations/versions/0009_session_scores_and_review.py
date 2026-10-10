"""session scores, flags and review

Revision ID: 0009
Revises: 0008
Create Date: 2026-10-10

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0009"
down_revision: Union[str, Sequence[str], None] = "0008"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # Sessions that ended before this migration keep an empty score: they are
    # shown as not scored rather than given a value nobody calculated.
    op.add_column("exercise_sessions", sa.Column("totals", sa.JSON(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("form_score", sa.Integer(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("scored_repetitions", sa.Integer(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("scoring_version", sa.String(length=20), nullable=True))
    op.add_column("exercise_sessions", sa.Column("flagged_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("exercise_sessions", sa.Column("flag_reasons", sa.JSON(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("flag_threshold", sa.Integer(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("reviewed_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("exercise_sessions", sa.Column("reviewed_by", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_exercise_sessions_reviewed_by", "exercise_sessions", "accounts", ["reviewed_by"], ["id"]
    )
    op.create_check_constraint(
        "ck_exercise_sessions_form_score",
        "exercise_sessions",
        "form_score IS NULL OR form_score BETWEEN 0 AND 100",
    )
    op.create_index(
        "ix_exercise_sessions_flagged",
        "exercise_sessions",
        ["flagged_at"],
        postgresql_where=sa.text("flagged_at IS NOT NULL"),
    )
    op.create_index(
        "ix_exercise_sessions_history",
        "exercise_sessions",
        ["patient_id", "exercise_template_id", "ended_at"],
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index("ix_exercise_sessions_history", table_name="exercise_sessions")
    op.drop_index("ix_exercise_sessions_flagged", table_name="exercise_sessions")
    op.drop_constraint("ck_exercise_sessions_form_score", "exercise_sessions", type_="check")
    op.drop_constraint("fk_exercise_sessions_reviewed_by", "exercise_sessions", type_="foreignkey")
    for column in (
        "reviewed_by",
        "reviewed_at",
        "flag_threshold",
        "flag_reasons",
        "flagged_at",
        "scoring_version",
        "scored_repetitions",
        "form_score",
        "totals",
    ):
        op.drop_column("exercise_sessions", column)
