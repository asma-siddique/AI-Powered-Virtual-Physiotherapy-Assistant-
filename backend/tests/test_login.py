"""US 1.2 - Secure sign-in and session management."""

from sqlalchemy import select

from app.models import AuditLog, AuthSession, Role
from tests.conftest import PASSWORD, bearer, sign_in

LOGIN = "/api/v1/auth/login"
REFRESH = "/api/v1/auth/refresh"
ME = "/api/v1/auth/me"


def attempt(client, identifier, password="wrong-password-1", **extra):
    return client.post(LOGIN, json={"identifier": identifier, "password": password, **extra})


def test_correct_credentials_issue_tokens_and_the_role(client, make):
    physio = make.account(Role.physiotherapist)

    body = sign_in(client, physio)

    assert body["account"]["role"] == "physiotherapist"
    assert body["tokens"]["token_type"] == "bearer"
    assert body["tokens"]["access_token"] and body["tokens"]["refresh_token"]
    assert body["tokens"]["expires_in"] == 15 * 60


def test_wrong_password_and_unknown_identifier_look_identical(client, make):
    account = make.account(Role.patient)

    wrong_password = attempt(client, account.email)
    unknown = attempt(client, "nobody@example.test")

    assert wrong_password.status_code == unknown.status_code == 401
    assert wrong_password.json() == unknown.json()
    assert wrong_password.json()["detail"]["code"] == "invalid_credentials"


def test_choosing_the_wrong_role_fails_like_a_wrong_password(client, make):
    patient = make.account(Role.patient)

    mismatch = attempt(client, patient.email, PASSWORD, role="admin")

    assert mismatch.status_code == 401
    assert mismatch.json() == attempt(client, patient.email).json()
    assert sign_in(client, patient, role="patient")["account"]["role"] == "patient"


def test_deactivated_account_cannot_sign_in(client, make):
    account = make.account(Role.patient, active=False)

    response = attempt(client, account.email, PASSWORD)

    assert response.status_code == 401
    assert response.json()["detail"]["code"] == "invalid_credentials"


def test_account_locks_after_five_failures_and_rejects_the_right_password(client, db, make):
    account = make.account(Role.patient)

    for _ in range(4):
        assert attempt(client, account.email).status_code == 401
    fifth = attempt(client, account.email)

    assert fifth.status_code == 423
    assert fifth.json()["detail"]["code"] == "account_locked"
    assert int(fifth.headers["Retry-After"]) > 0
    correct = attempt(client, account.email, PASSWORD)
    assert correct.status_code == 423

    entry = db.execute(select(AuditLog).where(AuditLog.action == "auth.lockout")).scalar_one()
    assert entry.target_id == str(account.id)


def test_lockout_follows_the_account_not_the_ip_address(client, make):
    account = make.account(Role.patient)

    for i in range(5):
        client.post(
            LOGIN,
            json={"identifier": account.email, "password": "wrong-password-1"},
            headers={"X-Forwarded-For": f"203.0.113.{i}"},
        )

    assert attempt(client, account.email, PASSWORD).status_code == 423


def test_lockout_looks_the_same_for_an_identifier_with_no_account(client):
    for _ in range(4):
        assert attempt(client, "ghost@example.test").status_code == 401

    assert attempt(client, "ghost@example.test").status_code == 423


def test_lock_lifts_after_the_lockout_period(client, make, time):
    account = make.account(Role.patient)
    for _ in range(5):
        attempt(client, account.email)

    time.advance(minutes=14)
    assert attempt(client, account.email, PASSWORD).status_code == 423
    time.advance(minutes=1, seconds=1)
    assert attempt(client, account.email, PASSWORD).status_code == 200


def test_failures_spread_over_more_than_the_window_do_not_lock(client, make, time):
    account = make.account(Role.patient)

    for _ in range(5):
        assert attempt(client, account.email).status_code == 401
        time.advance(minutes=4)

    assert attempt(client, account.email, PASSWORD).status_code == 200


def test_successful_sign_in_resets_the_failure_count(client, make):
    account = make.account(Role.patient)
    for _ in range(4):
        attempt(client, account.email)
    sign_in(client, account)

    for _ in range(4):
        assert attempt(client, account.email).status_code == 401
    assert attempt(client, account.email, PASSWORD).status_code == 200


def test_access_token_expires(client, make, time):
    tokens = sign_in(client, make.account(Role.patient))

    time.advance(minutes=15, seconds=1)
    response = client.get(ME, headers=bearer(tokens))

    assert response.status_code == 401
    assert response.json()["detail"]["code"] == "token_expired"


def test_refresh_rotates_the_refresh_token(client, make, time):
    tokens = sign_in(client, make.account(Role.patient))["tokens"]
    time.advance(minutes=16)

    refreshed = client.post(REFRESH, json={"refresh_token": tokens["refresh_token"]})

    assert refreshed.status_code == 200, refreshed.text
    new = refreshed.json()
    assert new["refresh_token"] != tokens["refresh_token"]
    assert client.get(ME, headers={"Authorization": f"Bearer {new['access_token']}"}).status_code == 200


def test_replaying_a_used_refresh_token_ends_the_session(client, db, make):
    tokens = sign_in(client, make.account(Role.patient))["tokens"]
    new = client.post(REFRESH, json={"refresh_token": tokens["refresh_token"]}).json()

    replay = client.post(REFRESH, json={"refresh_token": tokens["refresh_token"]})

    assert replay.status_code == 401
    assert db.execute(select(AuthSession)).scalar_one().revoked_at is not None
    # The legitimate holder of the new token is signed out too: the session is burned.
    assert client.post(REFRESH, json={"refresh_token": new["refresh_token"]}).status_code == 401
    assert client.get(ME, headers={"Authorization": f"Bearer {new['access_token']}"}).status_code == 401


def test_session_idle_for_thirty_minutes_needs_a_new_sign_in(client, make, time):
    body = sign_in(client, make.account(Role.patient))

    time.advance(minutes=30, seconds=1)

    refresh = client.post(REFRESH, json={"refresh_token": body["tokens"]["refresh_token"]})
    assert refresh.status_code == 401
    assert refresh.json()["detail"]["code"] == "session_expired"


def test_activity_keeps_a_session_alive_past_thirty_minutes(client, make, time):
    tokens = sign_in(client, make.account(Role.patient))["tokens"]

    for _ in range(4):  # 4 x 10 minutes = 40 minutes, never idle for 30
        time.advance(minutes=10)
        refreshed = client.post(REFRESH, json={"refresh_token": tokens["refresh_token"]})
        assert refreshed.status_code == 200, refreshed.text
        tokens = refreshed.json()

    assert client.get(ME, headers={"Authorization": f"Bearer {tokens['access_token']}"}).status_code == 200


def test_logout_revokes_the_session(client, make):
    body = sign_in(client, make.account(Role.patient))

    assert client.post("/api/v1/auth/logout", headers=bearer(body)).status_code == 204

    assert client.get(ME, headers=bearer(body)).status_code == 401
    refresh = client.post(REFRESH, json={"refresh_token": body["tokens"]["refresh_token"]})
    assert refresh.status_code == 401


def test_device_list_shows_sessions_and_each_can_be_revoked(client, make):
    account = make.account(Role.patient)
    phone = sign_in(client, account)
    laptop = sign_in(client, account)

    sessions = client.get("/api/v1/auth/sessions", headers=bearer(laptop)).json()

    assert len(sessions) == 2
    assert sum(s["current"] for s in sessions) == 1
    other = next(s for s in sessions if not s["current"])
    assert client.delete(f"/api/v1/auth/sessions/{other['id']}", headers=bearer(laptop)).status_code == 204
    assert client.get(ME, headers=bearer(phone)).status_code == 401
    assert client.get(ME, headers=bearer(laptop)).status_code == 200


def test_one_account_cannot_revoke_another_accounts_session(client, make):
    victim = sign_in(client, make.account(Role.patient))
    attacker = sign_in(client, make.account(Role.patient))
    victim_session = client.get("/api/v1/auth/sessions", headers=bearer(victim)).json()[0]["id"]

    response = client.delete(f"/api/v1/auth/sessions/{victim_session}", headers=bearer(attacker))

    assert response.status_code == 404
    assert client.get(ME, headers=bearer(victim)).status_code == 200
