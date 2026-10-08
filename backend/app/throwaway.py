"""Runs a command against a throwaway copy of the API:
`python -m app.throwaway <command> [arguments...]`.

Starts an empty Postgres in a temporary folder, applies the migrations, creates
the demo accounts from the SEED_* values and serves the API on a free local
port. The command finds the address in API_BASE_URL. Everything is removed when
the command finishes, so end-to-end checks never touch the development
database."""

import os
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

_START_TIMEOUT_SECONDS = 60


def _free_port() -> int:
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def run(command: list[str]) -> int:
    from app import devdb

    data_dir = Path(tempfile.mkdtemp(prefix="physioai-throwaway-"))
    server = None
    thread = None
    try:
        # Settings are read once, when `app.config` is first imported, so the
        # environment is fixed before anything else from `app` is loaded.
        os.environ["DATABASE_URL"] = devdb.start_embedded_postgres(data_dir, "physioai_throwaway")
        os.environ["JWT_SECRET"] = secrets.token_urlsafe(48)
        os.environ["ENVIRONMENT"] = "test"

        import uvicorn

        from app import seed
        from app.migrate import upgrade_to_head

        upgrade_to_head()
        seed.main()

        port = _free_port()
        server = uvicorn.Server(
            uvicorn.Config("app.main:app", host="127.0.0.1", port=port, log_level="warning")
        )
        thread = threading.Thread(target=server.run, daemon=True)
        thread.start()
        deadline = time.monotonic() + _START_TIMEOUT_SECONDS
        while not server.started:
            if not thread.is_alive() or time.monotonic() > deadline:
                raise SystemExit("The throwaway API did not start.")
            time.sleep(0.1)

        address = f"http://127.0.0.1:{port}/api/v1"
        print(f"Throwaway API ready at {address}", flush=True)
        program = shutil.which(command[0]) or command[0]
        return subprocess.call([program, *command[1:]], env={**os.environ, "API_BASE_URL": address})
    finally:
        if server is not None and thread is not None:
            server.should_exit = True
            thread.join(timeout=15)
        if "app.db" in sys.modules:
            sys.modules["app.db"].get_engine().dispose()
        for postgres in devdb._servers.values():
            postgres.cleanup()
        shutil.rmtree(data_dir, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit("usage: python -m app.throwaway <command> [arguments...]")
    raise SystemExit(run(sys.argv[1:]))
