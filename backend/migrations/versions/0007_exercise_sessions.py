"""exercise sessions

Revision ID: 0007
Revises: 0006
Create Date: 2026-10-09

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '0007'
down_revision: Union[str, Sequence[str], None] = '0006'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('exercise_sessions',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('patient_id', sa.Uuid(), nullable=False),
    sa.Column('plan_id', sa.Uuid(), nullable=False),
    sa.Column('plan_exercise_id', sa.Uuid(), nullable=False),
    sa.Column('exercise_template_id', sa.Uuid(), nullable=False),
    sa.Column('template_version', sa.Integer(), nullable=False),
    sa.Column('checks', sa.JSON(), nullable=False),
    sa.Column('prescription_revision', sa.Integer(), nullable=False),
    sa.Column('sets', sa.Integer(), nullable=False),
    sa.Column('reps', sa.Integer(), nullable=False),
    sa.Column('rest_seconds', sa.Integer(), nullable=False),
    sa.Column('difficulty', sa.String(length=10), nullable=False),
    sa.Column('status', sa.String(length=12), nullable=False),
    sa.Column('started_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('ended_at', sa.DateTime(timezone=True), nullable=True),
    sa.Column('precheck', sa.JSON(), nullable=False),
    sa.CheckConstraint("status IN ('active', 'completed', 'abandoned')", name='ck_exercise_sessions_status'),
    sa.ForeignKeyConstraint(['exercise_template_id'], ['exercise_templates.id'], ),
    sa.ForeignKeyConstraint(['patient_id'], ['accounts.id'], ),
    sa.ForeignKeyConstraint(['plan_exercise_id'], ['plan_exercises.id'], ),
    sa.ForeignKeyConstraint(['plan_id'], ['exercise_plans.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_exercise_sessions_patient', 'exercise_sessions', ['patient_id', 'started_at'], unique=False)
    op.create_index('uq_exercise_sessions_active', 'exercise_sessions', ['patient_id'], unique=True, postgresql_where=sa.text("status = 'active'"))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index('uq_exercise_sessions_active', table_name='exercise_sessions', postgresql_where=sa.text("status = 'active'"))
    op.drop_index('ix_exercise_sessions_patient', table_name='exercise_sessions')
    op.drop_table('exercise_sessions')
