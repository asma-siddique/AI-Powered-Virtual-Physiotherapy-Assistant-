"""US 1.2 - the account's own device list, and changing a password."""

import pytest
from sqlalchemy import select

from app import devices
from app.models import Account, AuditLog, Notification, Role
from tests.conftest import PASSWORD, bearer, sign_in

CHROME_WINDOWS = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/141.0.0.0 Safari/537.36"
)
SAFARI_IPHONE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)


def sign_in_from(client, account, user_agent: str, password: str = PASSWORD) -> dict:
    response = client.post(
        "/api/v1/auth/login",
        json={"identifier": account.email, "password": password},
        headers={"User-Agent": user_agent},
    )
    assert response.status_code == 200, response.text
    return response.json()


def change_password(client, tokens: dict, current: str, new: str):
    return client.post(
        "/api/v1/auth/change-password",
        json={"current_password": current, "new_password": new},
        headers=bearer(tokens),
    )


@pytest.mark.parametrize(
    ("user_agent", "expected"),
    [
        (CHROME_WINDOWS, "Chrome on Windows"),
        (SAFARI_IPHONE, "Safari on iPhone"),
        (CHROME_WINDOWS + " Edg/141.0.0.0", "Edge on Windows"),
        (
            "Mozilla/5.0 (Linux; Android 15; Pixel 9) AppleWebKit/537.36 (KHTML, like Gecko) "
            "Chrome/141.0.0.0 Mobile Safari/537.36",
            "Chrome on Android",
        ),
        ("Mozilla/5.0 (X11; Linux x86_64; rv:143.0) Gecko/20100101 Firefox/143.0", "Firefox on Linux"),
        (
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
            "Version/18.0 Safari/605.1.15",
            "Safari on Mac",
        ),
        ("Dart/3.9 (dart:io)", "PhysioAI app"),
        ("curl/8.9.1", "Unknown device"),
        (None, "Unknown device"),
    ],
)
def test_a_device_is_described_in_words_people_recognise(user_agent, expected):
    assert devices.describe(user_agent) == expected


def test_device_list_shows_every_signed_in_device_and_marks_this_one(client, make):
    account = make.account(Role.patient)
    laptop = sign_in_from(client, account, CHROME_WINDOWS)
    sign_in_from(client, account, SAFARI_IPHONE)

    listed = client.get("/api/v1/auth/sessions", headers=bearer(laptop)).json()

    assert {(d["device"], d["current"]) for d in listed} == {
        ("Chrome on Windows", True),
        ("Safari on iPhone", False),
    }
    assert all({"id", "created_at", "last_seen_at", "ip"} <= d.keys() for d in listed)
    assert "user_agent" not in listed[0] and "refresh_token" not in str(listed)


def test_signing_one_device_out_ends_only_that_session(client, db, make):
    account = make.account(Role.patient)
    laptop = sign_in_from(client, account, CHROME_WINDOWS)
    phone = sign_in_from(client, account, SAFARI_IPHONE)
    devices_listed = client.get("/api/v1/auth/sessions", headers=bearer(laptop)).json()
    phone_id = next(d["id"] for d in devices_listed if not d["current"])

    response = client.delete(f"/api/v1/auth/sessions/{phone_id}", headers=bearer(laptop))

    assert response.status_code == 204
    assert client.get("/api/v1/auth/me", headers=bearer(phone)).status_code == 401
    assert client.get("/api/v1/auth/me", headers=bearer(laptop)).status_code == 200
    # Its refresh token is dead too, so the phone cannot quietly sign itself back in.
    refreshed = client.post("/api/v1/auth/refresh", json={"refresh_token": phone["tokens"]["refresh_token"]})
    assert refreshed.status_code == 401
    entry = db.execute(select(AuditLog).where(AuditLog.action == "auth.session_revoked")).scalar_one()
    assert entry.actor_id == account.id and entry.detail == {"device": "Safari on iPhone"}
    again = client.delete(f"/api/v1/auth/sessions/{phone_id}", headers=bearer(laptop))
    assert again.status_code == 404


def test_nobody_can_see_or_sign_out_another_accounts_devices(client, make):
    jane = make.account(Role.patient)
    omar = make.account(Role.patient)
    janes = sign_in_from(client, jane, CHROME_WINDOWS)
    omars = sign_in_from(client, omar, SAFARI_IPHONE)
    janes_device = client.get("/api/v1/auth/sessions", headers=bearer(janes)).json()[0]["id"]

    listed = client.get("/api/v1/auth/sessions", headers=bearer(omars)).json()
    revoked = client.delete(f"/api/v1/auth/sessions/{janes_device}", headers=bearer(omars))

    assert [d["device"] for d in listed] == ["Safari on iPhone"]
    assert revoked.status_code == 404
    assert client.get("/api/v1/auth/me", headers=bearer(janes)).status_code == 200


def test_sign_out_everywhere_else_keeps_only_this_device(client, db, make):
    account = make.account(Role.physiotherapist)
    laptop = sign_in_from(client, account, CHROME_WINDOWS)
    phone = sign_in_from(client, account, SAFARI_IPHONE)
    tablet = sign_in_from(client, account, SAFARI_IPHONE)

    response = client.post("/api/v1/auth/sessions/revoke-others", headers=bearer(laptop))

    assert response.status_code == 200 and response.json() == {"signed_out": 2}
    assert client.get("/api/v1/auth/me", headers=bearer(laptop)).status_code == 200
    for other in (phone, tablet):
        assert client.get("/api/v1/auth/me", headers=bearer(other)).status_code == 401
    remaining = client.get("/api/v1/auth/sessions", headers=bearer(laptop)).json()
    assert [d["current"] for d in remaining] == [True]
    entry = db.execute(select(AuditLog).where(AuditLog.action == "auth.session_revoked")).scalar_one()
    assert entry.detail == {"devices": 2}
    # Nothing left to sign out: no second audit entry for doing nothing.
    assert client.post("/api/v1/auth/sessions/revoke-others", headers=bearer(laptop)).json() == {
        "signed_out": 0
    }
    assert len(db.execute(select(AuditLog).where(AuditLog.action == "auth.session_revoked")).all()) == 1


def test_expired_sessions_are_not_listed_as_devices(client, make, time):
    account = make.account(Role.patient)
    sign_in_from(client, account, SAFARI_IPHONE)
    time.advance(minutes=31)  # the phone goes idle past the 30-minute limit
    laptop = sign_in_from(client, account, CHROME_WINDOWS)

    listed = client.get("/api/v1/auth/sessions", headers=bearer(laptop)).json()

    assert [d["device"] for d in listed] == ["Chrome on Windows"]


def test_changing_the_password_signs_out_other_devices_and_is_recorded(client, db, make):
    account = make.account(Role.patient)
    laptop = sign_in_from(client, account, CHROME_WINDOWS)
    phone = sign_in_from(client, account, SAFARI_IPHONE)

    response = change_password(client, laptop, PASSWORD, "Brand-New-2026")

    assert response.status_code == 200, response.text
    assert response.json()["password_change_required"] is False
    assert "Brand-New-2026" not in response.text
    # This device stays signed in; the other one does not.
    assert client.get("/api/v1/auth/me", headers=bearer(laptop)).status_code == 200
    assert client.get("/api/v1/auth/me", headers=bearer(phone)).status_code == 401
    # Only the new password signs in.
    old = client.post("/api/v1/auth/login", json={"identifier": account.email, "password": PASSWORD})
    assert old.status_code == 401
    sign_in(client, account, "Brand-New-2026")
    entry = db.execute(select(AuditLog).where(AuditLog.action == "account.password_changed")).scalar_one()
    assert entry.actor_id == account.id
    assert entry.detail == {"other_devices_signed_out": 1, "replaced_temporary_password": False}
    assert "Brand-New-2026" not in str(entry.detail)
    notice = db.execute(select(Notification).where(Notification.recipient_id == account.id)).scalar_one()
    assert notice.kind == "security_password_changed" and notice.link == "/patient/security"


def test_password_change_needs_the_current_password(client, db, make):
    account = make.account(Role.patient)
    tokens = sign_in(client, account)

    response = change_password(client, tokens, "not-my-password-1", "Brand-New-2026")

    assert response.status_code == 400
    assert response.json()["detail"]["code"] == "current_password_incorrect"
    sign_in(client, account)  # the old password still works
    assert db.execute(select(AuditLog).where(AuditLog.action == "account.password_changed")).first() is None


@pytest.mark.parametrize(
    ("new_password", "status", "code"),
    [
        (PASSWORD, 400, "password_unchanged"),
        ("short1", 422, None),
        ("no-digits-here", 422, None),
        ("1234567890", 422, None),
    ],
)
def test_new_password_must_be_different_and_meet_the_policy(client, make, new_password, status, code):
    account = make.account(Role.patient)
    tokens = sign_in(client, account)

    response = change_password(client, tokens, PASSWORD, new_password)

    assert response.status_code == status
    if code:
        assert response.json()["detail"]["code"] == code
    sign_in(client, account)


def test_guessing_the_current_password_is_cut_off_like_failed_sign_ins(client, db, make):
    account = make.account(Role.patient)
    tokens = sign_in(client, account)

    codes = [
        change_password(client, tokens, f"guess-number-{n}", "Brand-New-2026").json()["detail"]["code"]
        for n in range(5)
    ]
    even_the_right_one = change_password(client, tokens, PASSWORD, "Brand-New-2026")

    assert codes == ["current_password_incorrect"] * 4 + ["account_locked"]
    assert even_the_right_one.status_code == 423
    assert db.get(Account, account.id).must_change_password is False
    sign_in_blocked = client.post(
        "/api/v1/auth/login", json={"identifier": account.email, "password": PASSWORD}
    )
    assert sign_in_blocked.status_code == 423


def test_change_password_requires_a_signed_in_account(client):
    response = client.post(
        "/api/v1/auth/change-password",
        json={"current_password": PASSWORD, "new_password": "Brand-New-2026"},
    )
    assert response.status_code == 401


def test_lockout_notice_leads_to_the_account_security_page(client, db, make):
    account = make.account(Role.physiotherapist)
    for _ in range(5):
        client.post("/api/v1/auth/login", json={"identifier": account.email, "password": "wrong-pass-1"})

    notice = db.execute(select(Notification).where(Notification.recipient_id == account.id)).scalar_one()

    assert notice.kind == "security_lockout" and notice.link == "/physio/security"
