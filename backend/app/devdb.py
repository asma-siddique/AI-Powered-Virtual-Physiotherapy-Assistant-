"""Embedded Postgres for local development, so nobody needs Docker or a cloud
project just to run the API. Production and CI use DATABASE_URL instead."""

import contextlib
import os
from collections.abc import Iterator
from pathlib import Path

import psycopg

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


def start_embedded_postgres(data_dir: Path, database: str) -> str:
    import pgserver

    data_dir.mkdir(parents=True, exist_ok=True)
    key = str(data_dir)
    if key not in _servers:
        with _working_directory(data_dir.parent):
            _servers[key] = pgserver.get_server(data_dir, cleanup_mode="stop")
    base_uri: str = _servers[key].get_uri()

    with psycopg.connect(base_uri, autocommit=True) as conn:
        exists = conn.execute("SELECT 1 FROM pg_database WHERE datname = %s", (database,)).fetchone()
        if not exists:
            conn.execute(f'CREATE DATABASE "{database}"')

    return base_uri.rsplit("/", 1)[0] + f"/{database}"
