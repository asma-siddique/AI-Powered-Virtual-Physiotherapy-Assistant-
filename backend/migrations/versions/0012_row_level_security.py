"""row-level security on patient data

Revision ID: 0012
Revises: 0011
Create Date: 2026-10-11

Every table that holds a patient's data gets a policy that PostgreSQL applies
to each statement, whatever the application asks for. The API runs its
statements as the role ``physioai_app`` and says who is asking in the
settings ``app.user_id`` and ``app.role`` (see app/rls.py).

Tables left without a policy, and why:
- accounts, auth_sessions, login_attempts, invite_codes: needed to work out
  who is asking in the first place, before any identity is known.
- exercise_templates: the exercise library, the same for everyone.
- audit_log: written by every role, read only through the admin's endpoint.
"""

from typing import Sequence, Union

from alembic import op


# revision identifiers, used by Alembic.
revision: str = "0012"
down_revision: Union[str, Sequence[str], None] = "0011"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

ROLE = "physioai_app"

# Table -> the condition a row must meet to be seen or written.
_SEES_PATIENT = "app_can_see_patient(patient_id)"
_OWN_PLAN = "EXISTS (SELECT 1 FROM exercise_plans p WHERE p.id = plan_id)"
_OWN_SESSION = "EXISTS (SELECT 1 FROM exercise_sessions s WHERE s.id = session_id)"
_SELF_OR_SYSTEM = "app_role() = 'system' OR {column} = app_user_id()"

POLICIES = {
    "exercise_plans": _SEES_PATIENT,
    "exercise_sessions": _SEES_PATIENT,
    # Rows that belong to a plan or a session follow it: they are visible
    # exactly when their plan or session is.
    "plan_exercises": _OWN_PLAN,
    "prescription_edits": _OWN_PLAN,
    "session_repetitions": _OWN_SESSION,
    "reminder_settings": _SELF_OR_SYSTEM.format(column="patient_id"),
    "session_reminders": _SELF_OR_SYSTEM.format(column="patient_id"),
}


def upgrade() -> None:
    """Upgrade schema."""
    op.execute(
        f"""
        DO $$
        BEGIN
            IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '{ROLE}') THEN
                CREATE ROLE {ROLE} NOLOGIN;
            END IF;
        END
        $$;
        """
    )
    # Whoever the API connects as must be allowed to become that role.
    op.execute(f"GRANT {ROLE} TO CURRENT_USER")
    op.execute(f"GRANT USAGE ON SCHEMA public TO {ROLE}")
    op.execute(f"GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO {ROLE}")
    op.execute(f"GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO {ROLE}")
    op.execute(
        f"ALTER DEFAULT PRIVILEGES IN SCHEMA public "
        f"GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO {ROLE}"
    )
    op.execute(f"ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO {ROLE}")

    # Who is asking, as the API declared it for this transaction.
    op.execute(
        """
        CREATE FUNCTION app_user_id() RETURNS uuid LANGUAGE sql STABLE AS
        $$ SELECT NULLIF(current_setting('app.user_id', true), '')::uuid $$
        """
    )
    op.execute(
        """
        CREATE FUNCTION app_role() RETURNS text LANGUAGE sql STABLE AS
        $$ SELECT COALESCE(NULLIF(current_setting('app.role', true), ''), 'anonymous') $$
        """
    )
    # A patient's data may be seen by that patient and by the physiotherapist
    # they are assigned to now. It runs with its owner's rights so that it can
    # read the assignments whoever is asking.
    op.execute(
        """
        CREATE FUNCTION app_can_see_patient(patient uuid) RETURNS boolean
        LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS
        $$
        SELECT CASE app_role()
            WHEN 'system' THEN true
            WHEN 'patient' THEN patient = app_user_id()
            WHEN 'physiotherapist' THEN EXISTS (
                SELECT 1 FROM patient_assignments a
                WHERE a.patient_id = patient
                  AND a.physiotherapist_id = app_user_id()
                  AND a.ended_at IS NULL
            )
            ELSE false
        END
        $$
        """
    )

    for table, condition in POLICIES.items():
        op.execute(f"ALTER TABLE {table} ENABLE ROW LEVEL SECURITY")
        op.execute(f"CREATE POLICY {table}_isolation ON {table} USING ({condition}) WITH CHECK ({condition})")

    # A consent record is written by the patient it belongs to. An admin can
    # read them all, because retrieving them for audit is part of US 1.4, but
    # cannot write or change one.
    own = "app_role() = 'system' OR account_id = app_user_id()"
    op.execute("ALTER TABLE consents ENABLE ROW LEVEL SECURITY")
    op.execute(f"CREATE POLICY consents_read ON consents FOR SELECT USING ({own} OR app_role() = 'admin')")
    op.execute(f"CREATE POLICY consents_insert ON consents FOR INSERT WITH CHECK ({own})")
    op.execute(f"CREATE POLICY consents_update ON consents FOR UPDATE USING ({own}) WITH CHECK ({own})")
    op.execute(f"CREATE POLICY consents_delete ON consents FOR DELETE USING ({own})")

    # Who is assigned to whom: each side sees their own; only an admin, or
    # the system when a patient registers, may change it.
    op.execute("ALTER TABLE patient_assignments ENABLE ROW LEVEL SECURITY")
    op.execute(
        """
        CREATE POLICY patient_assignments_read ON patient_assignments FOR SELECT USING (
            app_role() IN ('system', 'admin')
            OR patient_id = app_user_id()
            OR physiotherapist_id = app_user_id()
        )
        """
    )
    for command, clause in (
        ("INSERT", "WITH CHECK (app_role() IN ('system', 'admin'))"),
        ("UPDATE", "USING (app_role() IN ('system', 'admin')) WITH CHECK (app_role() IN ('system', 'admin'))"),
        ("DELETE", "USING (app_role() IN ('system', 'admin'))"),
    ):
        op.execute(
            f"CREATE POLICY patient_assignments_{command.lower()} ON patient_assignments "
            f"FOR {command} {clause}"
        )

    # A notification can be left for anyone, but only its recipient can read
    # it or mark it read.
    mine = "app_role() = 'system' OR recipient_id = app_user_id()"
    op.execute("ALTER TABLE notifications ENABLE ROW LEVEL SECURITY")
    op.execute("CREATE POLICY notifications_insert ON notifications FOR INSERT WITH CHECK (true)")
    op.execute(f"CREATE POLICY notifications_read ON notifications FOR SELECT USING ({mine})")
    op.execute(
        f"CREATE POLICY notifications_update ON notifications FOR UPDATE USING ({mine}) WITH CHECK ({mine})"
    )
    op.execute(f"CREATE POLICY notifications_delete ON notifications FOR DELETE USING ({mine})")


def downgrade() -> None:
    """Downgrade schema."""
    for name in ("insert", "read", "update", "delete"):
        op.execute(f"DROP POLICY notifications_{name} ON notifications")
    op.execute("ALTER TABLE notifications DISABLE ROW LEVEL SECURITY")
    for name in ("read", "insert", "update", "delete"):
        op.execute(f"DROP POLICY consents_{name} ON consents")
    op.execute("ALTER TABLE consents DISABLE ROW LEVEL SECURITY")
    for name in ("read", "insert", "update", "delete"):
        op.execute(f"DROP POLICY patient_assignments_{name} ON patient_assignments")
    op.execute("ALTER TABLE patient_assignments DISABLE ROW LEVEL SECURITY")
    for table in POLICIES:
        op.execute(f"DROP POLICY {table}_isolation ON {table}")
        op.execute(f"ALTER TABLE {table} DISABLE ROW LEVEL SECURITY")
    op.execute("DROP FUNCTION app_can_see_patient(uuid)")
    op.execute("DROP FUNCTION app_role()")
    op.execute("DROP FUNCTION app_user_id()")
    # The role is left in place: it belongs to the whole database server and
    # may be in use by another database on it.
