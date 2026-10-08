"""US 2.2 - Exercise prescription editing, with its change history, and the
"plan updated" alert of US 6.2."""

import uuid

import pytest
from sqlalchemy import select

from app.models import AuditLog, ExercisePlan, Notification, PlanExercise, PrescriptionEdit, Role
from tests.conftest import bearer, sign_in

NOBODY = "00000000-0000-0000-0000-000000000000"


class Case:
    """A physiotherapist, their patient, and the patient's current plan."""

    def __init__(self, client, make) -> None:
        self.client = client
        self.physio = make.account(Role.physiotherapist, full_name="Sarah Malik")
        self.patient = make.patient_of(self.physio)
        self.squats = make.exercise("Squats")
        self.lunge = make.exercise("Leg Lunge")
        self.headers = bearer(sign_in(client, self.physio))
        self.plan = self.assign("Week 1")

    def assign(self, name: str) -> dict:
        response = self.client.post(
            f"/api/v1/physio/patients/{self.patient.id}/plans",
            json={
                "name": name,
                "items": [
                    {"exercise_id": str(self.squats.id), "sets": 3, "reps": 12, "note": "Go slowly."},
                    {"exercise_id": str(self.lunge.id), "sets": 2, "reps": 10, "difficulty": "easy"},
                ],
            },
            headers=self.headers,
        )
        assert response.status_code == 201, response.text
        return response.json()

    def later(self, time, **delta: float) -> None:
        """Time passes. A session does not outlive it, so the physiotherapist
        signs in again, as they would on another day."""
        time.advance(**delta)
        self.headers = bearer(sign_in(self.client, self.physio))

    @property
    def item(self) -> dict:
        return self.plan["items"][0]

    def url(self, *, plan: str | None = None, item: str | None = None, patient: str | None = None) -> str:
        return (
            f"/api/v1/physio/patients/{patient or self.patient.id}"
            f"/plans/{plan or self.plan['id']}/items/{item or self.item['id']}"
        )

    def edit(self, body: dict, **where):
        return self.client.patch(self.url(**where), json=body, headers=self.headers)

    def history(self, plan: str | None = None, headers: dict | None = None):
        return self.client.get(
            f"/api/v1/physio/patients/{self.patient.id}/plans/{plan or self.plan['id']}/edits",
            headers=headers or self.headers,
        )


@pytest.fixture
def case(client, make) -> Case:
    return Case(client, make)


def rows(db, model) -> list:
    db.expire_all()
    return list(db.execute(select(model)).scalars())


def test_an_edit_is_timestamped_and_the_previous_values_are_kept(client, db, case, time):
    assigned_at = time.now()
    case.later(time, days=3)

    response = case.edit({"sets": 4, "reps": 10})

    assert response.status_code == 200, response.text
    item = response.json()["items"][0]
    assert (item["sets"], item["reps"], item["revision"]) == (4, 10, 2)
    assert item["updated_at"] is not None and item["note"] == "Go slowly."
    # The other exercise in the plan is untouched.
    other = response.json()["items"][1]
    assert (other["sets"], other["reps"], other["revision"], other["updated_at"]) == (2, 10, 1, None)

    edit = case.history().json()[0]
    assert edit["item_id"] == case.item["id"] and edit["exercise_name"] == "Squats"
    assert edit["edited_by"] == {"id": str(case.physio.id), "full_name": "Sarah Malik"}
    assert edit["revision"] == 2
    assert edit["changes"] == [
        {"field": "sets", "before": 3, "after": 4},
        {"field": "reps", "before": 12, "after": 10},
    ]
    stored = rows(db, PrescriptionEdit)[0]
    assert stored.edited_at == time.now() and stored.edited_at > assigned_at


def test_the_patient_sees_the_new_prescription_and_is_told_about_it(client, db, case):
    case.edit({"sets": 4, "rest_seconds": 90, "difficulty": "hard", "note": "Add a pause at the bottom."})

    seen = client.get("/api/v1/patient/plan", headers=bearer(sign_in(client, case.patient))).json()

    item = seen["items"][0]
    assert (item["sets"], item["rest_seconds"], item["difficulty"]) == (4, 90, "hard")
    assert item["note"] == "Add a pause at the bottom."
    assert seen["id"] == case.plan["id"]  # the same plan, edited in place
    notice = [n for n in rows(db, Notification) if n.kind == "plan_updated"]
    assert len(notice) == 1 and notice[0].recipient_id == case.patient.id
    assert notice[0].link == "/patient/plan"
    assert notice[0].body == (
        "Sarah Malik changed Squats: sets 3 to 4, rest 60s to 90s, difficulty medium to hard, the note."
    )


def test_history_lists_every_edit_in_the_order_it_was_made(client, case, time):
    case.edit({"sets": 4})
    case.later(time, hours=2)
    case.edit({"reps": 8}, item=case.plan["items"][1]["id"])
    case.later(time, days=1)
    case.edit({"sets": 5, "note": ""})

    history = case.history().json()

    assert [(e["exercise_name"], e["revision"]) for e in history] == [
        ("Squats", 2),
        ("Leg Lunge", 2),
        ("Squats", 3),
    ]
    assert [e["edited_at"] for e in history] == sorted(e["edited_at"] for e in history)
    assert len({e["edited_at"] for e in history}) == 3
    # Each entry holds what the value was before that edit, so nothing is lost.
    assert history[0]["changes"] == [{"field": "sets", "before": 3, "after": 4}]
    assert history[2]["changes"] == [
        {"field": "sets", "before": 4, "after": 5},
        {"field": "note", "before": "Go slowly.", "after": None},
    ]


def test_saving_the_same_values_is_not_an_edit(client, db, case):
    response = case.edit({"sets": 3, "reps": 12, "difficulty": "medium", "note": "  Go slowly. "})

    assert response.status_code == 200
    assert response.json()["items"][0]["revision"] == 1
    assert case.history().json() == []
    assert [n.kind for n in rows(db, Notification)] == ["plan_assigned"]
    assert [a for a in rows(db, AuditLog) if a.action == "plan.prescription_edited"] == []


def test_only_the_fields_that_are_sent_change(client, case):
    item = case.edit({"reps": 15}).json()["items"][0]

    assert (item["sets"], item["reps"], item["rest_seconds"], item["difficulty"], item["note"]) == (
        3,
        15,
        60,
        "medium",
        "Go slowly.",
    )


@pytest.mark.parametrize(
    "body",
    [
        {"sets": 0},
        {"sets": 11},
        {"reps": 0},
        {"reps": 51},
        {"rest_seconds": -1},
        {"rest_seconds": 601},
        {"difficulty": "extreme"},
        {"sets": None},
        {"difficulty": None},
        {"sets": "many"},
        {"note": "x" * 201},
    ],
)
def test_an_edit_outside_the_allowed_range_is_refused(client, db, case, body):
    response = case.edit(body)

    assert response.status_code == 422
    assert rows(db, PrescriptionEdit) == []
    item = rows(db, PlanExercise)
    assert {(i.sets, i.reps, i.revision) for i in item} == {(3, 12, 1), (2, 10, 1)}


def test_edit_is_audited_without_the_text_of_the_note(client, db, case):
    case.edit({"sets": 4, "note": "Private remark about the knee."})

    entry = next(a for a in rows(db, AuditLog) if a.action == "plan.prescription_edited")

    assert entry.actor_id == case.physio.id and entry.target_id == case.item["id"]
    assert entry.detail == {
        "patient_id": str(case.patient.id),
        "plan_id": case.plan["id"],
        "revision": 2,
        "changes": {"sets": {"from": 3, "to": 4}, "note": {"changed": True}},
    }
    assert "Private remark" not in str(entry.detail) and "Go slowly" not in str(entry.detail)
    # The physiotherapist's own history view does keep both versions of the note.
    assert case.history().json()[0]["changes"][1] == {
        "field": "note",
        "before": "Go slowly.",
        "after": "Private remark about the knee.",
    }


def test_an_archived_plan_cannot_be_edited_but_keeps_its_history(client, db, case):
    case.edit({"sets": 4})
    week_one = case.plan
    case.plan = case.assign("Week 2")  # archives Week 1

    refused = case.edit({"sets": 6}, plan=week_one["id"], item=week_one["items"][0]["id"])

    assert refused.status_code == 409 and refused.json()["detail"]["code"] == "plan_archived"
    archived = db.get(ExercisePlan, uuid.UUID(week_one["id"]))
    assert archived.archived_at is not None
    old_history = case.history(plan=week_one["id"]).json()
    assert [e["changes"] for e in old_history] == [[{"field": "sets", "before": 3, "after": 4}]]
    # The new plan starts with a clean history of its own.
    assert case.history().json() == []
    plans = client.get(f"/api/v1/physio/patients/{case.patient.id}/plans", headers=case.headers).json()
    assert [(p["name"], p["items"][0]["sets"]) for p in plans] == [("Week 2", 3), ("Week 1", 4)]


def test_editing_never_creates_or_archives_a_plan(client, db, case):
    case.edit({"sets": 4})
    case.edit({"reps": 9})

    plans = rows(db, ExercisePlan)

    assert len(plans) == 1 and plans[0].archived_at is None


def test_only_the_patients_own_physiotherapist_can_edit_or_read_the_history(client, make, case):
    stranger = bearer(sign_in(client, make.account(Role.physiotherapist)))
    case.edit({"sets": 4})

    edit = client.patch(case.url(), json={"sets": 9}, headers=stranger)
    history = case.history(headers=stranger)
    missing = client.patch(case.url(patient=NOBODY), json={"sets": 9}, headers=stranger)

    # The same answer as for a patient who does not exist at all.
    assert edit.status_code == history.status_code == 404
    assert edit.json() == missing.json()
    assert case.history().json()[0]["changes"] == [{"field": "sets", "before": 3, "after": 4}]


@pytest.mark.parametrize("role", [Role.patient, Role.admin])
def test_patients_and_admins_cannot_edit_a_prescription(client, make, case, role):
    account = case.patient if role == Role.patient else make.account(Role.admin)
    headers = bearer(sign_in(client, account))

    assert client.patch(case.url(), json={"sets": 9}, headers=headers).status_code == 403
    assert case.history(headers=headers).status_code == 403


def test_an_exercise_must_belong_to_the_plan_being_edited(client, case):
    week_one_item = case.item["id"]
    case.plan = case.assign("Week 2")

    wrong_plan = case.edit({"sets": 5}, item=week_one_item)  # Week 1's item under Week 2's address
    unknown_item = case.edit({"sets": 5}, item=NOBODY)
    unknown_plan = case.edit({"sets": 5}, plan=NOBODY)

    for response in (wrong_plan, unknown_item, unknown_plan):
        assert response.status_code == 404
    assert case.history(plan=NOBODY).status_code == 404


def test_a_deactivated_patients_plan_cannot_be_edited(client, db, make, case):
    admin = bearer(sign_in(client, make.account(Role.admin)))
    client.post(f"/api/v1/admin/users/{case.patient.id}/deactivate", headers=admin)

    response = case.edit({"sets": 5})

    assert response.status_code == 409 and response.json()["detail"]["code"] == "patient_inactive"
    assert rows(db, PrescriptionEdit) == []


def test_a_new_physiotherapist_takes_over_editing_and_sees_the_earlier_history(client, make, case):
    case.edit({"sets": 4})
    omar = make.account(Role.physiotherapist, full_name="Omar Farooq")
    admin = bearer(sign_in(client, make.account(Role.admin)))
    client.post(
        f"/api/v1/admin/users/{case.patient.id}/reassign",
        json={"physiotherapist_id": str(omar.id)},
        headers=admin,
    )
    omars = bearer(sign_in(client, omar))

    assert case.edit({"sets": 9}).status_code == 404  # Sarah no longer has access
    edited = client.patch(case.url(), json={"sets": 5}, headers=omars)

    assert edited.status_code == 200
    history = case.history(headers=omars).json()
    assert [(e["edited_by"]["full_name"], e["changes"][0]["after"]) for e in history] == [
        ("Sarah Malik", 4),
        ("Omar Farooq", 5),
    ]
