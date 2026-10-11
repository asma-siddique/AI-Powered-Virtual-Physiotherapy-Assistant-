"""US 5.3 - optional pain logging, notes and the exported progress report."""

import re
import time as stopwatch
import zlib
from datetime import UTC, datetime, timedelta

import pytest
from sqlalchemy import select

from app import pdf, report
from app.models import AuditLog, ExerciseSession, Role
from tests.conftest import bearer, sign_in
from tests.test_repetitions import Arm
from tests.test_session_review import AMBER, RED, end, later, perform
from tests.test_sessions import SESSIONS, Case

PHYSIO_SESSIONS = "/api/v1/physio/sessions"


@pytest.fixture
def arm(client, make) -> Arm:
    return Arm(client, make)


def pdf_text(document: bytes) -> str:
    """Every piece of text drawn in a PDF made by app.pdf, in drawing order."""
    drawn = []
    for stream in re.findall(rb"stream\n(.*?)\nendstream", document, re.DOTALL):
        content = zlib.decompress(stream)
        for raw in re.findall(rb"\((.*?)(?<!\\)\) Tj", content, re.DOTALL):
            text = raw.replace(b"\\(", b"(").replace(b"\\)", b")").replace(b"\\\\", b"\\")
            drawn.append(text.decode("cp1252"))
    return "\n".join(drawn)


def pain(arm: Arm, moment: str, score: int | None, note: str | None = None, headers: dict | None = None):
    body = {"moment": moment, "score": score}
    if note is not None:
        body["note"] = note
    return arm.client.put(f"{SESSIONS}/{arm.session_id}/pain", json=body, headers=headers or arm.headers)


def export(arm: Arm, headers: dict | None = None, patient=None, **params):
    return arm.client.get(
        f"/api/v1/physio/patients/{(patient or arm.patient).id}/report",
        params=params,
        headers=headers or arm.physio_headers,
    )


# --- The PDF writer ----------------------------------------------------------


def test_text_is_measured_and_wrapped_at_spaces():
    assert pdf.text_width("iii", 10) < pdf.text_width("WWW", 10)
    assert pdf.text_width("Report", 10, bold=True) > pdf.text_width("Report", 10)
    lines = pdf.wrap("one two three four five six seven", 10, 60)
    assert len(lines) > 1
    assert " ".join(lines) == "one two three four five six seven"
    assert all(pdf.text_width(line, 10) <= 60 for line in lines)
    assert pdf.wrap("first\nsecond", 10, 500) == ["first", "second"]


def test_a_document_is_a_well_formed_pdf():
    document = pdf.Document(title="A (test) report")
    page = document.add_page()
    page.text(50, 50, "Brackets (like these) and a back\\slash", bold=True)
    page.text(50, 70, "Not Latin: عائشہ")
    page.line(50, 80, 200, 80)
    page.polyline([(50, 100), (80, 90), (120, 110)], color=(0, 0.4, 0.4))
    page.dot(80, 90, 3, fill=(0, 0.4, 0.4))
    document.add_page()
    rendered = document.render()

    assert rendered.startswith(b"%PDF-1.4")
    assert rendered.rstrip().endswith(b"%%EOF")
    # The cross-reference table is where the file says it is, and lists every object.
    start = int(re.search(rb"startxref\n(\d+)", rendered).group(1))
    assert rendered[start : start + 4] == b"xref"
    count = int(re.search(rb"xref\n0 (\d+)", rendered).group(1))
    assert len(re.findall(rb"\d+ 0 obj", rendered)) == count - 1
    for offset in re.findall(rb"(\d{10}) 00000 n", rendered):
        assert re.match(rb"\d+ 0 obj", rendered[int(offset) :])
    assert b"/Count 2" in rendered
    text = pdf_text(rendered)
    assert "Brackets (like these) and a back\\slash" in text
    # Text the built-in font cannot draw is replaced, not left to break the file.
    assert "Not Latin: ?????" in text


# --- Pain logging ------------------------------------------------------------


def test_pain_can_be_logged_before_and_after_with_a_note(arm, db):
    before = pain(arm, "before", 3)
    end(arm)
    after = pain(arm, "after", 5, note="  A pinch in my left shoulder near the top.  ")

    assert before.status_code == 200, before.text
    assert (before.json()["pain_before"], before.json()["pain_after"]) == (3, None)
    assert after.status_code == 200, after.text
    detail = after.json()
    assert (detail["pain_before"], detail["pain_after"]) == (3, 5)
    assert detail["patient_note"] == "A pinch in my left shoulder near the top."
    listed = arm.client.get(SESSIONS, headers=arm.headers).json()[0]
    assert (listed["pain_before"], listed["pain_after"], listed["has_notes"]) == (3, 5, True)
    # The audit trail says that it was logged, never what was logged.
    entries = db.execute(select(AuditLog).where(AuditLog.action == "session.pain_logged")).scalars().all()
    assert [e.detail for e in entries] == [
        {"moment": "before", "answered": True},
        {"moment": "after", "answered": True},
    ]


def test_pain_is_never_required_and_not_answering_is_not_zero(arm):
    session = perform(arm, {})

    listed = arm.client.get(SESSIONS, headers=arm.headers).json()[0]

    assert session["status"] == "completed"
    assert (listed["pain_before"], listed["pain_after"], listed["has_notes"]) == (None, None, False)


def test_an_answer_can_be_changed_or_taken_back(arm):
    pain(arm, "before", 7, note="Sore today.")

    changed = pain(arm, "before", 2)
    cleared = pain(arm, "before", None, note="")

    # Leaving the note out keeps it; sending it empty removes it.
    assert (changed.json()["pain_before"], changed.json()["patient_note"]) == (2, "Sore today.")
    assert (cleared.json()["pain_before"], cleared.json()["patient_note"]) == (None, None)


@pytest.mark.parametrize("score", [-1, 11, 4.5, "bad"])
def test_a_rating_outside_the_scale_is_refused(arm, score):
    response = pain(arm, "after", score)

    assert response.status_code == 422
    assert (
        arm.client.get(SESSIONS + f"/{arm.session_id}/detail", headers=arm.headers).json()["pain_after"]
        is None
    )


def test_pain_can_only_be_logged_for_your_own_session(arm, client, make):
    someone = Case(client, make, exercise="Leg Lunge")

    response = pain(arm, "before", 4, headers=someone.headers)

    assert response.status_code == 404
    assert pain(arm, "sometime", 4).status_code == 422


def test_a_rating_becomes_part_of_the_record_after_a_day(arm, time):
    pain(arm, "before", 4)
    end(arm)
    later(arm, time, hours=25)

    response = pain(arm, "after", 9)

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "pain_log_closed"


# --- The physiotherapist's note ----------------------------------------------


def test_a_physiotherapist_writes_replaces_and_removes_a_note(arm, db):
    session = perform(arm, {})
    url = f"{PHYSIO_SESSIONS}/{session['id']}/note"

    written = arm.client.put(url, json={"note": " Lean is improving. "}, headers=arm.physio_headers)
    replaced = arm.client.put(url, json={"note": "Progress to 3 sets."}, headers=arm.physio_headers)

    assert written.status_code == 200, written.text
    assert written.json()["clinician_note"] == "Lean is improving."
    assert written.json()["clinician_note_at"] is not None
    assert replaced.json()["clinician_note"] == "Progress to 3 sets."
    # The patient sees it with the session.
    seen = arm.client.get(f"{SESSIONS}/{session['id']}/detail", headers=arm.headers).json()
    assert seen["clinician_note"] == "Progress to 3 sets."

    removed = arm.client.put(url, json={"note": "  "}, headers=arm.physio_headers)
    assert (removed.json()["clinician_note"], removed.json()["clinician_note_at"]) == (None, None)
    actions = [
        e.action for e in db.execute(select(AuditLog).where(AuditLog.action.like("session.note%"))).scalars()
    ]
    assert actions == ["session.note_saved", "session.note_saved", "session.note_removed"]
    assert "Progress" not in str([e.detail for e in db.execute(select(AuditLog)).scalars()])


def test_only_the_patients_own_physiotherapist_can_write_a_note(arm, client, make):
    session = perform(arm, {})
    omar = bearer(sign_in(client, make.account(Role.physiotherapist)))
    url = f"{PHYSIO_SESSIONS}/{session['id']}/note"

    assert client.put(url, json={"note": "Not mine."}, headers=omar).status_code == 404
    assert client.put(url, json={"note": "x" * 2001}, headers=arm.physio_headers).status_code == 422
    detail = client.get(f"{PHYSIO_SESSIONS}/{session['id']}", headers=arm.physio_headers).json()
    assert detail["clinician_note"] is None


# --- The exported report -----------------------------------------------------


def test_the_report_shows_sessions_scores_trend_pain_and_notes(arm, db, time):
    pain(arm, "before", 2)
    first = perform(arm, {}, AMBER)  # 78
    pain(arm, "after", 4, note="Tired by the second set.")
    later(arm, time, days=2)
    arm.session_id = arm.begin()
    second = perform(arm, {}, {}, {})  # 100
    arm.client.put(
        f"{PHYSIO_SESSIONS}/{second['id']}/note",
        json={"note": "Good control. Add a third set next week."},
        headers=arm.physio_headers,
    )
    later(arm, time, days=1)
    arm.session_id = arm.begin()
    end(arm)  # nothing to score
    later(arm, time, minutes=5)

    response = export(arm)

    assert response.status_code == 200, response.text
    assert response.headers["content-type"] == "application/pdf"
    assert response.headers["cache-control"] == "no-store"
    disposition = response.headers["content-disposition"]
    assert disposition.startswith('attachment; filename="physioai-report-') and ".pdf" in disposition
    # The file name does not carry the patient's name.
    assert arm.patient.full_name.split()[0].lower() not in disposition.lower()
    assert response.content.startswith(b"%PDF-1.4")

    text = pdf_text(response.content)
    assert "Progress report" in text
    assert arm.patient.full_name in text and "Sarah Malik" in text
    assert "3 sessions in this period, 2 with a form score. Average form score: 89 out of 100." in text
    assert "Arm Abduction: 78 to 100 over 2 scored sessions." in text
    assert "1 session had nothing to score and is not on the graph." in text
    assert "No session was paused for safety." in text
    assert "Pain was logged in 1 session" in text
    assert "2 > 4" in text
    assert "Patient: Tired by the second set." in text
    assert "Physiotherapist: Good control. Add a third set next week." in text
    assert "Page 1 of 1" in text
    # The session with nothing to score has a dash for its score, never 0.
    rows = text.split("Sessions\n", 1)[1].split("Notes\n", 1)[0].split("\n")
    assert "78" in rows and "100" in rows and "-" in rows
    assert first["id"] != second["id"]

    entry = db.execute(select(AuditLog).where(AuditLog.action == "report.exported")).scalar_one()
    assert entry.actor_id == arm.physio.id and entry.target_id == str(arm.patient.id)
    assert entry.detail["sessions"] == 3


def test_the_report_covers_only_the_range_asked_for(arm, time):
    start = time.now()
    perform(arm, RED)
    later(arm, time, days=40)
    arm.session_id = arm.begin()
    perform(arm, {})
    later(arm, time, minutes=5)

    recent = pdf_text(export(arm, since=(start + timedelta(days=20)).isoformat()).content)
    early = pdf_text(
        export(
            arm,
            since=(start - timedelta(days=1)).isoformat(),
            until=(start + timedelta(days=20)).isoformat(),
        ).content
    )
    nothing = pdf_text(
        export(
            arm,
            since=(start + timedelta(days=10)).isoformat(),
            until=(start + timedelta(days=20)).isoformat(),
        ).content
    )

    assert "1 session in this period, 1 with a form score. Average form score: 100" in recent
    assert "1 session was paused for safety" in early
    assert "No sessions were recorded in this period." in nothing


def test_a_report_never_contains_another_patients_data(arm, db, make):
    arm.patient.full_name = "Jane Cooper"
    perform(arm, {})
    pain(arm, "after", 6, note="Only Jane wrote this.")
    # The same physiotherapist's second patient, who has done nothing yet.
    second = make.patient_of(arm.physio)
    second.full_name = "Zainab Qureshi"
    db.commit()

    for_second = export(arm, patient=second)

    assert for_second.status_code == 200
    text = pdf_text(for_second.content)
    assert "Zainab Qureshi" in text
    assert "Jane Cooper" not in text
    assert "Only Jane wrote this." not in text
    assert "No sessions were recorded in this period." in text
    # And the first patient's own report does hold what they wrote.
    assert "Only Jane wrote this." in pdf_text(export(arm).content)


def test_only_the_patients_own_physiotherapist_can_export(arm, client, make):
    perform(arm, {})
    omar = bearer(sign_in(client, make.account(Role.physiotherapist)))
    stranger = make.patient_of(make.account(Role.physiotherapist))

    theirs = export(arm, headers=omar)
    not_mine = export(arm, patient=stranger)

    assert theirs.status_code == 404
    assert not_mine.status_code == 404
    assert b"%PDF" not in theirs.content and b"%PDF" not in not_mine.content
    # The patient cannot export it either: the endpoint is the physiotherapist's.
    assert export(arm, headers=arm.headers).status_code == 403


def test_a_range_that_makes_no_sense_is_refused(arm):
    now = datetime.now(UTC)

    backwards = export(arm, since=now.isoformat(), until=(now - timedelta(days=1)).isoformat())
    too_long = export(arm, since=(now - timedelta(days=400)).isoformat(), until=now.isoformat())

    assert (backwards.status_code, backwards.json()["detail"]["code"]) == (422, "range_invalid")
    assert (too_long.status_code, too_long.json()["detail"]["code"]) == (422, "range_too_long")


def test_three_months_of_daily_sessions_are_drawn_well_inside_five_seconds():
    start = datetime(2026, 7, 1, 9, tzinfo=UTC)
    sessions = tuple(
        report.ReportSession(
            started_at=start + timedelta(days=day),
            exercise=("Arm Abduction", "Squats", "Leg Lunge")[day % 3],
            status="completed",
            duration_seconds=300,
            repetitions=12,
            ok=9,
            info=2,
            amber=1,
            red=0,
            form_score=None if day % 11 == 0 else 60 + day % 40,
            pain_before=day % 5 if day % 2 else None,
            pain_after=day % 7 if day % 3 else None,
            patient_note="Felt fine. " * 6 if day % 9 == 0 else None,
            clinician_note="Keep the same prescription." if day % 13 == 0 else None,
        )
        for day in range(92)
    )
    data = report.ReportData(
        patient="Jane Cooper",
        physiotherapist="Dr. Sarah Malik",
        since=start,
        until=start + timedelta(days=92),
        generated_at=start + timedelta(days=92),
        sessions=sessions,
    )

    began = stopwatch.perf_counter()
    document = report.render(data)
    seconds = stopwatch.perf_counter() - began

    assert seconds < 5
    text = pdf_text(document)
    pages = int(re.search(r"Page 1 of (\d+)", text).group(1))
    assert pages >= 3
    # Every session has its row, on whichever page it fell.
    assert text.count("Arm Abduction") >= 31
    assert [name for name, *_ in data.trends()] == ["Squats", "Leg Lunge", "Arm Abduction"]


def test_the_stored_columns_keep_no_answer_empty(arm, db):
    perform(arm, {})

    stored = db.execute(select(ExerciseSession)).scalar_one()

    assert (stored.pain_before, stored.pain_after, stored.patient_note) == (None, None, None)
