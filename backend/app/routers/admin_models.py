from fastapi import APIRouter, Request, status

from app import model_registry
from app.deps import AdminUser, DbSession, client_ip
from app.model_schemas import (
    EvaluationIn,
    ModelRegistration,
    PromotionIn,
    RegistryOut,
    RollbackIn,
)

router = APIRouter(prefix="/admin/models", tags=["admin: scoring models"])


@router.get("", response_model=RegistryOut)
def list_models(_: AdminUser, db: DbSession) -> RegistryOut:
    """Every scoring model with its evaluations, which one is in production,
    and every promotion and rollback so far."""
    return model_registry.overview(db)


@router.post("", response_model=RegistryOut, status_code=status.HTTP_201_CREATED)
def register_model(body: ModelRegistration, admin: AdminUser, request: Request, db: DbSession) -> RegistryOut:
    """Registers a trained model as a candidate. It is refused without a
    held-out evaluation, or when any subject is in more than one split.
    Registering never changes which model is in production."""
    model_registry.register(db, admin, body, client_ip(request))
    return model_registry.overview(db)


@router.post("/rollback", response_model=RegistryOut)
def roll_back(body: RollbackIn, admin: AdminUser, request: Request, db: DbSession) -> RegistryOut:
    """Puts an earlier production model back at once. Sessions already under
    way keep the model they started with."""
    model_registry.rollback(db, admin, body.reason, body.to_version, client_ip(request))
    return model_registry.overview(db)


@router.post("/{version}/evaluations", response_model=RegistryOut, status_code=status.HTTP_201_CREATED)
def add_evaluation(
    version: str, body: EvaluationIn, admin: AdminUser, request: Request, db: DbSession
) -> RegistryOut:
    """Records one more evaluation of a model against a held-out set. The
    record is kept for good."""
    model_registry.add_evaluation(db, admin, version, body, client_ip(request))
    return model_registry.overview(db)


@router.post("/{version}/promote", response_model=RegistryOut)
def promote(
    version: str, body: PromotionIn, admin: AdminUser, request: Request, db: DbSession
) -> RegistryOut:
    """Makes a candidate the production model. Refused unless it does at
    least as well as the current model on the same held-out set."""
    model_registry.promote(db, admin, version, body.reason, client_ip(request))
    return model_registry.overview(db)
