"""pain ratings and notes on sessions

Revision ID: 0010
Revises: 0009
Create Date: 2026-10-11

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0010"
down_revision: Union[str, Sequence[str], None] = "0009"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # All optional: an empty pain rating means the patient did not answer.
    op.add_column("exercise_sessions", sa.Column("pain_before", sa.SmallInteger(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("pain_after", sa.SmallInteger(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("patient_note", sa.String(length=500), nullable=True))
    op.add_column("exercise_sessions", sa.Column("clinician_note", sa.String(length=2000), nullable=True))
    op.add_column("exercise_sessions", sa.Column("clinician_note_by", sa.Uuid(), nullable=True))
    op.add_column(
        "exercise_sessions", sa.Column("clinician_note_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.create_foreign_key(
        "fk_exercise_sessions_clinician_note_by",
        "exercise_sessions",
        "accounts",
        ["clinician_note_by"],
        ["id"],
    )
    op.create_check_constraint(
        "ck_exercise_sessions_pain",
        "exercise_sessions",
        "(pain_before IS NULL OR pain_before BETWEEN 0 AND 10) "
        "AND (pain_after IS NULL OR pain_after BETWEEN 0 AND 10)",
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_constraint("ck_exercise_sessions_pain", "exercise_sessions", type_="check")
    op.drop_constraint("fk_exercise_sessions_clinician_note_by", "exercise_sessions", type_="foreignkey")
    for column in (
        "clinician_note_at",
        "clinician_note_by",
        "clinician_note",
        "patient_note",
        "pain_after",
        "pain_before",
    ):
        op.drop_column("exercise_sessions", column)
