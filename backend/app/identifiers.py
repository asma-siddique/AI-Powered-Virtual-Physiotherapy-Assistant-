import re
from typing import Literal

from email_validator import EmailNotValidError, validate_email

from app.config import get_settings

IdentifierKind = Literal["email", "mobile"]

_MOBILE = re.compile(r"^\+?\d{10,15}$")


def normalize_identifier(raw: str) -> tuple[IdentifierKind, str] | None:
    """Returns ("email", lowercased) or ("mobile", digits with optional +), or
    None when the text is neither."""
    value = raw.strip()
    if "@" in value:
        try:
            # Outside production the reserved ".test" domain is accepted, which is
            # what the demo and test accounts use.
            validated = validate_email(
                value, check_deliverability=False, test_environment=not get_settings().is_production
            )
            return "email", validated.normalized.lower()
        except EmailNotValidError:
            return None
    compact = re.sub(r"[\s\-().]", "", value)
    if _MOBILE.match(compact):
        return "mobile", compact
    return None
