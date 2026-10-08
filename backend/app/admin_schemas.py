import uuid
from datetime import datetime

from pydantic import BaseModel, Field, field_validator, model_validator

from app.models import Role
from app.schemas import PersonRef


def _tidy_name(value: str) -> str:
    value = " ".join(value.split())
    if len(value) < 2:
        raise ValueError("Enter the person's full name.")
    return value


class AdminUserOut(BaseModel):
    id: uuid.UUID
    full_name: str
    email: str | None
    mobile: str | None
    role: Role
    is_active: bool
    created_at: datetime
    # Still on the temporary password an admin issued.
    must_change_password: bool
    # When the account last used the app on any device.
    last_seen_at: datetime | None
    # Patients only: the physiotherapist currently responsible for them.
    physiotherapist: PersonRef | None = None
    # Physiotherapists only: how many active patients they are responsible for.
    patient_count: int | None = None


class UserCreate(BaseModel):
    full_name: str = Field(min_length=2, max_length=120)
    identifier: str = Field(min_length=3, max_length=254, description="Email address or mobile number")
    role: Role
    # Required for a patient, who is never without a physiotherapist.
    physiotherapist_id: uuid.UUID | None = None

    _name = field_validator("full_name")(_tidy_name)

    @model_validator(mode="after")
    def _patient_needs_physiotherapist(self) -> "UserCreate":
        if self.role == Role.patient and self.physiotherapist_id is None:
            raise ValueError("Choose the patient's physiotherapist.")
        if self.role != Role.patient and self.physiotherapist_id is not None:
            raise ValueError("Only a patient is assigned to a physiotherapist.")
        return self


class UserCreated(BaseModel):
    user: AdminUserOut
    # Shown to the admin once and never stored in a readable form.
    temporary_password: str


class UserUpdate(BaseModel):
    """Only the fields that are sent change. An empty email or mobile removes
    it, as long as the account keeps one of the two."""

    full_name: str | None = Field(default=None, min_length=2, max_length=120)
    email: str | None = Field(default=None, max_length=254)
    mobile: str | None = Field(default=None, max_length=20)

    @field_validator("full_name")
    @classmethod
    def _name(cls, value: str | None) -> str | None:
        return None if value is None else _tidy_name(value)


class RoleChange(BaseModel):
    role: Role


class Reassignment(BaseModel):
    physiotherapist_id: uuid.UUID


class TemporaryPassword(BaseModel):
    temporary_password: str
