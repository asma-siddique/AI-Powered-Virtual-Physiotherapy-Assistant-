"""In-app notifications: plan assignment (US 2.1), lockout notice (US 1.2)."""

from sqlalchemy import select

from app.models import Notification, Role
from tests.conftest import PASSWORD, bearer, sign_in

NOTIFICATIONS = "/api/v1/notifications"
MISSING = "00000000-0000-0000-0000-000000000000"


def assign(client, headers, patient, exercise, name="Knee plan"):
    return client.post(
        f"/api/v1/physio/patients/{patient.id}/plans",
        json={"name": name, "items": [{"exercise_id": str(exercise.id), "sets": 3, "reps": 10}]},
        headers=headers,
    )


def test_assigning_a_plan_notifies_the_patient_with_a_link_to_it(client, make):
    physio = make.account(Role.physiotherapist, full_name="Dr. Sarah Malik")
    patient = make.patient_of(physio)
    squats = make.exercise("Squats")

    assert assign(client, bearer(sign_in(client, physio)), patient, squats).status_code == 201

    inbox = client.get(NOTIFICATIONS, headers=bearer(sign_in(client, patient))).json()
    assert inbox["unread_count"] == 1
    notice = inbox["items"][0]
    assert notice["kind"] == "plan_assigned"
    assert notice["title"] == "You have a new exercise plan"
    assert notice["body"] == 'Dr. Sarah Malik assigned you "Knee plan" with 1 exercise.'
    assert notice["link"] == "/patient/plan"
    assert notice["read_at"] is None


def test_a_replacement_plan_is_announced_as_an_update(client, make):
    physio = make.account(Role.physiotherapist)
    patient = make.patient_of(physio)
    squats = make.exercise("Squats")
    headers = bearer(sign_in(client, physio))

    assign(client, headers, patient, squats, "Week 1")
    assign(client, headers, patient, squats, "Week 2")

    titles = [
        n["title"]
        for n in client.get(NOTIFICATIONS, headers=bearer(sign_in(client, patient))).json()["items"]
    ]
    assert sorted(titles) == ["You have a new exercise plan", "Your exercise plan was updated"]


def test_a_refused_plan_sends_nothing(client, db, make):
    physio = make.account(Role.physiotherapist)
    patient = make.patient_of(physio)
    retired = make.exercise("Wall Sit", active=False)

    assert assign(client, bearer(sign_in(client, physio)), patient, retired).status_code == 409

    assert db.execute(select(Notification)).first() is None


def test_notifications_are_private_to_their_recipient(client, make):
    physio = make.account(Role.physiotherapist)
    jane = make.patient_of(physio)
    marcus = make.patient_of(physio)
    assign(client, bearer(sign_in(client, physio)), jane, make.exercise("Squats"))
    jane_headers = bearer(sign_in(client, jane))
    marcus_headers = bearer(sign_in(client, marcus))
    notice_id = client.get(NOTIFICATIONS, headers=jane_headers).json()["items"][0]["id"]

    assert client.get(NOTIFICATIONS, headers=marcus_headers).json() == {"unread_count": 0, "items": []}
    # Marking someone else's notification read is refused like an unknown one.
    theirs = client.post(f"{NOTIFICATIONS}/{notice_id}/read", headers=marcus_headers)
    unknown = client.post(f"{NOTIFICATIONS}/{MISSING}/read", headers=marcus_headers)
    assert theirs.status_code == 404 and theirs.json() == unknown.json()
    assert client.get(NOTIFICATIONS, headers=jane_headers).json()["unread_count"] == 1


def test_reading_one_and_reading_all(client, make, time):
    physio = make.account(Role.physiotherapist)
    patient = make.patient_of(physio)
    squats = make.exercise("Squats")
    physio_headers = bearer(sign_in(client, physio))
    for name in ("Week 1", "Week 2", "Week 3"):
        assign(client, physio_headers, patient, squats, name)
        time.advance(minutes=1)
    headers = bearer(sign_in(client, patient))
    inbox = client.get(NOTIFICATIONS, headers=headers).json()
    assert inbox["unread_count"] == 3
    assert "Week 3" in inbox["items"][0]["body"]  # newest first

    assert client.post(f"{NOTIFICATIONS}/{inbox['items'][0]['id']}/read", headers=headers).status_code == 204
    after_one = client.get(NOTIFICATIONS, headers=headers).json()
    assert after_one["unread_count"] == 2
    assert after_one["items"][0]["read_at"] == time.now().isoformat().replace("+00:00", "Z")

    assert client.post(f"{NOTIFICATIONS}/read-all", headers=headers).status_code == 204
    after_all = client.get(NOTIFICATIONS, headers=headers).json()
    assert after_all["unread_count"] == 0
    assert all(n["read_at"] for n in after_all["items"])


def test_limit_caps_the_list_but_not_the_unread_count(client, make, time):
    physio = make.account(Role.physiotherapist)
    patient = make.patient_of(physio)
    squats = make.exercise("Squats")
    physio_headers = bearer(sign_in(client, physio))
    for _ in range(3):
        assign(client, physio_headers, patient, squats)
        time.advance(minutes=1)

    inbox = client.get(f"{NOTIFICATIONS}?limit=2", headers=bearer(sign_in(client, patient))).json()

    assert len(inbox["items"]) == 2 and inbox["unread_count"] == 3


def test_account_holder_finds_a_notice_after_their_sign_in_was_paused(client, make, time):
    account = make.account(Role.patient)
    for _ in range(5):
        client.post("/api/v1/auth/login", json={"identifier": account.email, "password": "wrong-pass-1"})
    time.advance(minutes=16)

    inbox = client.get(NOTIFICATIONS, headers=bearer(sign_in(client, account, PASSWORD))).json()

    assert inbox["unread_count"] == 1
    notice = inbox["items"][0]
    assert notice["kind"] == "security_lockout"
    assert notice["title"] == "Sign-in to your account was paused"
    assert "15 minutes" in notice["body"] and "5 unsuccessful attempts" in notice["body"]


def test_no_notice_is_created_for_an_identifier_with_no_account(client, db):
    for _ in range(5):
        client.post(
            "/api/v1/auth/login", json={"identifier": "ghost@example.test", "password": "wrong-pass-1"}
        )

    assert db.execute(select(Notification)).first() is None
