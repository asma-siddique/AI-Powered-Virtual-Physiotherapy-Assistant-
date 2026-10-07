# PhysioAI

AI-powered virtual physiotherapy assistant. Final Year Project, BS Data Science (2023-2027), FCIT, University of the Punjab.

Patients do the exercises their physiotherapist assigns while the app tracks their movement through the camera and gives severity-tiered feedback. Physiotherapists assign plans and review sessions. Admins manage accounts and the exercise library.

| Part | Stack | Folder |
|---|---|---|
| App (Android, iOS, Web) | Flutter, Riverpod, go_router | `frontend/` |
| API | FastAPI, SQLAlchemy, Alembic | `backend/` |
| Database | PostgreSQL (Supabase when hosted) | `backend/migrations/` |

## What works today

Sprint 1, identity and access (user stories 1.1 to 1.3):

- Patient registration that requires a single-use physiotherapist invite code and links the patient to that physiotherapist.
- Role-based sign-in for patients, physiotherapists and admins, with short-lived access tokens and rotating refresh tokens.
- Sign-in pauses after 5 failed attempts in 15 minutes, per account and regardless of IP address. Sessions end after 30 minutes of inactivity.
- Every endpoint checks the caller's role on the server. A physiotherapist can only see their own patients.
- Audit log entries for registrations, invite codes and lockouts.
- A device list for each account, with per-session sign-out (API only so far).

Not built yet: the advisory and consent step (1.4), exercise plans, live sessions, progress, notifications, and admin user management.

## Run it locally

You need Python 3.11+ and Flutter 3.41+. No Docker or cloud account is needed: with `DATABASE_URL` left empty, the API starts an embedded PostgreSQL whose data lives in `~/.physioai/pgdata`.

### API

```bash
cd backend
python -m venv .venv
.venv/Scripts/activate          # macOS/Linux: source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env
alembic upgrade head            # create the tables
python -m app.seed              # create the demo accounts listed in .env
uvicorn app.main:app --reload --port 8000
```

Interactive API docs: http://localhost:8000/docs

### App

```bash
cd frontend
flutter pub get
flutter run -d chrome
```

The app talks to `http://localhost:8000/api/v1` by default. To point it elsewhere, add `--dart-define=API_BASE_URL=https://your-host/api/v1`.

### Demo accounts

`python -m app.seed` creates one admin, one physiotherapist and one patient. Their emails and passwords are the `SEED_*` values in `backend/.env` (copied from `.env.example`). They are for local development only; the seed refuses to run when `ENVIRONMENT=production`.

To try registration: sign in as the physiotherapist, press **Generate Invite Code**, sign out, then use that code on **Create your account**.

## Tests

```bash
cd backend && pytest                      # API tests, run against a real PostgreSQL
cd backend && ruff check . && ruff format --check .
cd frontend && flutter analyze && flutter test
cd frontend && bash tool/live_api_test.sh # app repositories against the running API
```

`pytest` starts its own temporary embedded PostgreSQL. To use another server instead, set `TEST_DATABASE_URL` to a database whose name contains `test` (the suite drops and recreates its schema).

## Using Supabase

Put the Supabase connection string in `backend/.env` as `DATABASE_URL`, set a `JWT_SECRET` of at least 32 characters, then run `alembic upgrade head`. Authentication is handled by this API (password hashing, tokens, lockout), with its tables stored in the Supabase database; Supabase's own Auth service is not used.

## Conventions

- Branch from `main`, open a pull request, and merge only when CI is green.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), for example `feat(auth): add invite code registration`.
- Database changes go through Alembic: edit `app/models.py`, then `alembic revision --autogenerate -m "what changed"`.
