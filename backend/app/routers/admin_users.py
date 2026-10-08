import uuid
from typing import Annotated

from fastapi import APIRouter, Query, Request, status

from app import account_service
from app.admin_schemas import (
    AdminUserOut,
    Reassignment,
    RoleChange,
    TemporaryPassword,
    UserCreate,
    UserCreated,
    UserUpdate,
)
from app.deps import AdminUser, DbSession, client_ip
from app.models import Role

router = APIRouter(prefix="/admin/users", tags=["admin: users"])


@router.get("", response_model=list[AdminUserOut])
def list_users(
    _: AdminUser,
    db: DbSession,
    role: Role | None = None,
    active: bool | None = None,
    q: Annotated[str | None, Query(max_length=100, description="Name, email or mobile")] = None,
) -> list[AdminUserOut]:
    return account_service.to_out(db, account_service.search(db, role=role, active=active, text=q))


@router.post("", response_model=UserCreated, status_code=status.HTTP_201_CREATED)
def create_user(body: UserCreate, admin: AdminUser, request: Request, db: DbSession) -> UserCreated:
    """Creates an account with a temporary password, which is returned once.
    The new user has to choose their own password the first time they sign in."""
    account, password = account_service.create(db, admin, body, client_ip(request))
    db.commit()
    return UserCreated(user=account_service.one_out(db, account), temporary_password=password)


@router.patch("/{user_id}", response_model=AdminUserOut)
def update_user(
    user_id: uuid.UUID, body: UserUpdate, admin: AdminUser, request: Request, db: DbSession
) -> AdminUserOut:
    user = account_service.get_user(db, user_id, lock=True)
    account_service.update(db, admin, user, body, client_ip(request))
    db.commit()
    return account_service.one_out(db, user)


@router.post("/{user_id}/deactivate", response_model=AdminUserOut)
def deactivate_user(user_id: uuid.UUID, admin: AdminUser, request: Request, db: DbSession) -> AdminUserOut:
    """The account can no longer sign in and is signed out everywhere. Nothing
    it created is removed."""
    user = account_service.get_user(db, user_id, lock=True)
    account_service.set_active(db, admin, user, False, client_ip(request))
    db.commit()
    return account_service.one_out(db, user)


@router.post("/{user_id}/activate", response_model=AdminUserOut)
def activate_user(user_id: uuid.UUID, admin: AdminUser, request: Request, db: DbSession) -> AdminUserOut:
    user = account_service.get_user(db, user_id, lock=True)
    account_service.set_active(db, admin, user, True, client_ip(request))
    db.commit()
    return account_service.one_out(db, user)


@router.post("/{user_id}/role", response_model=AdminUserOut)
def change_user_role(
    user_id: uuid.UUID, body: RoleChange, admin: AdminUser, request: Request, db: DbSession
) -> AdminUserOut:
    user = account_service.get_user(db, user_id, lock=True)
    account_service.change_role(db, admin, user, body.role, client_ip(request))
    db.commit()
    return account_service.one_out(db, user)


@router.post("/{user_id}/reassign", response_model=AdminUserOut)
def reassign_patient(
    user_id: uuid.UUID, body: Reassignment, admin: AdminUser, request: Request, db: DbSession
) -> AdminUserOut:
    """Moves a patient to another physiotherapist. The previous physiotherapist
    loses access and the new one gains it with this request."""
    patient = account_service.get_user(db, user_id, lock=True)
    account_service.reassign(db, admin, patient, body.physiotherapist_id, client_ip(request))
    db.commit()
    return account_service.one_out(db, patient)


@router.post("/{user_id}/reset-password", response_model=TemporaryPassword)
def reset_user_password(
    user_id: uuid.UUID, admin: AdminUser, request: Request, db: DbSession
) -> TemporaryPassword:
    """Issues a new temporary password, returned once, and signs the account
    out everywhere."""
    user = account_service.get_user(db, user_id, lock=True)
    password = account_service.reset_password(db, admin, user, client_ip(request))
    db.commit()
    return TemporaryPassword(temporary_password=password)
