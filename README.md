# PhysioAI

AI-powered virtual physiotherapy assistant. Final Year Project, BS Data Science (2023-2027), FCIT, University of the Punjab.

Patients do the exercises their physiotherapist assigns while the app tracks their movement through the camera and gives severity-tiered feedback. Physiotherapists assign plans and review sessions. Admins manage accounts and the exercise library.

| Part | Stack | Folder |
|---|---|---|
| App (Android, iOS, Web) | Flutter, Riverpod, go_router | `frontend/` |
| API | FastAPI, SQLAlchemy, Alembic | `backend/` |
| Database | PostgreSQL (Supabase when hosted) | `backend/migrations/` |

## What works today

Identity and access (user stories 1.1 to 1.4):

- Patient registration that requires a single-use physiotherapist invite code and links the patient to that physiotherapist.
- Two-step sign-in: choose a role, then sign in. Patients can also create an account from there. Access tokens are short-lived and refresh tokens rotate.
- Sign-in pauses after 5 failed attempts in 15 minutes, per account and regardless of IP address. Sessions end after 30 minutes of inactivity.
- Every endpoint checks the caller's role on the server. A physiotherapist can only see their own patients.
- A mandatory advisory for patients: until they tick the acknowledgment and continue, nothing else in the app opens. The acknowledgment is stored on the server with its timestamp and the version of the wording, and the same text can be re-read under Help.
- Audit log entries for registrations, invite codes, lockouts and advisory acknowledgments.
- A device list for each account, with per-session sign-out (API only so far).

The advisory wording lives in `backend/app/disclaimer.py`. Changing it means bumping `CURRENT_VERSION` there, after which every patient is asked to acknowledge the new wording. Endpoints that start or record a live session must depend on `ConsentedPatient` (`backend/app/deps.py`), which refuses patients who have not acknowledged it.

Exercise library and plans (user stories 2.1, 2.3, 7.1 and 7.2):

- The five supported exercises (Arm Abduction, Leg Abduction, Leg Lunge, Push-ups, Squats) are added by a migration, each with its target joints, movement pattern, patient instructions and RED / AMBER / INFO checks.
- Exercise Library for admins (in the admin panel only): see every exercise, switch one on or off (switching off asks first and explains the effect), and edit an exercise's profile and its RED / AMBER / INFO thresholds. Every edit makes a new version and is audited with the values before and after. A new exercise starts switched off, so physiotherapists are never offered one the scoring model cannot handle yet.
- Plan Builder for physiotherapists: choose a patient, pick from the exercises that are switched on, set sets, reps, rest and difficulty, and assign. Assigning a new plan archives the previous one rather than replacing it, and a plan that contains an exercise since switched off is flagged.
- Patients see their plan on Home and in full under My Exercise Plan.

In-app notifications:

- A bell with an unread count for every role. Opening a notification marks it read and goes to the page it is about.
- A patient is notified when a plan is assigned, and the plan on screen refreshes when that arrives. An account is notified when sign-in to it was paused.
- The app checks for new notifications once a minute while it is open. Push notifications (Firebase Cloud Messaging) are not built yet.

The severity thresholds that ship with the five exercises are provisional starting values. They have not yet been derived from the REHAB24-6 labels or reviewed clinically; see the note at the top of `backend/migrations/versions/0003_exercise_templates_and_plans.py`.

Not built yet: editing a prescription with its change history (2.2), a screen for the device list (1.2), admin user management (7.3), live sessions, progress, push notifications, chat and feedback.

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

With the embedded database, the API applies new migrations by itself each time it starts, so after pulling new code you only need to restart it. A shared database (`DATABASE_URL` set) is never migrated automatically; run `alembic upgrade head` for that.

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
cd frontend && bash tool/live_api_test.sh # the app's real repositories against a real API
```

`pytest` starts its own temporary embedded PostgreSQL. To use another server instead, set `TEST_DATABASE_URL` to a database whose name contains `test` (the suite drops and recreates its schema).

`tool/live_api_test.sh` starts a throwaway API with its own empty database (`python -m app.throwaway`), runs the end-to-end test against it and removes everything afterwards, so your development data is never touched. To run it against an API that is already running instead, set `API_BASE_URL`; that leaves a test patient and a test exercise behind.

## Using Supabase

Put the Supabase connection string in `backend/.env` as `DATABASE_URL`, set a `JWT_SECRET` of at least 32 characters, then run `alembic upgrade head`. Authentication is handled by this API (password hashing, tokens, lockout), with its tables stored in the Supabase database; Supabase's own Auth service is not used.

## Conventions

- Branch from `main`, open a pull request, and merge only when CI is green.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), for example `feat(auth): add invite code registration`.
- Database changes go through Alembic: edit `app/models.py`, then `alembic revision --autogenerate -m "what changed"`.
