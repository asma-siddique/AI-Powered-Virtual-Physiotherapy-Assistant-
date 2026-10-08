import re
import uuid
from datetime import datetime
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.models import Role


class RegisterRequest(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    identifier: str = Field(min_length=3, max_length=254, description="Email address or mobile number")
    password: str = Field(min_length=8, max_length=128)
    invite_code: str = Field(min_length=4, max_length=32)

    @field_validator("full_name")
    @classmethod
    def _tidy_name(cls, value: str) -> str:
        value = " ".join(value.split())
        if len(value) < 2:
            raise ValueError("Enter your full name.")
        return value

    @field_validator("password")
    @classmethod
    def _password_policy(cls, value: str) -> str:
        if not re.search(r"[A-Za-z]", value) or not re.search(r"\d", value):
            raise ValueError("Use at least 8 characters, including a letter and a number.")
        return value


class LoginRequest(BaseModel):
    identifier: str = Field(min_length=1, max_length=254)
    password: str = Field(min_length=1, max_length=128)
    # The role the user picked on the sign-in screen. When sent, it must match
    # the account's real role or sign-in fails like any other wrong detail.
    role: Role | None = None


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=10, max_length=512)


class AccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    full_name: str
    email: str | None
    mobile: str | None
    role: Role
    is_active: bool
    created_at: datetime


class PersonRef(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    full_name: str


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class MeResponse(BaseModel):
    account: AccountOut
    # Set for patients only: the physiotherapist currently responsible for them.
    physiotherapist: PersonRef | None = None
    # Patients only: whether the current advisory has been acknowledged. The app
    # sends a patient to the advisory screen while this is false.
    advisory_acknowledged: bool | None = None


class AuthResponse(MeResponse):
    tokens: TokenPair


class SessionOut(BaseModel):
    id: uuid.UUID
    created_at: datetime
    last_seen_at: datetime
    user_agent: str | None
    ip: str | None
    current: bool


class InviteCodeOut(BaseModel):
    id: uuid.UUID
    code: str
    created_at: datetime
    expires_at: datetime
    status: str  # active | redeemed | expired
    redeemed_by: PersonRef | None = None


class PatientSummary(BaseModel):
    id: uuid.UUID
    full_name: str
    email: str | None
    mobile: str | None
    is_active: bool
    assigned_at: datetime


class AuditEntryOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    actor_id: uuid.UUID | None
    action: str
    target_type: str | None
    target_id: str | None
    detail: dict[str, Any]
    created_at: datetime


class DisclaimerPoint(BaseModel):
    heading: str
    body: str


class DisclaimerOut(BaseModel):
    version: str
    title: str
    intro: str
    points: list[DisclaimerPoint]
    caution: str
    acknowledgment: str


class ConsentStatusOut(BaseModel):
    disclaimer: DisclaimerOut
    acknowledged: bool
    acknowledged_at: datetime | None = None


class ConsentRequest(BaseModel):
    # The version the patient actually read, so an acknowledgment can never be
    # recorded against wording they did not see.
    version: str = Field(min_length=1, max_length=20)
    # Must be sent as true: consent is never assumed from a missing field.
    acknowledged: Literal[True]


class ConsentRecordOut(BaseModel):
    id: uuid.UUID
    account: PersonRef
    disclaimer_version: str
    acknowledged_at: datetime
