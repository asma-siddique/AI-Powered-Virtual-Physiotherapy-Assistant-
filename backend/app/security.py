import hashlib
import secrets
import uuid
from dataclasses import dataclass
from datetime import timedelta
from functools import lru_cache

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import Argon2Error, InvalidHashError

from app import clock
from app.config import get_settings


@lru_cache
def _hasher() -> PasswordHasher:
    settings = get_settings()
    return PasswordHasher(time_cost=settings.argon2_time_cost, memory_cost=settings.argon2_memory_kib)


@lru_cache
def _dummy_hash() -> str:
    return _hasher().hash(secrets.token_urlsafe(16))


def hash_password(password: str) -> str:
    return _hasher().hash(password)


def verify_password(password_hash: str, password: str) -> bool:
    try:
        return _hasher().verify(password_hash, password)
    except (Argon2Error, InvalidHashError):
        return False


def burn_password_check(password: str) -> None:
    """Spend the same work as a real check when the account does not exist, so
    response time does not reveal whether an identifier is registered."""
    verify_password(_dummy_hash(), password)


def sha256_hex(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def new_refresh_token() -> tuple[str, str]:
    token = secrets.token_urlsafe(48)
    return token, sha256_hex(token)


@dataclass(frozen=True)
class AccessClaims:
    account_id: uuid.UUID
    session_id: uuid.UUID


class TokenError(Exception):
    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


def create_access_token(account_id: uuid.UUID, session_id: uuid.UUID) -> tuple[str, int]:
    settings = get_settings()
    now = clock.utcnow()
    lifetime = timedelta(minutes=settings.access_token_minutes)
    payload = {
        "sub": str(account_id),
        "sid": str(session_id),
        "typ": "access",
        "iat": int(now.timestamp()),
        "exp": int((now + lifetime).timestamp()),
    }
    token = jwt.encode(payload, settings.resolved_jwt_secret(), algorithm=settings.jwt_algorithm)
    return token, int(lifetime.total_seconds())


def decode_access_token(token: str) -> AccessClaims:
    settings = get_settings()
    try:
        # Time claims are checked below against app.clock, not the wall clock
        # PyJWT uses, so the two can never disagree.
        payload = jwt.decode(
            token,
            settings.resolved_jwt_secret(),
            algorithms=[settings.jwt_algorithm],
            options={"verify_exp": False, "verify_iat": False, "require": ["sub", "sid", "exp"]},
        )
        if payload.get("typ") != "access":
            raise TokenError("token_invalid")
        claims = AccessClaims(uuid.UUID(payload["sub"]), uuid.UUID(payload["sid"]))
    except (jwt.PyJWTError, ValueError, KeyError) as exc:
        raise TokenError("token_invalid") from exc
    if int(payload["exp"]) <= int(clock.utcnow().timestamp()):
        raise TokenError("token_expired")
    return claims
