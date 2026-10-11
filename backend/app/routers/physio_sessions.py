import uuid
from datetime import UTC, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, Request, Response, status

from app import audit, clock, errors, plan_service, report, review_service, session_service
from app.deps import DbSession, PhysioUser, client_ip
from app.session_schemas import ClinicianNoteIn, FlaggedSession, SessionBrief, SessionDetail

router = APIRouter(prefix="/physio", tags=["physiotherapist: sessions"])


@router.get("/flagged-sessions", response_model=list[FlaggedSession])
def list_flagged_sessions(
    physio: PhysioUser,
    db: DbSession,
    state: Literal["unreviewed", "reviewed", "all"] = "unreviewed",
) -> list[FlaggedSession]:
    """Sessions of the physiotherapist's own patients that had a RED
    repetition or scored below the threshold, most recently flagged first."""
    return review_service.flagged(db, physio, state)


@router.get("/sessions/{session_id}", response_model=SessionDetail)
def get_session(session_id: uuid.UUID, physio: PhysioUser, db: DbSession) -> SessionDetail:
    return session_service.detail(db, review_service.session_of_patient(db, physio, session_id))


@router.post("/sessions/{session_id}/review", response_model=SessionDetail)
def review_session(
    session_id: uuid.UUID, physio: PhysioUser, request: Request, db: DbSession
) -> SessionDetail:
    """Marks a flagged session as reviewed, which is the only thing that takes
    it out of the unreviewed queue."""
    session = review_service.mark_reviewed(db, physio, session_id, client_ip(request))
    return session_service.detail(db, session)


@router.get("/patients/{patient_id}/sessions", response_model=list[SessionBrief])
def list_patient_sessions(
    patient_id: uuid.UUID,
    physio: PhysioUser,
    db: DbSession,
    exercise_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[SessionBrief]:
    """The ended sessions of one of the physiotherapist's own patients."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    return session_service.history(db, patient.id, exercise_id=exercise_id, since=since, until=until)


@router.put("/sessions/{session_id}/note", response_model=SessionDetail)
def save_session_note(
    session_id: uuid.UUID, body: ClinicianNoteIn, physio: PhysioUser, request: Request, db: DbSession
) -> SessionDetail:
    """The physiotherapist's own note on a session of one of their patients.
    An empty note removes it."""
    session = review_service.set_note(db, physio, session_id, body.note, client_ip(request))
    return session_service.detail(db, session)


@router.get(
    "/patients/{patient_id}/report",
    response_class=Response,
    responses={200: {"content": {"application/pdf": {}}, "description": "The report as a PDF."}},
)
def export_patient_report(
    patient_id: uuid.UUID,
    physio: PhysioUser,
    request: Request,
    db: DbSession,
    since: datetime | None = None,
    until: datetime | None = None,
) -> Response:
    """A PDF of one patient's sessions, scores, trend, pain ratings and notes
    for sessions started from `since` and before `until` (the last 90 days
    when not given). Only for a patient assigned to the physiotherapist
    asking; anyone else's is not found."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    now = clock.utcnow()

    def aware(moment: datetime) -> datetime:
        return moment.replace(tzinfo=UTC) if moment.tzinfo is None else moment.astimezone(UTC)

    end = aware(until) if until else now
    start = aware(since) if since else end - timedelta(days=90)
    if start >= end:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "range_invalid",
            "The report's start must be before its end.",
        )
    if end - start > timedelta(days=report.MAX_DAYS):
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "range_too_long",
            "A report covers at most one year. Choose a shorter period.",
        )

    data = report.gather(db, physio, patient, start, end, now)
    document = report.render(data)
    audit.record(
        db,
        "report.exported",
        actor_id=physio.id,
        target_type="account",
        target_id=patient.id,
        detail={"since": start.isoformat(), "until": end.isoformat(), "sessions": len(data.sessions)},
        ip=client_ip(request),
    )
    db.commit()
    return Response(
        content=document,
        media_type="application/pdf",
        headers={
            "Content-Disposition": f'attachment; filename="{report.filename(patient.id, start, end)}"',
            # A report holds health data: no shared cache may keep a copy.
            "Cache-Control": "no-store",
        },
    )
