"""model registry, evaluation records and promotions

Revision ID: 0013
Revises: 0012
Create Date: 2026-10-11

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0013"
down_revision: Union[str, Sequence[str], None] = "0012"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# Evaluation records and promotion decisions are kept for good (US 4.3).
APPEND_ONLY = ("model_evaluations", "model_promotions")


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "scoring_models",
        sa.Column("version", sa.String(length=80), nullable=False),
        sa.Column("kind", sa.String(length=12), nullable=False),
        sa.Column("status", sa.String(length=12), nullable=False),
        sa.Column("record", sa.JSON(), nullable=False),
        sa.Column("weights", sa.LargeBinary(), nullable=True),
        sa.Column("weights_sha256", sa.String(length=64), nullable=True),
        sa.Column("registered_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("registered_by", sa.Uuid(), nullable=True),
        sa.CheckConstraint("kind IN ('rule', 'classifier')", name="ck_scoring_models_kind"),
        sa.CheckConstraint(
            "status IN ('candidate', 'production', 'retired')", name="ck_scoring_models_status"
        ),
        # A classifier cannot exist here without the weights to run it.
        sa.CheckConstraint(
            "kind = 'rule' OR (weights IS NOT NULL AND weights_sha256 IS NOT NULL)",
            name="ck_scoring_models_weights",
        ),
        sa.ForeignKeyConstraint(["registered_by"], ["accounts.id"]),
        sa.PrimaryKeyConstraint("version"),
    )
    # Exactly one model scores sessions at any moment.
    op.create_index(
        "uq_scoring_models_production",
        "scoring_models",
        ["status"],
        unique=True,
        postgresql_where=sa.text("status = 'production'"),
    )
    op.create_table(
        "model_evaluations",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("model_version", sa.String(length=80), nullable=False),
        sa.Column("eval_set", sa.String(length=160), nullable=False),
        sa.Column("agreement", sa.Float(), nullable=False),
        sa.Column("balanced_accuracy", sa.Float(), nullable=True),
        sa.Column("repetitions", sa.Integer(), nullable=False),
        sa.Column("metrics", sa.JSON(), nullable=False),
        sa.Column("source", sa.String(length=20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("recorded_by", sa.Uuid(), nullable=True),
        sa.CheckConstraint("agreement BETWEEN 0 AND 1", name="ck_model_evaluations_agreement"),
        sa.ForeignKeyConstraint(["model_version"], ["scoring_models.version"]),
        sa.ForeignKeyConstraint(["recorded_by"], ["accounts.id"]),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index("ix_model_evaluations_model", "model_evaluations", ["model_version", "created_at"])
    op.create_table(
        "model_promotions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("action", sa.String(length=10), nullable=False),
        sa.Column("model_version", sa.String(length=80), nullable=False),
        sa.Column("previous_version", sa.String(length=80), nullable=True),
        sa.Column("evaluation_id", sa.Uuid(), nullable=True),
        sa.Column("incumbent_evaluation_id", sa.Uuid(), nullable=True),
        sa.Column("reason", sa.String(length=300), nullable=False),
        sa.Column("decided_by", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('promote', 'rollback')", name="ck_model_promotions_action"),
        sa.ForeignKeyConstraint(["model_version"], ["scoring_models.version"]),
        sa.ForeignKeyConstraint(["previous_version"], ["scoring_models.version"]),
        sa.ForeignKeyConstraint(["evaluation_id"], ["model_evaluations.id"]),
        sa.ForeignKeyConstraint(["incumbent_evaluation_id"], ["model_evaluations.id"]),
        sa.ForeignKeyConstraint(["decided_by"], ["accounts.id"]),
        sa.PrimaryKeyConstraint("id"),
    )

    # Nobody, whatever their role, may change or delete an evaluation record
    # or a promotion decision once it is written.
    op.execute(
        """
        CREATE FUNCTION refuse_change() RETURNS trigger LANGUAGE plpgsql AS
        $$
        BEGIN
            RAISE EXCEPTION '% is append-only: rows cannot be changed or deleted', TG_TABLE_NAME
                USING ERRCODE = 'restrict_violation';
        END
        $$
        """
    )
    for table in APPEND_ONLY:
        op.execute(
            f"CREATE TRIGGER {table}_append_only BEFORE UPDATE OR DELETE ON {table} "
            f"FOR EACH ROW EXECUTE FUNCTION refuse_change()"
        )

    # What scores sessions today is the first entry: the transparent rule.
    op.execute(
        """
        INSERT INTO scoring_models (version, kind, status, record, registered_at)
        VALUES (
            'rules-1', 'rule', 'production',
            '{"description": "Each repetition is worth 100 (good), 85 (INFO), 55 (AMBER) or 0 (RED); the score is their average. Not trained on data."}',
            now()
        )
        """
    )

    # Which model judged a repetition, and how likely it thought it correct.
    op.add_column("session_repetitions", sa.Column("correct_probability", sa.Float(), nullable=True))
    op.add_column("session_repetitions", sa.Column("model_version", sa.String(length=80), nullable=True))
    op.alter_column(
        "exercise_sessions",
        "scoring_version",
        existing_type=sa.String(length=20),
        type_=sa.String(length=80),
        existing_nullable=True,
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.execute("UPDATE exercise_sessions SET scoring_version = left(scoring_version, 20)")
    op.alter_column(
        "exercise_sessions",
        "scoring_version",
        existing_type=sa.String(length=80),
        type_=sa.String(length=20),
        existing_nullable=True,
    )
    op.drop_column("session_repetitions", "model_version")
    op.drop_column("session_repetitions", "correct_probability")
    for table in APPEND_ONLY:
        op.execute(f"DROP TRIGGER {table}_append_only ON {table}")
    op.execute("DROP FUNCTION refuse_change()")
    op.drop_table("model_promotions")
    op.drop_index("ix_model_evaluations_model", table_name="model_evaluations")
    op.drop_table("model_evaluations")
    op.drop_index("uq_scoring_models_production", table_name="scoring_models")
    op.drop_table("scoring_models")
