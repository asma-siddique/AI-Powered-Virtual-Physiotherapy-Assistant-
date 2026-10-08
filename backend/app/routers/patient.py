from fastapi import APIRouter, Request, Response, status

from app import consent_service, disclaimer, errors
from app.deps import DbSession, PatientUser, client_ip
from app.schemas import ConsentRequest, ConsentStatusOut

router = APIRouter(prefix="/patient", tags=["patient"])


@router.get("/consent", response_model=ConsentStatusOut)
def get_consent(patient: PatientUser, db: DbSession) -> ConsentStatusOut:
    """The advisory text and whether this patient has acknowledged it. Also what
    the Help page shows, so the wording is the same in both places."""
    return consent_service.status(db, patient.id)


@router.post("/consent", response_model=ConsentStatusOut, status_code=status.HTTP_201_CREATED)
def acknowledge_consent(
    body: ConsentRequest, patient: PatientUser, request: Request, response: Response, db: DbSession
) -> ConsentStatusOut:
    if body.version != disclaimer.CURRENT_VERSION:
        raise errors.disclaimer_outdated()
    _, created = consent_service.acknowledge(
        db, patient, ip=client_ip(request), user_agent=request.headers.get("user-agent")
    )
    if not created:
        response.status_code = status.HTTP_200_OK
    return consent_service.status(db, patient.id)
