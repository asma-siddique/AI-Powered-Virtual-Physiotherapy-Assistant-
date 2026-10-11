"""plan frequency, reminder settings and sent reminders

Revision ID: 0011
Revises: 0010
Create Date: 2026-10-11

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0011"
down_revision: Union[str, Sequence[str], None] = "0010"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # Plans made before a frequency could be prescribed are treated as daily.
    op.add_column(
        "exercise_plans",
        sa.Column("frequency_days", sa.JSON(), nullable=False, server_default="[0, 1, 2, 3, 4, 5, 6]"),
    )
    op.create_table(
        "reminder_settings",
        sa.Column("patient_id", sa.Uuid(), nullable=False),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("time_minutes", sa.Integer(), nullable=False),
        sa.Column("utc_offset_minutes", sa.Integer(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("time_minutes BETWEEN 0 AND 1439", name="ck_reminder_settings_time"),
        sa.CheckConstraint(
            "utc_offset_minutes IS NULL OR utc_offset_minutes BETWEEN -720 AND 840",
            name="ck_reminder_settings_offset",
        ),
        sa.ForeignKeyConstraint(["patient_id"], ["accounts.id"]),
        sa.PrimaryKeyConstraint("patient_id"),
    )
    op.create_table(
        "session_reminders",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("plan_id", sa.Uuid(), nullable=False),
        sa.Column("patient_id", sa.Uuid(), nullable=False),
        sa.Column("local_date", sa.Date(), nullable=False),
        sa.Column("sent_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(["patient_id"], ["accounts.id"]),
        sa.ForeignKeyConstraint(["plan_id"], ["exercise_plans.id"]),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("plan_id", "local_date", name="uq_session_reminders_plan_day"),
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table("session_reminders")
    op.drop_table("reminder_settings")
    op.drop_column("exercise_plans", "frequency_days")
