"""A patient's exercise session: starting it (US 3.1), storing and classifying
its repetitions (US 3.3, 3.4), the safety pause and ending it. A session only
exists once the camera pre-check has passed, and it keeps its own copy of the
prescription and thresholds it was started with."""

import uuid
from collections import Counter
from datetime import UTC, datetime, timedelta

from fastapi import status
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import (
    audit,
    clock,
    errors,
    model_registry,
    notifications,
    personal,
    pose,
    pose_features,
    reference_service,
    scoring,
    severity,
)
from app.config import get_settings
from app.exercise_schemas import ExerciseBrief
from app.models import (
    Account,
    ExercisePlan,
    ExerciseReference,
    ExerciseSession,
    ExerciseTemplate,
    PatientAssignment,
    PlanExercise,
    SessionRepetition,
)
from app.session_schemas import (
    MAX_SERIES_FRAMES,
    PainIn,
    PauseOut,
    PrecheckEvidence,
    PrecheckRequirements,
    PreviousSession,
    RepetitionDetail,
    RepetitionIn,
    RepetitionOut,
    SeriesSpec,
    SessionBrief,
    SessionDetail,
    SessionOut,
    SessionSummary,
    SessionTotals,
)

ACTIVE, PAUSED, COMPLETED, ABANDONED = "active", "paused", "completed", "abandoned"
# A paused session is still under way: it blocks a second one and can be ended.
UNDER_WAY = (ACTIVE, PAUSED)
ENDED = (COMPLETED, ABANDONED)

# Why a session is in the physiotherapist's flagged queue.
FLAG_RED, FLAG_LOW_SCORE = "red", "low_score"
# How long after a session starts its pain rating can still be changed.
PAIN_WINDOW = timedelta(hours=24)
# The most sessions one history request returns: far more than a year of
# daily exercise.
HISTORY_LIMIT = 1000


def _required(target_joints: list[str], checks: list[dict], exercise_slug: str) -> list[str]:
    return pose.required_landmarks(target_joints, [check["key"] for check in checks], exercise_slug)


def _current_item(db: Session, patient: Account, item_id: uuid.UUID) -> tuple[PlanExercise, ExerciseTemplate]:
    """An exercise of the plan in force for this patient. Anything else, such
    as another patient's exercise or one from an archived plan, is not found."""
    row = db.execute(
        select(PlanExercise, ExerciseTemplate)
        .join(ExercisePlan, ExercisePlan.id == PlanExercise.plan_id)
        .join(ExerciseTemplate, ExerciseTemplate.id == PlanExercise.exercise_template_id)
        .where(
            PlanExercise.id == item_id,
            ExercisePlan.patient_id == patient.id,
            ExercisePlan.archived_at.is_(None),
        )
    ).one_or_none()
    if row is None:
        raise errors.not_found("That exercise is not in your current plan.")
    item, template = row
    if not template.is_active:
        raise errors.conflict(
            "exercise_unavailable",
            "This exercise is not available at the moment. Your physiotherapist can update your plan.",
        )
    return item, template


def requirements(db: Session, patient: Account, item_id: uuid.UUID) -> PrecheckRequirements:
    item, template = _current_item(db, patient, item_id)
    return PrecheckRequirements(
        item_id=item.id,
        exercise=ExerciseBrief.model_validate(template),
        sets=item.sets,
        reps=item.reps,
        rest_seconds=item.rest_seconds,
        difficulty=item.difficulty.value,
        required_landmarks=_required(template.target_joints, template.checks, template.slug),
        min_visibility=pose.MIN_VISIBILITY,
        min_brightness=pose.MIN_BRIGHTNESS,
        hold_ms=pose.HOLD_MS,
        camera_view=template.camera_view,
        front_min_ratio=pose.FRONT_MIN_RATIO,
        side_max_ratio=pose.SIDE_MAX_RATIO,
    )


def _pause_of(repetition: SessionRepetition) -> PauseOut:
    worst = repetition.feedback[0]
    return PauseOut(repetition_id=repetition.id, check=worst["check"], message=worst["message"])


def _pause(db: Session, session: ExerciseSession) -> PauseOut | None:
    """The RED repetition a paused session is waiting on."""
    if session.status != PAUSED:
        return None
    repetition = db.execute(
        select(SessionRepetition)
        .where(
            SessionRepetition.session_id == session.id,
            SessionRepetition.tier == severity.RED,
            SessionRepetition.acknowledged_at.is_(None),
        )
        .order_by(SessionRepetition.created_at.desc())
        .limit(1)
    ).scalar_one()
    return _pause_of(repetition)


def totals(db: Session, session_id: uuid.UUID) -> SessionTotals:
    counts = {
        tier: count
        for tier, count in db.execute(
            select(SessionRepetition.tier, func.count())
            .where(SessionRepetition.session_id == session_id)
            .group_by(SessionRepetition.tier)
        )
    }
    return SessionTotals(
        repetitions=sum(counts.values()), **{tier: counts.get(tier, 0) for tier in severity.TIERS}
    )


def _seconds(session: ExerciseSession) -> int:
    return int(((session.ended_at or clock.utcnow()) - session.started_at).total_seconds())


def _stored_totals(db: Session, session: ExerciseSession) -> SessionTotals:
    """The totals saved when the session ended; counted afresh for a session
    still under way or one that ended before totals were saved."""
    if session.totals is not None:
        return SessionTotals(**session.totals)
    return totals(db, session.id)


def flag(db: Session, session: ExerciseSession, reason: str, patient: Account) -> None:
    """Puts the session in its physiotherapist's flagged queue (US 5.2), in
    the caller's transaction. A session already reviewed that gives a new
    reason goes back in as unreviewed, so nothing new is hidden by an earlier
    review."""
    reasons = list(session.flag_reasons or [])
    is_new = session.flagged_at is None
    resurfaced = session.reviewed_at is not None
    if reason in reasons and not resurfaced:
        return
    if reason not in reasons:
        session.flag_reasons = [*reasons, reason]
    if is_new or resurfaced:
        session.flagged_at = clock.utcnow()
    session.reviewed_at = None
    session.reviewed_by = None
    if not (is_new or resurfaced):
        return
    physio_id = db.execute(
        select(PatientAssignment.physiotherapist_id).where(
            PatientAssignment.patient_id == patient.id, PatientAssignment.ended_at.is_(None)
        )
    ).scalar_one_or_none()
    if physio_id is not None:
        template = db.get(ExerciseTemplate, session.exercise_template_id)
        why = (
            "was paused for safety"
            if reason == FLAG_RED
            else f"scored below {session.flag_threshold} out of 100"
        )
        notifications.send(
            db,
            physio_id,
            notifications.SESSION_FLAGGED,
            "Session flagged for review",
            f"{patient.full_name}'s {template.name} session {why}.",
            link="/physio/flagged",
        )


def _close(db: Session, session: ExerciseSession, status_: str, patient: Account) -> None:
    """Ends a session and stores what it came to. Every repetition it holds
    was classified when it was stored, so the score is never built from
    anything still waiting to be judged."""
    session.status = status_
    session.ended_at = clock.utcnow()
    rows = list(
        db.execute(
            select(
                SessionRepetition.tier, SessionRepetition.measures, SessionRepetition.correct_probability
            ).where(SessionRepetition.session_id == session.id)
        )
    )
    counts = Counter(tier for tier, _, _ in rows)
    session.totals = SessionTotals(
        repetitions=len(rows), **{tier: counts.get(tier, 0) for tier in severity.TIERS}
    ).model_dump()
    judged = [probability for _, _, probability in rows if probability is not None]
    if judged:
        # The session's classifier judged these repetitions as they came in.
        session.form_score, session.scored_repetitions = scoring.classifier_score(judged)
    else:
        # The rule scores it: it was the session's scorer from the start, or
        # no repetition reached the classifier (the app sent no frames). The
        # stored version always names what really produced the score.
        session.form_score, session.scored_repetitions = scoring.form_score(
            (tier, measures) for tier, measures, _ in rows
        )
        session.scoring_version = scoring.VERSION
        session.reference_id = None
    threshold = get_settings().flag_score_below
    if session.form_score is not None and session.form_score < threshold:
        session.flag_threshold = threshold
        flag(db, session, FLAG_LOW_SCORE, patient)


def summary(db: Session, session: ExerciseSession) -> SessionSummary | None:
    """What an ended session came to, with the session of the same exercise
    before it for comparison (US 4.2)."""
    if session.ended_at is None:
        return None
    before = db.execute(
        select(ExerciseSession)
        .where(
            ExerciseSession.patient_id == session.patient_id,
            ExerciseSession.exercise_template_id == session.exercise_template_id,
            ExerciseSession.status == COMPLETED,
            ExerciseSession.id != session.id,
            ExerciseSession.ended_at <= session.started_at,
        )
        .order_by(ExerciseSession.ended_at.desc())
        .limit(1)
    ).scalar_one_or_none()
    previous = None
    change = None
    if before is not None:
        previous = PreviousSession(
            id=before.id,
            ended_at=before.ended_at,
            repetitions=_stored_totals(db, before).repetitions,
            form_score=before.form_score,
        )
        if session.form_score is not None and before.form_score is not None:
            change = session.form_score - before.form_score
    return SessionSummary(
        duration_seconds=_seconds(session),
        totals=_stored_totals(db, session),
        form_score=session.form_score,
        scored_repetitions=session.scored_repetitions or 0,
        scoring_version=session.scoring_version,
        previous=previous,
        score_change=change,
    )


def brief(db: Session, session: ExerciseSession, template: ExerciseTemplate) -> SessionBrief:
    return SessionBrief(
        id=session.id,
        status=session.status,
        started_at=session.started_at,
        ended_at=session.ended_at,
        exercise=ExerciseBrief.model_validate(template),
        sets=session.sets,
        reps=session.reps,
        duration_seconds=_seconds(session),
        totals=_stored_totals(db, session),
        form_score=session.form_score,
        scoring_version=session.scoring_version,
        flag_reasons=session.flag_reasons or [],
        reviewed_at=session.reviewed_at,
        pain_before=session.pain_before,
        pain_after=session.pain_after,
        has_notes=bool(session.patient_note or session.clinician_note),
    )


def record_pain(
    db: Session, patient: Account, session_id: uuid.UUID, sent: PainIn, ip: str | None
) -> ExerciseSession:
    """Stores an optional pain rating for one of the patient's own sessions
    (US 5.3). It can be changed for a day after the session started, then it
    is part of the record."""
    session = own_session(db, patient, session_id, lock=True)
    if clock.utcnow() - session.started_at > PAIN_WINDOW:
        raise errors.conflict("pain_log_closed", "This session can no longer be changed.")
    if sent.moment == "before":
        session.pain_before = sent.score
    else:
        session.pain_after = sent.score
    if sent.note is not None:
        session.patient_note = sent.note.strip() or None
    audit.record(
        db,
        "session.pain_logged",
        actor_id=patient.id,
        target_type="exercise_session",
        target_id=session.id,
        # The rating itself is health data and stays out of the audit trail.
        detail={"moment": sent.moment, "answered": sent.score is not None},
        ip=ip,
    )
    db.commit()
    return session


def _aware(moment: datetime | None) -> datetime | None:
    return moment.replace(tzinfo=UTC) if moment is not None and moment.tzinfo is None else moment


def history(
    db: Session,
    patient_id: uuid.UUID,
    *,
    exercise_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[SessionBrief]:
    """A patient's ended sessions, most recent first (US 5.1). Only sessions
    that happened are returned: a day without one is simply absent, never a
    row with a made-up score."""
    query = (
        select(ExerciseSession, ExerciseTemplate)
        .join(ExerciseTemplate, ExerciseTemplate.id == ExerciseSession.exercise_template_id)
        .where(ExerciseSession.patient_id == patient_id, ExerciseSession.status.in_(ENDED))
    )
    if exercise_id is not None:
        query = query.where(ExerciseSession.exercise_template_id == exercise_id)
    if since is not None:
        query = query.where(ExerciseSession.started_at >= _aware(since))
    if until is not None:
        query = query.where(ExerciseSession.started_at < _aware(until))
    rows = db.execute(query.order_by(ExerciseSession.started_at.desc()).limit(HISTORY_LIMIT)).all()
    return [brief(db, session, template) for session, template in rows]


def detail(db: Session, session: ExerciseSession) -> SessionDetail:
    """One session with every repetition it holds, in the order performed."""
    template = db.get(ExerciseTemplate, session.exercise_template_id)
    repetitions = db.execute(
        select(SessionRepetition, SessionRepetition.series.is_not(None))
        .where(SessionRepetition.session_id == session.id)
        .order_by(SessionRepetition.set_number, SessionRepetition.rep_number)
    ).all()
    current = reference_service.current(db, session.patient_id, template.id)
    in_reference = set(current.repetition_ids) if current is not None else set()
    return SessionDetail(
        **brief(db, session, template).model_dump(),
        difficulty=session.difficulty,
        rest_seconds=session.rest_seconds,
        checks=session.checks,
        scored_repetitions=session.scored_repetitions,
        patient_note=session.patient_note,
        clinician_note=session.clinician_note,
        clinician_note_at=session.clinician_note_at,
        reference_supported=template.slug in personal.CUTS,
        repetitions=[
            RepetitionDetail(
                id=repetition.id,
                set_number=repetition.set_number,
                rep_number=repetition.rep_number,
                started_ms=repetition.started_ms,
                ended_ms=repetition.ended_ms,
                tier=repetition.tier,
                feedback=repetition.feedback,
                unmeasured=[key for key, value in repetition.measures.items() if value is None],
                can_be_reference=bool(kept) and template.slug in personal.CUTS,
                in_reference=str(repetition.id) in in_reference,
                reference_distance=repetition.reference_distance,
                judged_correct=(
                    None
                    if repetition.correct_probability is None
                    else repetition.correct_probability >= scoring.CORRECT_FROM
                ),
            )
            for repetition, kept in repetitions
        ],
    )


def to_out(db: Session, session: ExerciseSession) -> SessionOut:
    template = db.get(ExerciseTemplate, session.exercise_template_id)
    return SessionOut(
        id=session.id,
        status=session.status,
        started_at=session.started_at,
        ended_at=session.ended_at,
        exercise=ExerciseBrief.model_validate(template),
        sets=session.sets,
        reps=session.reps,
        rest_seconds=session.rest_seconds,
        difficulty=session.difficulty,
        prescription_revision=session.prescription_revision,
        template_version=session.template_version,
        required_landmarks=_required(template.target_joints, session.checks, template.slug),
        checks=session.checks,
        totals=totals(db, session.id),
        pause=_pause(db, session),
        series=_series(db, session),
        summary=summary(db, session),
    )


def _channels(db: Session, session: ExerciseSession) -> tuple[str, ...]:
    """The values of one frame, in order: the session's classifier's, or else
    the standard ones (app.personal) a reference is made of."""
    model = model_registry.classifier_of(db, session.scoring_version)
    return tuple(model.channels) if model is not None else personal.CHANNELS


def _series(db: Session, session: ExerciseSession) -> SeriesSpec | None:
    """What the app has to send with each repetition: for the session's
    scorer, and so its first repetitions can become the patient's reference.
    None once the session has ended."""
    if session.status not in UNDER_WAY:
        return None
    channels = _channels(db, session)
    sides = len(pose_features.SIDES)
    joints = [name.removeprefix("left_") for name in channels if name.startswith("left_")]
    return SeriesSpec(
        joints=joints,
        checks=list(channels[len(joints) * sides :]),
        channels=list(channels),
        max_frames=MAX_SERIES_FRAMES,
    )


def start(
    db: Session, patient: Account, item_id: uuid.UUID, evidence: PrecheckEvidence, ip: str | None
) -> ExerciseSession:
    item, template = _current_item(db, patient, item_id)
    required = _required(template.target_joints, template.checks, template.slug)
    problems = pose.precheck_problems(
        required,
        brightness=evidence.brightness,
        visibility=evidence.visibility,
        held_ms=evidence.held_ms,
        view=template.camera_view,
        shoulder_ratio=evidence.shoulder_ratio,
    )
    if problems:
        # No session row is written, so nothing can ever be scored against a
        # camera setup that did not pass.
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "precheck_failed",
            "Your camera setup has not passed the check yet. Follow the guidance on screen and try again.",
            problems=problems,
        )

    now = clock.utcnow()
    # One session at a time: one left open (a closed tab, a lost connection) is
    # closed as abandoned rather than left running forever.
    for stale in db.execute(
        select(ExerciseSession)
        .where(ExerciseSession.patient_id == patient.id, ExerciseSession.status.in_(UNDER_WAY))
        .with_for_update()
    ).scalars():
        _close(db, stale, ABANDONED, patient)
    db.flush()

    # A patient with a reference for this exercise is judged against it;
    # everyone else by the production model or the rule.
    reference = (
        reference_service.current(db, patient.id, template.id) if template.slug in personal.CUTS else None
    )
    session = ExerciseSession(
        id=uuid.uuid4(),
        patient_id=patient.id,
        plan_id=item.plan_id,
        plan_exercise_id=item.id,
        exercise_template_id=template.id,
        # Copies, not references: editing the plan or the thresholds later
        # must never change what this session was performed and scored against.
        template_version=template.version,
        checks=template.checks,
        prescription_revision=item.revision,
        sets=item.sets,
        reps=item.reps,
        rest_seconds=item.rest_seconds,
        difficulty=item.difficulty.value,
        status=ACTIVE,
        started_at=now,
        # Fixed here: promoting or rolling back a model later never changes
        # how a session already under way is scored.
        scoring_version=(
            personal.VERSION if reference is not None else model_registry.scorer_for(db, template.slug)
        ),
        reference_id=reference.id if reference is not None else None,
        precheck={
            "brightness": evidence.brightness,
            "held_ms": evidence.held_ms,
            "visibility": {name: evidence.visibility[name] for name in required},
            "min_visibility": pose.MIN_VISIBILITY,
            "min_brightness": pose.MIN_BRIGHTNESS,
            "hold_ms": pose.HOLD_MS,
            "camera_view": template.camera_view,
            "shoulder_ratio": evidence.shoulder_ratio,
        },
    )
    db.add(session)
    try:
        db.flush()
    except IntegrityError as exc:
        # Two starts at the same moment: only one session becomes the active one.
        db.rollback()
        raise errors.conflict(
            "session_conflict", "A session was just started on another device. Try again."
        ) from exc
    audit.record(
        db,
        "session.started",
        actor_id=patient.id,
        target_type="exercise_session",
        target_id=session.id,
        detail={
            "plan_exercise_id": str(item.id),
            "exercise_template_id": str(template.id),
            "template_version": template.version,
            "prescription_revision": item.revision,
            "scoring_version": session.scoring_version,
        },
        ip=ip,
    )
    db.commit()
    return session


def own_session(
    db: Session, patient: Account, session_id: uuid.UUID, *, lock: bool = False
) -> ExerciseSession:
    query = select(ExerciseSession).where(
        ExerciseSession.id == session_id, ExerciseSession.patient_id == patient.id
    )
    session = db.execute(query.with_for_update() if lock else query).scalar_one_or_none()
    if session is None:
        raise errors.not_found("Session not found.")
    return session


def end(db: Session, patient: Account, session_id: uuid.UUID, ip: str | None) -> ExerciseSession:
    session = own_session(db, patient, session_id, lock=True)
    if session.status not in UNDER_WAY:
        # Ending twice (a double tap, a retry after a lost reply) changes nothing.
        return session
    # A patient may stop while paused: nobody is made to carry on after a RED.
    ended_while_paused = session.status == PAUSED
    _close(db, session, COMPLETED, patient)
    audit.record(
        db,
        "session.ended",
        actor_id=patient.id,
        target_type="exercise_session",
        target_id=session.id,
        detail={
            "seconds": int((session.ended_at - session.started_at).total_seconds()),
            "ended_while_paused": ended_while_paused,
            **session.totals,
            "form_score": session.form_score,
            "scoring_version": session.scoring_version,
            "flag_reasons": session.flag_reasons or [],
        },
        ip=ip,
    )
    db.commit()
    return session


def _repetition_out(session: ExerciseSession, repetition: SessionRepetition) -> RepetitionOut:
    paused_by_this = (
        session.status == PAUSED and repetition.tier == severity.RED and repetition.acknowledged_at is None
    )
    return RepetitionOut(
        id=repetition.id,
        set_number=repetition.set_number,
        rep_number=repetition.rep_number,
        started_ms=repetition.started_ms,
        ended_ms=repetition.ended_ms,
        tier=repetition.tier,
        feedback=repetition.feedback,
        unmeasured=[key for key, value in repetition.measures.items() if value is None],
        session_status=session.status,
        pause=_pause_of(repetition) if paused_by_this else None,
        judged_correct=(
            None
            if repetition.correct_probability is None
            else repetition.correct_probability >= scoring.CORRECT_FROM
        ),
    )


def _same_repetition(stored: SessionRepetition, sent: RepetitionIn) -> bool:
    return (
        stored.set_number == sent.set_number
        and stored.rep_number == sent.rep_number
        and stored.started_ms == sent.started_ms
        and stored.ended_ms == sent.ended_ms
        and stored.measures == sent.measures
    )


class _Judged:
    """What the session's scorer made of one repetition."""

    def __init__(self) -> None:
        self.probability: float | None = None
        self.judged_by: str | None = None
        self.distance: float | None = None
        # The resampled angles to keep, for a reference later.
        self.series: list[list[float | None]] | None = None


def _judge(db: Session, session: ExerciseSession, sent: RepetitionIn) -> _Judged:
    """How likely the session's scorer thinks the repetition correct, and its
    version; empty when the rule scores this session or the app sent no
    frames. This never decides the tier or the safety pause: those stay with
    the thresholds."""
    judged = _Judged()
    if sent.frames is None:
        return judged
    channels = _channels(db, session)
    if any(len(frame) != len(channels) for frame in sent.frames):
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "frames_malformed",
            f"Every frame needs {len(channels)} values, in the order the session asks for.",
        )
    template = db.get(ExerciseTemplate, session.exercise_template_id)
    standard = channels == personal.CHANNELS
    if standard:
        kept = db.execute(
            select(func.count())
            .select_from(SessionRepetition)
            .where(SessionRepetition.session_id == session.id, SessionRepetition.series.is_not(None))
        ).scalar_one()
        values, mask = personal.series_of(sent.frames)
        if kept < personal.STORED_SERIES:
            judged.series = personal.encode(values, mask)

    if session.scoring_version == personal.VERSION and standard:
        reference = db.get(ExerciseReference, session.reference_id)
        distance = personal.distance_for(template.slug, values, mask, *personal.decode(reference.series))
        if distance is not None:
            judged.distance = round(distance, 3)
            judged.probability = personal.probability_correct(distance, template.slug)
            judged.judged_by = personal.VERSION
        return judged

    model = model_registry.classifier_of(db, session.scoring_version)
    if model is None:
        return judged
    probability = model.judge(sent.frames, template.slug)
    if probability is not None:
        judged.probability, judged.judged_by = probability, session.scoring_version
    return judged


def record_repetition(
    db: Session, patient: Account, session_id: uuid.UUID, sent: RepetitionIn, ip: str | None
) -> tuple[RepetitionOut, bool]:
    """Stores one repetition and classifies it. Returns what was stored and
    whether it was already there (the same key sent again)."""
    # The lock makes "classify, store and pause" one step: two repetitions
    # arriving together cannot both slip past a pause.
    session = own_session(db, patient, session_id, lock=True)

    stored = db.execute(
        select(SessionRepetition).where(
            SessionRepetition.session_id == session.id, SessionRepetition.client_key == sent.client_key
        )
    ).scalar_one_or_none()
    if stored is not None:
        if not _same_repetition(stored, sent):
            raise errors.conflict(
                "client_key_reused", "This key was already used for a different repetition."
            )
        # A retry after a lost reply: answer with what was stored the first time.
        return _repetition_out(session, stored), True

    if session.status == PAUSED:
        raise errors.conflict(
            "session_paused",
            "Read the message on screen before you continue.",
            pause=_pause(db, session).model_dump(mode="json"),
        )
    if session.status != ACTIVE:
        raise errors.conflict("session_not_active", "This session has already ended.")
    if sent.set_number > session.sets:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "set_out_of_range",
            f"This exercise was prescribed with {session.sets} sets.",
        )
    if sent.rep_number > session.reps:
        # The app moves to the next set after the prescribed repetitions, so
        # only a faulty client sends more. It also keeps one session within
        # the 500 KB of US 8.2.
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "rep_out_of_range",
            f"This exercise was prescribed with {session.reps} repetitions per set.",
        )

    known = [check["key"] for check in session.checks]
    unknown = sorted(set(sent.measures) - set(known))
    if unknown:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "unknown_check",
            "This session does not have a check called " + ", ".join(unknown) + ".",
        )
    missing = [key for key in known if key not in sent.measures]
    if missing:
        # Every check must be accounted for, even as "could not be measured",
        # so a safety check can never be skipped by leaving it out.
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "measures_incomplete",
            "A measurement is missing for " + ", ".join(missing) + ".",
            missing=missing,
        )

    tier, feedback, _ = severity.classify(sent.measures, session.checks)
    judged = _judge(db, session, sent)
    repetition = SessionRepetition(
        id=uuid.uuid4(),
        session_id=session.id,
        client_key=sent.client_key,
        set_number=sent.set_number,
        rep_number=sent.rep_number,
        started_ms=sent.started_ms,
        ended_ms=sent.ended_ms,
        # In the template's order, so the stored record reads the same every time.
        measures={key: sent.measures[key] for key in known},
        tier=tier,
        feedback=feedback,
        created_at=clock.utcnow(),
        correct_probability=judged.probability,
        model_version=judged.judged_by,
        reference_distance=judged.distance,
    )
    if judged.series is not None:
        repetition.series = judged.series
    db.add(repetition)
    if tier == severity.RED:
        # In the same transaction as the repetition: a RED is never stored
        # without the pause.
        session.status = PAUSED
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise errors.conflict(
            "repetition_exists",
            f"Repetition {sent.rep_number} of set {sent.set_number} is already stored.",
        ) from exc
    if tier == severity.RED:
        # A RED goes to the physiotherapist at once, not when the session
        # ends: a patient who closes the app after it must still be seen.
        flag(db, session, FLAG_RED, patient)
        audit.record(
            db,
            "session.paused",
            actor_id=patient.id,
            target_type="exercise_session",
            target_id=session.id,
            detail={
                "repetition_id": str(repetition.id),
                "set_number": repetition.set_number,
                "rep_number": repetition.rep_number,
                "check": feedback[0]["check"],
            },
            ip=ip,
        )
    db.commit()
    return _repetition_out(session, repetition), False


def acknowledge(
    db: Session, patient: Account, session_id: uuid.UUID, repetition_id: uuid.UUID, ip: str | None
) -> ExerciseSession:
    """Records that the patient has read the corrective message of a RED
    repetition, and lets the session carry on."""
    session = own_session(db, patient, session_id, lock=True)
    repetition = db.execute(
        select(SessionRepetition).where(
            SessionRepetition.id == repetition_id, SessionRepetition.session_id == session.id
        )
    ).scalar_one_or_none()
    if repetition is None or repetition.tier != severity.RED:
        raise errors.conflict("wrong_repetition", "That is not the repetition this session is paused on.")
    if repetition.acknowledged_at is not None:
        # Acknowledging twice (a double tap, a retry) changes nothing.
        return session
    if session.status != PAUSED:
        raise errors.conflict("session_not_paused", "This session is not paused.")

    repetition.acknowledged_at = clock.utcnow()
    session.status = ACTIVE
    audit.record(
        db,
        "session.pause_acknowledged",
        actor_id=patient.id,
        target_type="exercise_session",
        target_id=session.id,
        detail={"repetition_id": str(repetition.id), "check": repetition.feedback[0]["check"]},
        ip=ip,
    )
    db.commit()
    return session
