from logging.config import fileConfig

from alembic import context

from app import models  # noqa: F401  (registers the tables on Base.metadata)
from app.db import Base, get_engine

config = context.config

if config.config_file_name is not None:
    # Migrations also run inside the API at start-up in development; do not
    # switch off the loggers it already configured.
    fileConfig(config.config_file_name, disable_existing_loggers=False)

target_metadata = Base.metadata


def run_migrations_online() -> None:
    # The connection comes from the app's own settings (DATABASE_URL, or the
    # embedded development database), never from alembic.ini.
    with get_engine().connect() as connection:
        context.configure(connection=connection, target_metadata=target_metadata, compare_type=True)
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    raise SystemExit("Offline migrations are not supported; run against a database.")
run_migrations_online()
