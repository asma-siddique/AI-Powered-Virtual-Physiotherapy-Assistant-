from datetime import UTC, datetime


def utcnow() -> datetime:
    """Single source of "now" so tests can move time forward."""
    return datetime.now(UTC)
