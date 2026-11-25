"""a patient's own reference repetitions for an exercise

Revision ID: 0016
Revises: 0015
Create Date: 2026-11-24

In REHAB24-6 each person was asked to make a different mistake, so a model
that judges people it has never seen does little better than chance on some
exercises. Judging a repetition against two of the patient's own repetitions
that a physiotherapist saw done correctly scored 79.7% on the test subjects,
against 63.3% for the classifier on the same repetitions (ml/README.md).

- exercise_references: the patient's reference per exercise, kept when
  replaced (retired_at), with row-level security like every other table of
  patient data.
- session_repetitions.series: the resampled joint angles of a session's
  first repetitions, so a reference can be made from them; and
  reference_distance, how far a repetition was from the reference.
- exercise_sessions.reference_id: the reference a session was judged against.
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0016"
down_revision: Union[str, Sequence[str], None] = "0015"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

ROLE = "physioai_app"
_SEES_PATIENT = "app_can_see_patient(patient_id)"


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "exercise_references",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("patient_id", sa.Uuid(), nullable=False),
        sa.Column("exercise_template_id", sa.Uuid(), nullable=False),
        sa.Column("repetition_ids", sa.JSON(), nullable=False),
        sa.Column("series", sa.JSON(), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("retired_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("retired_by", sa.Uuid(), nullable=True),
        sa.ForeignKeyConstraint(["patient_id"], ["accounts.id"]),
        sa.ForeignKeyConstraint(["exercise_template_id"], ["exercise_templates.id"]),
        sa.ForeignKeyConstraint(["created_by"], ["accounts.id"]),
        sa.ForeignKeyConstraint(["retired_by"], ["accounts.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "uq_exercise_references_current",
        "exercise_references",
        ["patient_id", "exercise_template_id"],
        unique=True,
        postgresql_where=sa.text("retired_at IS NULL"),
    )
    op.execute(f"GRANT SELECT, INSERT, UPDATE, DELETE ON exercise_references TO {ROLE}")
    op.execute("ALTER TABLE exercise_references ENABLE ROW LEVEL SECURITY")
    op.execute(
        "CREATE POLICY exercise_references_isolation ON exercise_references "
        f"USING ({_SEES_PATIENT}) WITH CHECK ({_SEES_PATIENT})"
    )

    op.add_column("session_repetitions", sa.Column("series", sa.JSON(), nullable=True))
    op.add_column("session_repetitions", sa.Column("reference_distance", sa.Float(), nullable=True))
    op.add_column("exercise_sessions", sa.Column("reference_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_exercise_sessions_reference", "exercise_sessions", "exercise_references", ["reference_id"], ["id"]
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_constraint("fk_exercise_sessions_reference", "exercise_sessions", type_="foreignkey")
    op.drop_column("exercise_sessions", "reference_id")
    op.drop_column("session_repetitions", "reference_distance")
    op.drop_column("session_repetitions", "series")
    op.drop_index("uq_exercise_references_current", table_name="exercise_references")
    op.drop_table("exercise_references")
