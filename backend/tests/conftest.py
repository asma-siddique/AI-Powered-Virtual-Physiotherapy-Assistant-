import os
import shutil
import tempfile
import uuid
from collections.abc import Iterator
from datetime import datetime, timedelta
from pathlib import Path

import pytest

# Settings are read once at import time, so the test environment is fixed before
# anything from `app` is imported.
os.environ["ENVIRONMENT"] = "test"
os.environ["JWT_SECRET"] = "test-secret-not-used-anywhere-else-0123456789"
os.environ["ARGON2_TIME_COST"] = "1"
os.environ["ARGON2_MEMORY_KIB"] = "64"

_embedded_dir: Path | None = None
if os.environ.get("TEST_DATABASE_URL"):
    # The suite drops and rebuilds the whole schema, so it must never be pointed
    # at a database that holds real data.
    if "test" not in os.environ["TEST_DATABASE_URL"].rsplit("/", 1)[-1]:
        raise RuntimeError("TEST_DATABASE_URL must name a database containing 'test'")
    os.environ["DATABASE_URL"] = os.environ["TEST_DATABASE_URL"]
else:
    from app.devdb import start_embedded_postgres

    _embedded_dir = Path(tempfile.mkdtemp(prefix="physioai-test-pg-"))
    os.environ["DATABASE_URL"] = start_embedded_postgres(_embedded_dir, "physioai_test")

from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import text  # noqa: E402
from sqlalchemy.orm import Session  # noqa: E402

from app import clock  # noqa: E402
from app.db import Base, get_engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import (  # noqa: E402
    Account,
    ExerciseTemplate,
    InviteCode,
    PatientAssignment,
    Role,
)
from app.security import hash_password  # noqa: E402

BACKEND_DIR = Path(__file__).resolve().parent.parent
PASSWORD = "Correct-Horse-9"
# Names of the exercises the migrations insert, read before the first test
# empties the tables.
SEEDED_EXERCISES: list[str] = []


@pytest.fixture(scope="session", autouse=True)
def _schema() -> Iterator[None]:
    """Builds the schema with the real migrations, so they are tested too."""
    engine = get_engine()
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE"))
        conn.execute(text("CREATE SCHEMA public"))
    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_DIR / "migrations"))
    command.upgrade(config, "head")
    with engine.connect() as conn:
        rows = conn.execute(text("SELECT name FROM exercise_templates ORDER BY name"))
        SEEDED_EXERCISES.extend(row[0] for row in rows)
    yield
    engine.dispose()
    if _embedded_dir is not None:
        from app import devdb

        for server in devdb._servers.values():
            server.cleanup()
        shutil.rmtree(_embedded_dir, ignore_errors=True)


@pytest.fixture(autouse=True)
def _clean_tables() -> None:
    tables = ", ".join(f'"{t.name}"' for t in Base.metadata.sorted_tables)
    with get_engine().begin() as conn:
        conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))


@pytest.fixture
def db() -> Iterator[Session]:
    with Session(get_engine(), expire_on_commit=False) as session:
        yield session


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app) as test_client:
        yield test_client


class Clock:
    def __init__(self, monkeypatch: pytest.MonkeyPatch) -> None:
        self._now = clock.utcnow()
        monkeypatch.setattr(clock, "utcnow", lambda: self._now)

    def now(self) -> datetime:
        return self._now

    def advance(self, **delta: float) -> None:
        self._now += timedelta(**delta)


@pytest.fixture
def time(monkeypatch: pytest.MonkeyPatch) -> Clock:
    return Clock(monkeypatch)


CHECK = {
    "key": "knee_valgus",
    "label": "Knee alignment",
    "measure": "Inward deviation of the knees",
    "unit": "degrees",
    "info": 5,
    "amber": 10,
    "red": 15,
    "corrective_message": "Keep your knees in line with your toes.",
}


class Factory:
    def __init__(self, db: Session) -> None:
        self.db = db

    def account(self, role: Role, email: str | None = None, *, active: bool = True, **extra) -> Account:
        account = Account(
            id=uuid.uuid4(),
            full_name=extra.pop("full_name", f"Test {role.value.title()}"),
            email=email or f"{role.value}-{uuid.uuid4().hex[:8]}@example.test",
            password_hash=hash_password(PASSWORD),
            role=role,
            is_active=active,
            created_at=clock.utcnow(),
            **extra,
        )
        self.db.add(account)
        self.db.commit()
        return account

    def invite(
        self, physio: Account, *, code: str = "PHY-TEST-CODE", expires_in_days: float = 7
    ) -> InviteCode:
        now = clock.utcnow()
        invite = InviteCode(
            code=code,
            physiotherapist_id=physio.id,
            created_at=now,
            expires_at=now + timedelta(days=expires_in_days),
        )
        self.db.add(invite)
        self.db.commit()
        return invite

    def exercise(self, name: str = "Squats", *, active: bool = True, **extra) -> ExerciseTemplate:
        now = clock.utcnow()
        template = ExerciseTemplate(
            slug=name.lower().replace(" ", "-"),
            name=name,
            domain=extra.pop("domain", "Functional rehabilitation"),
            body_area=extra.pop("body_area", "whole_body"),
            primary_targets=extra.pop("primary_targets", "Quadriceps, glutes"),
            target_joints=extra.pop("target_joints", ["hip", "knee", "ankle"]),
            movement_pattern=extra.pop("movement_pattern", "Bend the hips and knees, then stand."),
            instructions=extra.pop("instructions", "Stand tall, bend your knees, then stand back up."),
            checks=extra.pop("checks", [CHECK]),
            is_active=active,
            version=1,
            created_at=now,
            updated_at=now,
            **extra,
        )
        self.db.add(template)
        self.db.commit()
        return template

    def patient_of(self, physio: Account, email: str | None = None) -> Account:
        patient = self.account(Role.patient, email)
        self.db.add(
            PatientAssignment(patient_id=patient.id, physiotherapist_id=physio.id, assigned_at=clock.utcnow())
        )
        self.db.commit()
        return patient


@pytest.fixture
def make(db: Session) -> Factory:
    return Factory(db)


def sign_in(client: TestClient, account: Account, password: str = PASSWORD, **extra) -> dict:
    response = client.post(
        "/api/v1/auth/login", json={"identifier": account.email, "password": password, **extra}
    )
    assert response.status_code == 200, response.text
    return response.json()


def bearer(tokens: dict) -> dict[str, str]:
    return {"Authorization": f"Bearer {tokens['tokens']['access_token']}"}
