from pathlib import Path

from alembic import command
from alembic.config import Config

_BACKEND_DIR = Path(__file__).resolve().parent.parent


def upgrade_to_head() -> None:
    """Applies any migrations the database has not seen yet (`alembic upgrade head`)."""
    config = Config(str(_BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(_BACKEND_DIR / "migrations"))
    command.upgrade(config, "head")
