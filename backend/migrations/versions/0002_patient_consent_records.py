"""patient consent records

Revision ID: 0002
Revises: 0001
Create Date: 2026-10-08

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '0002'
down_revision: Union[str, Sequence[str], None] = '0001'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table('consents',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('account_id', sa.Uuid(), nullable=False),
    sa.Column('disclaimer_version', sa.String(length=20), nullable=False),
    sa.Column('acknowledged_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('ip', sa.String(length=45), nullable=True),
    sa.Column('user_agent', sa.String(length=255), nullable=True),
    sa.ForeignKeyConstraint(['account_id'], ['accounts.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('account_id', 'disclaimer_version', name='uq_consents_account_version')
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table('consents')
