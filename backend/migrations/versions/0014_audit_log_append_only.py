"""the audit log is append-only

Revision ID: 0014
Revises: 0013
Create Date: 2026-10-14

"""

from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = "0014"
down_revision: Union[str, Sequence[str], None] = "0013"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    """Upgrade schema."""
    # US 8.3: an audit entry is never edited or deleted, by any role. The
    # database refuses it itself, with the function migration 0013 added for
    # the model registry's records, so no endpoint or mistake in the API can
    # change what the log says happened.
    op.execute(
        "CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log "
        "FOR EACH ROW EXECUTE FUNCTION refuse_change()"
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.execute("DROP TRIGGER audit_log_append_only ON audit_log")
