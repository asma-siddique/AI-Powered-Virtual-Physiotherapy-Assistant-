from collections.abc import Iterator

from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

from app.config import LOCAL_STATE_DIR, get_settings


class Base(DeclarativeBase):
    pass


_engine: Engine | None = None
_session_factory: sessionmaker[Session] | None = None


def database_url() -> str:
    settings = get_settings()
    url = settings.database_url
    if not url:
        if settings.is_production:
            raise RuntimeError("DATABASE_URL must be set in production")
        from app.devdb import start_embedded_postgres

        url = start_embedded_postgres(LOCAL_STATE_DIR / "pgdata", "physioai")
    # Supabase hands out postgres:// or postgresql:// URLs; SQLAlchemy needs the driver named.
    for prefix in ("postgres://", "postgresql://"):
        if url.startswith(prefix):
            return "postgresql+psycopg://" + url[len(prefix) :]
    return url


def get_engine() -> Engine:
    global _engine, _session_factory
    if _engine is None:
        _engine = create_engine(database_url(), pool_pre_ping=True)
        _session_factory = sessionmaker(bind=_engine, expire_on_commit=False)
    return _engine


def get_db() -> Iterator[Session]:
    get_engine()
    assert _session_factory is not None
    with _session_factory() as session:
        yield session
