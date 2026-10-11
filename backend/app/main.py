import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from sqlalchemy import text

from app import reminders
from app.config import get_settings
from app.db import get_engine
from app.migrate import upgrade_to_head
from app.routers import (
    admin,
    admin_exercises,
    admin_users,
    auth,
    notifications,
    patient,
    patient_sessions,
    physio,
    physio_plans,
    physio_sessions,
)

log = logging.getLogger("physioai")


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    # Connect at start-up so a database or configuration problem stops the server
    # with a clear error, instead of surfacing on somebody's first request.
    settings = get_settings()
    settings.resolved_jwt_secret()
    if settings.database_url is None and not settings.is_production:
        # The embedded development database belongs to this machine only, so
        # keep it up to date automatically. Shared databases (DATABASE_URL) are
        # migrated deliberately with `alembic upgrade head`.
        upgrade_to_head()
    with get_engine().connect() as connection:
        connection.execute(text("SELECT 1"))
    interval = settings.reminder_interval_seconds
    scheduler = asyncio.create_task(_remind_every(interval)) if interval else None
    yield
    if scheduler is not None:
        scheduler.cancel()


async def _remind_every(seconds: int) -> None:
    """Sends session reminders as they fall due (US 6.1). A pass that fails is
    logged and the next one still runs."""
    while True:
        await asyncio.sleep(seconds)
        try:
            await asyncio.to_thread(reminders.tick)
        except Exception:
            log.exception("The reminder pass failed")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(title="PhysioAI API", version="0.1.0", lifespan=lifespan)
    app.add_middleware(
        CORSMiddleware,
        allow_origin_regex=settings.cors_origin_regex,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    api = APIRouter(prefix="/api/v1")
    api.include_router(auth.router)
    api.include_router(patient.router)
    api.include_router(patient_sessions.router)
    api.include_router(physio.router)
    api.include_router(admin.router)
    api.include_router(admin_users.router)
    api.include_router(admin_exercises.router)
    api.include_router(physio_plans.router)
    api.include_router(physio_sessions.router)
    api.include_router(notifications.router)
    app.include_router(api)

    @app.get("/health", tags=["meta"])
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/", include_in_schema=False)
    def root() -> RedirectResponse:
        # The address uvicorn prints is the first thing people open in a browser.
        return RedirectResponse("/docs")

    return app


app = create_app()
