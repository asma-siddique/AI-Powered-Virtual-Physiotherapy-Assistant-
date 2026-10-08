"""prescription edits and revisions

Revision ID: 0006
Revises: 0005
Create Date: 2026-10-09

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '0006'
down_revision: Union[str, Sequence[str], None] = '0005'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column('plan_exercises', sa.Column('revision', sa.Integer(), server_default='1', nullable=False))
    op.add_column('plan_exercises', sa.Column('updated_at', sa.DateTime(timezone=True), nullable=True))
    op.create_table('prescription_edits',
    sa.Column('id', sa.BigInteger(), sa.Identity(always=False), nullable=False),
    sa.Column('plan_id', sa.Uuid(), nullable=False),
    sa.Column('plan_exercise_id', sa.Uuid(), nullable=False),
    sa.Column('edited_by', sa.Uuid(), nullable=False),
    sa.Column('edited_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('revision', sa.Integer(), nullable=False),
    sa.Column('changes', sa.JSON(), nullable=False),
    sa.ForeignKeyConstraint(['edited_by'], ['accounts.id'], ),
    sa.ForeignKeyConstraint(['plan_exercise_id'], ['plan_exercises.id'], ),
    sa.ForeignKeyConstraint(['plan_id'], ['exercise_plans.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_prescription_edits_plan', 'prescription_edits', ['plan_id', 'edited_at'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index('ix_prescription_edits_plan', table_name='prescription_edits')
    op.drop_table('prescription_edits')
    op.drop_column('plan_exercises', 'updated_at')
    op.drop_column('plan_exercises', 'revision')
