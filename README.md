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
- Account & Security for every role: the devices the account is signed in on (sign out one, or all others), and changing the password, which signs out every other device. Wrong guesses at the current password count towards the same sign-in pause.

User and role management for admins (user stories 7.3 and 1.3):

- Users & Roles screen: search and filter accounts, add a patient, physiotherapist or admin, correct a name or contact, deactivate and reactivate, reassign a patient to another physiotherapist, change a staff role, and reset a password.
- A new or reset account gets a temporary password that is shown to the admin once. Until its owner replaces it, the server refuses everything except reading their own profile, choosing a password and signing out.
- Deactivating signs the account out everywhere and stops sign-in; nothing it created is removed. A physiotherapist who still has active patients cannot be deactivated or made an admin until those patients are reassigned.
- Reassigning closes the old assignment and opens a new one in the same request, so the previous physiotherapist loses access and the new one gains it at once. The patient's plan carries over, and all three people are notified.
- Roles change only between Physiotherapist and Admin. A patient account never becomes a staff account or the other way round, because it carries a physiotherapist link, consent and clinical records. The person is signed out so the new role applies immediately.
- An admin cannot deactivate, demote or reset their own account, so the system can never be left without an admin.
- Every one of these changes is written to the audit log with who did it and what changed.

There is no email service yet, so a forgotten password is reset by an admin rather than by a self-service link.

The advisory wording lives in `backend/app/disclaimer.py`. Changing it means bumping `CURRENT_VERSION` there, after which every patient is asked to acknowledge the new wording. Endpoints that start or record a live session must depend on `ConsentedPatient` (`backend/app/deps.py`), which refuses patients who have not acknowledged it.

Exercise library and plans (user stories 2.1, 2.3, 7.1 and 7.2):

- The five supported exercises (Arm Abduction, Leg Abduction, Leg Lunge, Push-ups, Squats) are added by a migration, each with its target joints, movement pattern, patient instructions and RED / AMBER / INFO checks.
- Exercise Library for admins (in the admin panel only): see every exercise, switch one on or off (switching off asks first and explains the effect), and edit an exercise's profile and its RED / AMBER / INFO thresholds. Every edit makes a new version and is audited with the values before and after. A new exercise starts switched off, so physiotherapists are never offered one the scoring model cannot handle yet.
- Plan Builder for physiotherapists: choose a patient, pick from the exercises that are switched on, set sets, reps, rest and difficulty, and assign. Assigning a new plan archives the previous one rather than replacing it, and a plan that contains an exercise since switched off is flagged.
- Patients see their plan on Home and in full under My Exercise Plan.
- Prescription editing (2.2): a physiotherapist adjusts the sets, reps, rest, difficulty or note of an exercise in the plan that is in force, without assigning a new plan. Every edit is stored with its time, who made it and the value each field had before, and the plan's change history shows them in order. Archived plans cannot be edited. The patient is notified and sees when each exercise was last updated.

Each prescription carries a `revision` number that goes up with every edit. A session stores its own copy of the prescription and that revision at the moment it starts, which is what keeps a later edit from ever changing how a completed session is scored.

Camera check and sessions (user story 3.1, and the landmark extraction of 3.2):

- Each exercise in My Exercise Plan has **Start**, which opens a full-screen camera check. The app follows 33 body landmarks with MediaPipe Pose Landmarker, in the browser, and checks that the joints this exercise needs are in view and that there is enough light. Which joints are needed comes from the exercise's own template, so a leg exercise does not ask for arms.
- The guidance is specific and live ("Step back so your legs are visible", "It is too dark to see you clearly"). There is no button to press: the patient is standing well back from the device, so the session starts by itself once the setup has stayed good for 1.5 seconds.
- A session cannot start any other way. The app sends what it measured, never a "passed" flag, and the API judges it against the same thresholds (`backend/app/pose.py`). If it does not pass, no session row is created, so nothing can ever be scored from a setup that failed the check.
- A session stores its own copy of the prescription, the template version and the thresholds at the moment it starts. Editing the plan or the thresholds afterwards does not change it.
- The video never leaves the device. Only the landmark positions are used. What is stored is the check's measurements, the session's start and end times, and for each repetition the angles measured during it.

The live session (user stories 3.2 to 3.4), for Arm Abduction:

- Joint angles are measured in every frame from the exercise's own target joints and checks (`frontend/lib/features/session/pose/pose_features.dart`, with a Python twin in `backend/app/pose_features.py` held to the same test cases).
- Repetitions are counted from the angle of the working joint: one for each full movement away from the resting position, to the top, and back (`rep_counter.dart`). A half lift, a single bad camera frame, or a movement lost from view is not counted, and nothing is counted until the resting position has been seen. The screen shows the count, the set, and the time.
- The app never judges a repetition. It sends what it measured, and the API classifies it against the thresholds the session started with (`backend/app/severity.py`): below INFO is a good repetition, then INFO, AMBER and RED; the repetition's tier is its worst check. The feedback on screen is always the server's reply, so there is a stored record behind everything the patient is shown.
- INFO and AMBER show the check's corrective message and the session carries on. A RED repetition pauses the session in the same database transaction that stores it. While it is paused the server refuses further repetitions, and it continues only when the patient acknowledges that repetition's message. The pause and the acknowledgment are audited.
- A repetition whose reply was lost is sent again with the same key and stored once. One that could not be measured for a check is stored as unmeasured for that check rather than guessed.
- Ending the session shows a summary read from the server: the form score, a comparison with the previous session of the same exercise, time, repetitions, and how many were good, INFO, AMBER and RED.
- Exercises without a counting profile yet (Leg Abduction, Leg Lunge, Push-ups; Squats has a profile but has not been tried in front of a camera) still open a timed session and say that repetitions are not counted.

Session summary, history and review (user stories 4.2, 5.1 and 5.2):

- **Form score.** When a session ends the server stores its totals and a form score from 0 to 100. Until the classifier of 4.1 exists, the score is a transparent rule (`backend/app/scoring.py`): each repetition is worth 100 (good), 85 (INFO), 55 (AMBER) or 0 (RED), and the score is their average. The version of the rule (`rules-1`) is saved with every session, so a score always says how it was produced. A session with nothing to score has no score; it is never stored or shown as 0.
- **Summary.** The summary is built only after the session has ended, from repetitions that were each classified when they were stored, and it compares the score with the previous completed session of the same exercise.
- **Session History** lists every finished session, most recent first. A session opens in full: every repetition, its tier, the corrective message and anything that was not in view. A session left open (a closed tab) is closed and scored when the next one starts, and is marked as not finished.
- **Progress** plots the form score of one exercise over 30 days, 3 months, 12 months or all time, with the same trend in a sentence. Only sessions that happened and have a score are plotted; a day without a session is simply absent.
- **Flagged Sessions** for physiotherapists: a session goes into the queue the moment it has a RED repetition, or when it ends with a score below `FLAG_SCORE_BELOW` (60 unless set in `backend/.env`). The physiotherapist is notified, sees the patient, the reason and the full session, and marks it reviewed. Nothing else takes a session out of the queue, and a new RED after a review brings it back. A physiotherapist only ever sees sessions of patients assigned to them.

Limits to know about:

- The points per tier and the flag threshold of 60 are this project's starting values, not derived from REHAB24-6 or reviewed clinically. The score is a rule, not the trained model the user story asks for.
- The 3-second (summary) and 300 ms (history) targets have not been measured. History is not paginated; a request returns at most 1000 sessions.
- The live session has been tested with drawn body positions at known angles, in widget tests and against a real API and database. It has **not yet been tried in front of a real webcam**, so the counting angles (arm raised past 70 degrees, back below 30) and how often real tracking noise triggers feedback are unconfirmed.
- The severity thresholds are provisional (see below), so the feedback is a demonstration of the mechanism, not clinical advice.
- "Good repetition" (below the INFO threshold) is this project's addition; the user story names only RED, AMBER and INFO.
- There is no form score yet (4.1 to 4.3), and the depth check of Squats and Push-ups is not measured.
- Pose tracking is built for the web app only (the Android and iOS builds show a message instead); the pose model and its runtime are loaded from Google's and jsDelivr's servers when a session opens, so that needs an internet connection; and the frame rate on real hardware has not been measured yet.

In-app notifications:

- A bell with an unread count for every role. Opening a notification marks it read and goes to the page it is about.
- A patient is notified when a plan is assigned or a prescription in it is edited, and the plan on screen refreshes when that arrives. Patients and physiotherapists are told when a patient is reassigned. An account is notified when sign-in to it was paused or its password was changed.
- The app checks for new notifications once a minute while it is open. Push notifications (Firebase Cloud Messaging) are not built yet.

The severity thresholds that ship with the five exercises are provisional starting values. They have not yet been derived from the REHAB24-6 labels or reviewed clinically; see the note at the top of `backend/migrations/versions/0003_exercise_templates_and_plans.py`.

Not built yet: repetition counting for the other exercises, the trained classifier and its monitoring (4.1 and 4.3), pain logging and report export (5.3), reminders (6.1), push notifications, chat and feedback, and the security hardening of epic 8.

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

- `dev` is where finished work is collected. Branch from `dev`, open a pull request into `dev`, and merge only when CI is green.
- `main` is what is deployed. It only changes when `dev` is merged into it for a deployment; nothing is pushed to `main` directly.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), for example `feat(auth): add invite code registration`.
- Database changes go through Alembic: edit `app/models.py`, then `alembic revision --autogenerate -m "what changed"`.
