"""The progress report a physiotherapist exports for one patient (US 5.3):
the sessions in a date range with their scores, the trend, pain ratings and
any notes, as a PDF.

Gathering the data and drawing it are separate, so what goes into a report
can be tested without reading a PDF.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import pdf
from app.models import Account, ExerciseSession, ExerciseTemplate

ENDED = ("completed", "abandoned")
# A report never covers more than this, so it stays quick to produce.
MAX_DAYS = 366

TEAL: pdf.Color = (0.0, 0.42, 0.42)
SERIES: tuple[pdf.Color, ...] = (
    (0.0, 0.42, 0.42),
    (0.66, 0.40, 0.31),
    (0.10, 0.24, 0.37),
    (0.90, 0.32, 0.0),
    (0.29, 0.25, 0.55),
)


@dataclass(frozen=True)
class ReportSession:
    started_at: datetime
    exercise: str
    status: str
    duration_seconds: int
    repetitions: int
    ok: int
    info: int
    amber: int
    red: int
    # None when the session had nothing to score.
    form_score: int | None
    # None when the patient chose not to answer.
    pain_before: int | None
    pain_after: int | None
    patient_note: str | None
    clinician_note: str | None


@dataclass(frozen=True)
class ReportData:
    patient: str
    physiotherapist: str
    since: datetime
    until: datetime
    generated_at: datetime
    # Oldest first.
    sessions: tuple[ReportSession, ...]

    @property
    def scored(self) -> tuple[ReportSession, ...]:
        return tuple(s for s in self.sessions if s.form_score is not None)

    def trends(self) -> list[tuple[str, int, int, int]]:
        """For each exercise with a scored session: its name, first score,
        latest score and how many scored sessions lie between them."""
        by_exercise: dict[str, list[int]] = {}
        for session in self.scored:
            by_exercise.setdefault(session.exercise, []).append(session.form_score)
        return [(name, scores[0], scores[-1], len(scores)) for name, scores in by_exercise.items()]


def gather(
    db: Session,
    physiotherapist: Account,
    patient: Account,
    since: datetime,
    until: datetime,
    generated_at: datetime,
) -> ReportData:
    """The ended sessions of [patient], and of nobody else, that started in
    the range. The caller has already checked that the patient is assigned to
    the physiotherapist asking."""
    rows = db.execute(
        select(ExerciseSession, ExerciseTemplate.name)
        .join(ExerciseTemplate, ExerciseTemplate.id == ExerciseSession.exercise_template_id)
        .where(
            ExerciseSession.patient_id == patient.id,
            ExerciseSession.status.in_(ENDED),
            ExerciseSession.started_at >= since,
            ExerciseSession.started_at < until,
        )
        .order_by(ExerciseSession.started_at)
    ).all()
    sessions = []
    for session, exercise in rows:
        totals = session.totals or {}
        sessions.append(
            ReportSession(
                started_at=session.started_at,
                exercise=exercise,
                status=session.status,
                duration_seconds=int(
                    ((session.ended_at or session.started_at) - session.started_at).total_seconds()
                ),
                repetitions=totals.get("repetitions", 0),
                ok=totals.get("ok", 0),
                info=totals.get("info", 0),
                amber=totals.get("amber", 0),
                red=totals.get("red", 0),
                form_score=session.form_score,
                pain_before=session.pain_before,
                pain_after=session.pain_after,
                patient_note=session.patient_note,
                clinician_note=session.clinician_note,
            )
        )
    return ReportData(
        patient=patient.full_name,
        physiotherapist=physiotherapist.full_name,
        since=since,
        until=until,
        generated_at=generated_at,
        sessions=tuple(sessions),
    )


def filename(patient_id: uuid.UUID, since: datetime, until: datetime) -> str:
    # The patient's name stays out of the file name: it ends up in download
    # folders and browser histories.
    return f"physioai-report-{str(patient_id)[:8]}-{since:%Y%m%d}-{until:%Y%m%d}.pdf"


def _day(moment: datetime) -> str:
    return f"{moment.day} {moment:%b %Y}"


def _moment(moment: datetime) -> str:
    return f"{moment.day} {moment:%b %Y}, {moment:%H:%M}"


def _pain(session: ReportSession) -> str:
    if session.pain_before is None and session.pain_after is None:
        return "-"

    def one(value: int | None) -> str:
        return "-" if value is None else str(value)

    return f"{one(session.pain_before)} > {one(session.pain_after)}"


class _Layout:
    """Writes down the page, starting a new one when it runs out of room."""

    MARGIN = 48.0
    BOTTOM = 64.0

    def __init__(self, data: ReportData) -> None:
        self.data = data
        self.doc = pdf.Document(title=f"PhysioAI progress report: {data.patient}")
        self.page = self.doc.add_page()
        self.y = self.MARGIN
        self.width = self.page.width - 2 * self.MARGIN

    @property
    def left(self) -> float:
        return self.MARGIN

    @property
    def right(self) -> float:
        return self.page.width - self.MARGIN

    def room(self, height: float) -> None:
        """Moves to a new page unless [height] more points fit on this one."""
        if self.y + height > self.page.height - self.BOTTOM:
            self.page = self.doc.add_page()
            self.y = self.MARGIN

    def heading(self, text: str) -> None:
        self.room(60)
        self.y += 22
        self.page.text(self.left, self.y, text, size=13, bold=True)
        self.y += 8
        self.page.line(self.left, self.y, self.right, self.y)
        self.y += 6

    def paragraph(
        self, text: str, *, size: float = 10, color: pdf.Color = pdf.BLACK, indent: float = 0
    ) -> None:
        for line in pdf.wrap(text, size, self.width - indent):
            self.room(size + 5)
            self.y += size + 4
            self.page.text(self.left + indent, self.y, line, size=size, color=color)

    def footers(self) -> None:
        count = len(self.doc.pages)
        for number, page in enumerate(self.doc.pages, start=1):
            y = page.height - 40
            page.line(self.left, y - 12, self.right, y - 12)
            page.text(
                self.left,
                y,
                "Form scores and severity tiers support a physiotherapist's judgment. "
                "They are not a diagnosis.",
                size=8,
                color=pdf.GREY,
            )
            page.text(self.right, y, f"Page {number} of {count}", size=8, color=pdf.GREY, align="right")


def _chart(layout: _Layout, data: ReportData) -> None:
    """Form score against time, one line for each exercise. Only sessions
    that have a score are plotted; nothing is drawn for a day without one."""
    scored = data.scored
    height = 150.0
    layout.room(height + 60)
    page = layout.page
    top = layout.y + 14
    left = layout.left + 26
    right = layout.right - 8
    bottom = top + height

    for mark in (0, 25, 50, 75, 100):
        y = bottom - height * mark / 100
        page.line(left, y, right, y)
        page.text(left - 6, y + 3, str(mark), size=8, color=pdf.GREY, align="right")

    start = scored[0].started_at.timestamp()
    span = scored[-1].started_at.timestamp() - start

    def x(moment: datetime) -> float:
        if span == 0:
            return (left + right) / 2
        return left + (right - left) * (moment.timestamp() - start) / span

    exercises = list(dict.fromkeys(s.exercise for s in scored))
    for index, exercise in enumerate(exercises):
        color = SERIES[index % len(SERIES)]
        points = [
            (x(s.started_at), bottom - height * s.form_score / 100) for s in scored if s.exercise == exercise
        ]
        page.polyline(points, color=color)
        for px, py in points:
            page.dot(px, py, 2.6, fill=color)

    page.text(left, bottom + 12, _day(scored[0].started_at), size=8, color=pdf.GREY)
    if span:
        page.text(right, bottom + 12, _day(scored[-1].started_at), size=8, color=pdf.GREY, align="right")

    # The legend, wrapping when the exercises do not fit on one line.
    lx = left
    ly = bottom + 28
    for index, exercise in enumerate(exercises):
        needed = 14 + pdf.text_width(exercise, 9) + 16
        if lx + needed > right and lx > left:
            lx = left
            ly += 13
        page.rect(lx, ly - 7, 8, 8, fill=SERIES[index % len(SERIES)])
        page.text(lx + 12, ly, exercise, size=9)
        lx += needed
    layout.y = ly + 4


# Column: title, x offset from the left margin, alignment.
_COLUMNS = (
    ("Date", 0.0, "left"),
    ("Exercise", 98.0, "left"),
    ("Reps", 248.0, "right"),
    ("Score", 290.0, "right"),
    ("Good", 330.0, "right"),
    ("Info", 364.0, "right"),
    ("Amber", 402.0, "right"),
    ("Red", 434.0, "right"),
    ("Pain", 499.0, "right"),
)


def _table(layout: _Layout, sessions: tuple[ReportSession, ...]) -> None:
    def header() -> None:
        layout.y += 14
        for title, offset, align in _COLUMNS:
            layout.page.text(
                layout.left + offset, layout.y, title, size=8, bold=True, color=pdf.GREY, align=align
            )
        layout.y += 5
        layout.page.line(layout.left, layout.y, layout.right, layout.y)

    header()
    for session in sessions:
        if layout.y + 18 > layout.page.height - layout.BOTTOM:
            layout.page = layout.doc.add_page()
            layout.y = layout.MARGIN
            header()
        layout.y += 14
        name = session.exercise
        if session.status == "abandoned":
            name += " (not finished)"
        cells = (
            _moment(session.started_at),
            name,
            str(session.repetitions),
            # A session with nothing to score has no score; it is not 0.
            "-" if session.form_score is None else str(session.form_score),
            str(session.ok),
            str(session.info),
            str(session.amber),
            str(session.red),
            _pain(session),
        )
        for (_, offset, align), cell in zip(_COLUMNS, cells, strict=True):
            layout.page.text(layout.left + offset, layout.y, cell, size=9, align=align)
        layout.y += 4
        layout.page.line(layout.left, layout.y, layout.right, layout.y, width=0.4)


def render(data: ReportData) -> bytes:
    layout = _Layout(data)
    page = layout.page

    page.text(layout.left, layout.y + 4, "PhysioAI", size=11, bold=True, color=TEAL)
    layout.y += 32
    page.text(layout.left, layout.y, "Progress report", size=22, bold=True)
    layout.y += 10
    for label, value in (
        ("Patient", data.patient),
        ("Physiotherapist", data.physiotherapist),
        ("Period", f"{_day(data.since)} to {_day(data.until)} (times in UTC)"),
        ("Generated", _moment(data.generated_at) + " UTC"),
    ):
        layout.y += 15
        page.text(layout.left, layout.y, label, size=10, color=pdf.GREY)
        page.text(layout.left + 96, layout.y, value, size=10)

    sessions = data.sessions
    scored = data.scored
    layout.heading("Summary")
    if not sessions:
        layout.paragraph("No sessions were recorded in this period.")
        layout.footers()
        return layout.doc.render()

    paused = sum(1 for s in sessions if s.red)
    layout.paragraph(
        f"{len(sessions)} session{'s' if len(sessions) != 1 else ''} in this period, "
        f"{len(scored)} with a form score."
        + (
            f" Average form score: {round(sum(s.form_score for s in scored) / len(scored))} out of 100."
            if scored
            else ""
        )
    )
    layout.paragraph(
        "No session was paused for safety."
        if paused == 0
        else f"{paused} session{'s were' if paused != 1 else ' was'} paused for safety (a RED repetition)."
    )
    rated = [s for s in sessions if s.pain_before is not None or s.pain_after is not None]
    layout.paragraph(
        "The patient did not log pain in this period."
        if not rated
        else f"Pain was logged in {len(rated)} session{'s' if len(rated) != 1 else ''} "
        "(0 is no pain, 10 the worst imaginable)."
    )

    layout.heading("Form score trend")
    if scored:
        for name, first, latest, count in data.trends():
            layout.paragraph(
                f"{name}: {latest} out of 100, from one scored session."
                if count == 1
                else f"{name}: {first} to {latest} over {count} scored sessions."
            )
        _chart(layout, data)
        unscored = len(sessions) - len(scored)
        if unscored:
            layout.paragraph(
                f"{unscored} session{'s' if unscored != 1 else ''} had nothing to score and "
                f"{'are' if unscored != 1 else 'is'} not on the graph.",
                size=9,
                color=pdf.GREY,
            )
    else:
        layout.paragraph("No session in this period had anything to score.")

    layout.heading("Sessions")
    layout.paragraph(
        "Pain is shown as before > after the session; a dash means it was not answered.",
        size=9,
        color=pdf.GREY,
    )
    _table(layout, sessions)

    noted = [s for s in sessions if s.patient_note or s.clinician_note]
    layout.heading("Notes")
    if not noted:
        layout.paragraph("No notes were written in this period.")
    for session in noted:
        layout.room(40)
        layout.y += 6
        layout.paragraph(f"{_moment(session.started_at)}  -  {session.exercise}", size=9, color=pdf.GREY)
        if session.patient_note:
            layout.paragraph(f"Patient: {session.patient_note}", indent=10)
        if session.clinician_note:
            layout.paragraph(f"Physiotherapist: {session.clinician_note}", indent=10)

    layout.footers()
    return layout.doc.render()
