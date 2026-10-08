"""Embedded Postgres for local development, so nobody needs Docker or a cloud
project just to run the API. Production and CI use DATABASE_URL instead."""

import contextlib
import logging
import os
import subprocess
import time
from collections.abc import Iterator
from pathlib import Path

import psycopg

log = logging.getLogger("physioai.devdb")

# Up to about two minutes in total, enough for crash recovery on a slow disk.
_START_ATTEMPTS = 24
_RETRY_DELAY_SECONDS = 5

_servers: dict[str, object] = {}


@contextlib.contextmanager
def _working_directory(path: Path) -> Iterator[None]:
    # Postgres' pg_ctl refuses to start when the process's current directory is
    # one it cannot use, which depends on how the API happened to be launched.
    try:
        previous: str | None = os.getcwd()
    except OSError:
        previous = None
    os.chdir(path)
    try:
        yield
    finally:
        if previous is not None:
            with contextlib.suppress(OSError):
                os.chdir(previous)


def _start_server(data_dir: Path) -> object:
    import pgserver
    from pgserver.postgres_server import PostgresServer

    for attempt in range(1, _START_ATTEMPTS + 1):
        try:
            return pgserver.get_server(data_dir, cleanup_mode="stop")
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError, AssertionError):
            # After an unclean stop (process killed, power loss) Postgres replays
            # its log before accepting connections, which can outlast pgserver's
            # fixed 10-second wait. Postgres keeps starting in the background, so
            # a later attempt finds it running. Until it is ready, pgserver trips
            # its own "status == 'ready'" assertion, hence AssertionError here.
            PostgresServer._instances.pop(data_dir, None)
            if attempt == _START_ATTEMPTS:
                raise
            log.warning(
                "Local database is still starting (attempt %d of %d); retrying in %d seconds",
                attempt,
                _START_ATTEMPTS,
                _RETRY_DELAY_SECONDS,
            )
            time.sleep(_RETRY_DELAY_SECONDS)
    raise AssertionError("unreachable")


def start_embedded_postgres(data_dir: Path, database: str) -> str:
    data_dir = data_dir.expanduser().resolve()
    data_dir.mkdir(parents=True, exist_ok=True)
    key = str(data_dir)
    if key not in _servers:
        with _working_directory(data_dir.parent):
            _servers[key] = _start_server(data_dir)
    base_uri: str = _servers[key].get_uri()

    with psycopg.connect(base_uri, autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (database,)).fetchone()
        if not exists:
            conn.execute(f'CREATE DATABASE "{database}"')

    return base_uri.rsplit("/", 1)[0] + f"/{database}"
