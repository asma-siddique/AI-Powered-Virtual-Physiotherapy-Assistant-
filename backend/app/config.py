import secrets
from functools import lru_cache
from pathlib import Path

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

LOCAL_STATE_DIR = Path.home() / ".physioai"
# backend/.env, wherever the process was started from.
ENV_FILE = Path(__file__).resolve().parent.parent / ".env"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=ENV_FILE, env_file_encoding="utf-8", extra="ignore")

    environment: str = "development"  # development | test | production

    # Supabase/Postgres connection string. Left empty in development, the app
    # starts an embedded local Postgres instead (see app/devdb.py).
    database_url: str | None = None

    jwt_secret: str | None = None

    @field_validator("database_url", "jwt_secret", mode="before")
    @classmethod
    def _blank_means_unset(cls, value: object) -> object:
        # .env.example ships these as "NAME=" with nothing after the equals sign,
        # which arrives here as an empty string rather than as missing.
        return None if isinstance(value, str) and not value.strip() else value

    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 15
    refresh_token_days: int = 7
    idle_timeout_minutes: int = 30

    lockout_threshold: int = 5
    lockout_window_minutes: int = 15
    lockout_duration_minutes: int = 15

    invite_code_ttl_days: int = 7

    cors_origin_regex: str = r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$"

    argon2_time_cost: int = 3
    argon2_memory_kib: int = 65536

    # Local demo accounts created by `python -m app.seed` (never in production).
    seed_admin_name: str = "Alex Morgan"
    seed_admin_email: str | None = None
    seed_admin_password: str | None = None
    seed_physio_name: str = "Dr. Sarah Malik"
    seed_physio_email: str | None = None
    seed_physio_password: str | None = None
    seed_patient_name: str = "Jane Cooper"
    seed_patient_email: str | None = None
    seed_patient_password: str | None = None

    @property
    def is_production(self) -> bool:
        return self.environment == "production"

    def resolved_jwt_secret(self) -> str:
        if self.jwt_secret:
            if self.is_production and len(self.jwt_secret) < 32:
                raise RuntimeError("JWT_SECRET must be at least 32 characters in production")
            return self.jwt_secret
        if self.is_production:
            raise RuntimeError("JWT_SECRET must be set in production")
        # Development convenience: one random secret per machine, kept outside the
        # repository so sessions survive server reloads.
        path = LOCAL_STATE_DIR / "dev_jwt_secret"
        if not path.exists():
            LOCAL_STATE_DIR.mkdir(parents=True, exist_ok=True)
            path.write_text(secrets.token_urlsafe(48), encoding="utf-8")
        return path.read_text(encoding="utf-8").strip()


@lru_cache
def get_settings() -> Settings:
    return Settings()
