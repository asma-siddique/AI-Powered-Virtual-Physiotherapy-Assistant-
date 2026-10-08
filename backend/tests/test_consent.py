"""US 1.4 - Advisory disclaimer and consent capture."""

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app import disclaimer
from app.deps import ConsentedPatient
from app.models import AuditLog, ConsentRecord, Role
from tests.conftest import bearer, sign_in

CONSENT = "/api/v1/patient/consent"
ME = "/api/v1/auth/me"


def acknowledge(client, headers, **overrides):
    body = {"version": disclaimer.CURRENT_VERSION, "acknowledged": True, **overrides}
    return client.post(CONSENT, json=body, headers=headers)


def consent_count(db) -> int:
    return db.execute(select(func.count()).select_from(ConsentRecord)).scalar()


@pytest.fixture
def patient_headers(client, make):
    physio = make.account(Role.physiotherapist)
    return bearer(sign_in(client, make.patient_of(physio)))


def test_new_patient_has_not_acknowledged_and_gets_the_advisory_text(client, patient_headers):
    response = client.get(CONSENT, headers=patient_headers)

    assert response.status_code == 200
    body = response.json()
    assert body["acknowledged"] is False and body["acknowledged_at"] is None
    text = body["disclaimer"]
    assert text["version"] == disclaimer.CURRENT_VERSION
    assert text["title"] == "Before your first session"
    assert len(text["points"]) == 3
    assert "does not diagnose" in " ".join(p["body"] for p in text["points"])
    assert "does not replace professional medical advice" in text["acknowledgment"]


def test_sign_in_tells_the_app_whether_the_advisory_is_still_needed(client, make):
    physio = make.account(Role.physiotherapist)
    patient = make.patient_of(physio)

    patient_session = sign_in(client, patient)
    assert patient_session["advisory_acknowledged"] is False
    assert acknowledge(client, bearer(patient_session)).status_code == 201

    assert sign_in(client, patient)["advisory_acknowledged"] is True
    assert client.get(ME, headers=bearer(patient_session)).json()["advisory_acknowledged"] is True
    # The question only applies to patients.
    assert sign_in(client, physio)["advisory_acknowledged"] is None
    assert sign_in(client, make.account(Role.admin))["advisory_acknowledged"] is None


def test_registration_starts_without_consent(client, make):
    make.invite(make.account(Role.physiotherapist))

    registered = client.post(
        "/api/v1/auth/register",
        json={
            "full_name": "Jane Cooper",
            "identifier": "jane@example.test",
            "password": "Recover-2026",
            "invite_code": "PHY-TEST-CODE",
        },
    )

    assert registered.status_code == 201
    assert registered.json()["advisory_acknowledged"] is False


def test_acknowledging_stores_a_server_side_timestamp_and_an_audit_entry(client, db, patient_headers, time):
    response = acknowledge(client, patient_headers)

    assert response.status_code == 201, response.text
    assert response.json()["acknowledged"] is True
    record = db.execute(select(ConsentRecord)).scalar_one()
    assert record.acknowledged_at == time.now()
    assert record.disclaimer_version == disclaimer.CURRENT_VERSION
    entry = db.execute(select(AuditLog).where(AuditLog.action == "consent.acknowledged")).scalar_one()
    assert entry.actor_id == record.account_id
    assert entry.detail == {"disclaimer_version": disclaimer.CURRENT_VERSION}


@pytest.mark.parametrize(
    "body",
    [
        {"version": disclaimer.CURRENT_VERSION},
        {"version": disclaimer.CURRENT_VERSION, "acknowledged": False},
        {"version": disclaimer.CURRENT_VERSION, "acknowledged": None},
        {"acknowledged": True},
        {},
    ],
)
def test_consent_is_never_assumed(client, db, patient_headers, body):
    response = client.post(CONSENT, json=body, headers=patient_headers)

    assert response.status_code == 422
    assert consent_count(db) == 0
    assert client.get(CONSENT, headers=patient_headers).json()["acknowledged"] is False


def test_acknowledging_wording_the_patient_did_not_see_is_refused(client, db, patient_headers):
    response = acknowledge(client, patient_headers, version="2020-01")

    assert response.status_code == 409
    assert response.json()["detail"]["code"] == "disclaimer_outdated"
    assert consent_count(db) == 0


def test_acknowledging_twice_keeps_the_original_timestamp(client, db, make, time):
    patient = make.patient_of(make.account(Role.physiotherapist))
    first = acknowledge(client, bearer(sign_in(client, patient)))
    time.advance(days=3)

    second = acknowledge(client, bearer(sign_in(client, patient)))

    assert second.status_code == 200
    assert second.json()["acknowledged_at"] == first.json()["acknowledged_at"]
    assert consent_count(db) == 1
    acknowledged = select(func.count()).select_from(AuditLog).where(AuditLog.action == "consent.acknowledged")
    assert db.execute(acknowledged).scalar() == 1


def test_new_wording_must_be_acknowledged_again_and_the_old_record_is_kept(
    client, db, patient_headers, monkeypatch
):
    acknowledge(client, patient_headers)
    monkeypatch.setattr(disclaimer, "CURRENT_VERSION", "2027-01")

    status = client.get(CONSENT, headers=patient_headers).json()
    assert status["acknowledged"] is False
    assert status["disclaimer"]["version"] == "2027-01"
    assert client.get(ME, headers=patient_headers).json()["advisory_acknowledged"] is False

    assert acknowledge(client, patient_headers).status_code == 201
    versions = db.execute(select(ConsentRecord.disclaimer_version)).scalars().all()
    assert sorted(versions) == ["2026-10", "2027-01"]


def test_one_patients_consent_does_not_cover_another(client, make):
    physio = make.account(Role.physiotherapist)
    first = bearer(sign_in(client, make.patient_of(physio)))
    second = bearer(sign_in(client, make.patient_of(physio)))

    acknowledge(client, first)

    assert client.get(CONSENT, headers=second).json()["acknowledged"] is False


def session_app() -> FastAPI:
    """Stands in for the future live-session endpoints, which must all depend on
    ConsentedPatient."""
    app = FastAPI()

    @app.post("/session")
    def start_session(patient: ConsentedPatient) -> dict[str, str]:
        return {"patient": str(patient.id)}

    return app


def test_session_endpoints_refuse_a_patient_without_consent(client, make, patient_headers):
    sessions = TestClient(session_app())

    before = sessions.post("/session", headers=patient_headers)
    assert before.status_code == 403
    assert before.json()["detail"]["code"] == "consent_required"

    acknowledge(client, patient_headers)

    assert sessions.post("/session", headers=patient_headers).status_code == 200
    # Other roles are refused for their role, whatever their consent state.
    physio_headers = bearer(sign_in(client, make.account(Role.physiotherapist)))
    assert sessions.post("/session", headers=physio_headers).json()["detail"]["code"] == "forbidden"
    assert sessions.post("/session").status_code == 401


def test_admin_can_retrieve_consent_records_for_audit(client, make, time):
    physio = make.account(Role.physiotherapist)
    jane = make.patient_of(physio)
    acknowledge(client, bearer(sign_in(client, jane)))
    time.advance(hours=1)
    marcus = make.patient_of(physio)
    acknowledge(client, bearer(sign_in(client, marcus)))
    admin = bearer(sign_in(client, make.account(Role.admin)))

    everyone = client.get("/api/v1/admin/consents", headers=admin).json()
    only_jane = client.get(f"/api/v1/admin/consents?account_id={jane.id}", headers=admin).json()

    assert [c["account"]["id"] for c in everyone] == [str(marcus.id), str(jane.id)]
    assert everyone[0]["disclaimer_version"] == disclaimer.CURRENT_VERSION
    assert everyone[0]["acknowledged_at"] > everyone[1]["acknowledged_at"]
    assert [c["account"]["id"] for c in only_jane] == [str(jane.id)]
