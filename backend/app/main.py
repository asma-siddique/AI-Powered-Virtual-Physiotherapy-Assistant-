from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse
from sqlalchemy import text

from app.config import get_settings
from app.db import get_engine
from app.routers import admin, auth, physio


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    # Connect at start-up so a database or configuration problem stops the server
    # with a clear error, instead of surfacing on somebody's first request.
    get_settings().resolved_jwt_secret()
    with get_engine().connect() as connection:
        connection.execute(text("SELECT 1"))
    yield


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
    api.include_router(physio.router)
    api.include_router(admin.router)
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
