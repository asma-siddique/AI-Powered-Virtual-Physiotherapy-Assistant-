# PhysioAI

AI-powered virtual physiotherapy assistant. Final Year Project, BS Data Science (2023-2027), FCIT, University of the Punjab.

Patients do the exercises their physiotherapist assigns while the app tracks their movement through the camera and gives severity-tiered feedback. Physiotherapists assign plans and review sessions. Admins manage accounts and the exercise library.

| Part | Stack | Folder |
|---|---|---|
| App (Android, iOS, Web) | Flutter, Riverpod, go_router | `frontend/` |
| API | FastAPI, SQLAlchemy, Alembic | `backend/` |
| Database | PostgreSQL (Supabase when hosted) | `backend/migrations/` |
| Correctness model (REHAB24-6) | Python, MediaPipe, PyTorch | `ml/` (see `ml/README.md`) |

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
- All five exercises have a counting profile (`repProfiles` in `rep_counter.dart`): Arm Abduction follows the shoulder, Leg Abduction the hip (the leg moving out about 20 degrees), Leg Lunge and Squats the knee, Push-ups the elbow. An exercise without a profile still opens a timed session and says that repetitions are not counted. Only Arm Abduction has been tried in front of a real camera so far.
- **Depth** (Squats and Push-ups) is judged on the lowest point of each repetition, not on its worst frame: the app sends how many degrees the working joint stayed short of a right angle (0 at or past it), and the template's `depth` thresholds apply to that. The camera check of Push-ups asks for the wrists, because the elbow angle cannot be measured without them.

Session summary, history and review (user stories 4.2, 5.1 and 5.2):

- **Form score.** When a session ends the server stores its totals and a form score from 0 to 100. Until an admin promotes a trained classifier (see "The trained classifier" below), the score is a transparent rule (`backend/app/scoring.py`): each repetition is worth 100 (good), 85 (INFO), 55 (AMBER) or 0 (RED), and the score is their average. The version of whatever produced it (`rules-1` for the rule) is saved with every session, so a score always says how it was produced. A session with nothing to score has no score; it is never stored or shown as 0.
- **Summary.** The summary is built only after the session has ended, from repetitions that were each classified when they were stored, and it compares the score with the previous completed session of the same exercise.
- **Session History** lists every finished session, most recent first. A session opens in full: every repetition, its tier, the corrective message and anything that was not in view. A session left open (a closed tab) is closed and scored when the next one starts, and is marked as not finished.
- **Progress** plots the form score of one exercise over 30 days, 3 months, 12 months or all time, with the same trend in a sentence. Only sessions that happened and have a score are plotted; a day without a session is simply absent.
- **Flagged Sessions** for physiotherapists: a session goes into the queue the moment it has a RED repetition, or when it ends with a score below `FLAG_SCORE_BELOW` (60 unless set in `backend/.env`). The physiotherapist is notified, sees the patient, the reason and the full session, and marks it reviewed. Nothing else takes a session out of the queue, and a new RED after a review brings it back. A physiotherapist only ever sees sessions of patients assigned to them.

Pain logging, notes and the progress report (user story 5.3):

- **Pain is optional.** During the camera check and again on the summary, the patient can pick a number from 0 to 10, and after the session add a short note. Nothing about starting or ending a session depends on it. Not answering is stored as empty, never as 0, and tapping the chosen number again takes the answer back. A rating can be changed for 24 hours after the session started; after that it is part of the record.
- **Notes.** The patient's note and the physiotherapist's own note on a session are shown with that session to both of them. The physiotherapist writes theirs from the session's detail in Flagged Sessions.
- **Report export.** On the Patients page, **Report** downloads a PDF for the last 30 days, 3 months or 12 months: a summary, the form-score trend of each exercise with a graph, every session with its score, tier counts and pain ratings, and all notes. The server only produces it for a patient assigned to the physiotherapist asking; anyone else's is "not found". The PDF is written by `backend/app/pdf.py` with the standard library only, so there is nothing extra to install.
- The audit trail records that pain was logged, a note was saved or a report was exported, but never the rating or the words.

Limits to know about:

- Report times are in UTC, because the server does not know the patient's time zone. Names written in a script outside Western European characters (for example Urdu) are replaced with "?" in the PDF, because it uses the PDF's built-in font. Report download works in the web app only.
- The points per tier and the flag threshold of 60 are this project's starting values, not derived from REHAB24-6 or reviewed clinically. The score is a rule, not the trained model the user story asks for.
- The 3-second (summary) and 300 ms (history) targets have not been measured. History is not paginated; a request returns at most 1000 sessions.
- The live session has been tested with drawn body positions at known angles, in widget tests and against a real API and database. It has **not yet been tried in front of a real webcam**, so the counting angles (arm raised past 70 degrees, back below 30) and how often real tracking noise triggers feedback are unconfirmed.
- The severity thresholds are provisional (see below), so the feedback is a demonstration of the mechanism, not clinical advice.
- "Good repetition" (below the INFO threshold) is this project's addition; the user story names only RED, AMBER and INFO.
- **The trained model does not meet its target yet.** The first model trained on the real dataset (`rehab-cnn-202610120844-23109ddc`, 12 Oct 2026) agrees with the expert labels on **60.7%** of the 366 held-out test repetitions (balanced accuracy 60.1%), where always answering "correct" would score 60.1%. **The 85% target is not met.** It scored 95.6% on the people it was trained on and 75.3% on the validation subjects, so it has learnt the training subjects rather than the movement: there are only 5 full training subjects. The app's rule (`rules-1`) scores 51.4% on the same repetitions (balanced 59.4%): it calls 177 of the 220 correct repetitions incorrect, which says the shipped thresholds are too strict for what the camera really measures. Neither is good enough to rely on; the rule stays in production and this model has not been promoted. The counting angles of every profile and the depth target of 90 degrees are starting values, not derived from REHAB24-6 or clinically reviewed.
- Pose tracking is built for the web app only (the Android and iOS builds show a message instead); the pose model and its runtime (about 15 MB) are loaded when a session opens: from a copy next to the app when `tool/fetch_pose_assets.sh` has been run (no internet needed, about 2 seconds), otherwise from Google's and jsDelivr's servers, which needs an internet connection and took over a minute on a slow one; and the frame rate on real hardware has not been measured yet.
- If the camera shows but the camera check stays on "Looking for you…", the pose tracker is not producing frames. Open the browser console (F12): the tracker reports what went wrong there (lines starting with `[PhysioAI pose]`), and `physioPose.status()` shows how many frames it has sent and how many had a person in them. When pose detection keeps failing on the graphics card, it switches to the processor by itself.

In-app notifications:

- A bell with an unread count for every role. Opening a notification marks it read and goes to the page it is about.
- A patient is notified when a plan is assigned or a prescription in it is edited, and the plan on screen refreshes when that arrives. Patients and physiotherapists are told when a patient is reassigned. An account is notified when sign-in to it was paused or its password was changed.
- The app checks for new notifications once a minute while it is open.

Reminders and alerts (user stories 6.1 and 6.2):

- **Prescribed days.** In the Plan Builder the physiotherapist chooses the days of the week a plan is for (every day unless changed). The patient sees them on My Exercise Plan.
- **Session reminders.** On those days, at the time the patient chose (18:00 unless changed, or switched off), the server sends a reminder that links straight to the first exercise not yet done that day. A scheduler inside the API looks for due reminders every 30 seconds (`REMINDER_INTERVAL_SECONDS`; 0 turns it off). One reminder per plan per day, enforced in the database. Whether one is due is decided from the plan as it is at that moment, so a replaced plan, a deactivated account or a day already completed gets none.
- **Whose evening.** The app tells the server how far the device's clock is from UTC, and again whenever that changes. Until it has, no reminder is sent.
- **Alerts.** A physiotherapist is notified the moment a patient's session has a RED repetition or ends with a low score; the notice goes to whoever the patient is assigned to at that moment. A patient is notified when their plan is assigned or edited and when their physiotherapist writes a note on a session.
- **Desktop alerts.** With permission (turned on from the notification list), anything new also appears as a notification from the browser while PhysioAI is open in a tab, and clicking it opens the page it is about.

Limit: these are **not push notifications**. Nothing reaches a device while the app is closed; the reminder is waiting in the notification list the next time it is opened. Real push needs Firebase Cloud Messaging and a Firebase project's credentials, which are not set up.

Row-level data isolation (user story 8.1):

- **A second lock, in the database.** Every endpoint already checks who is asking. On top of that, PostgreSQL row-level security policies (migration 0012) apply to every statement the API runs: a patient's plans, sessions, repetitions, prescription history, consent, reminder settings and notifications can be read or changed only by that patient and, for the clinical tables, by the physiotherapist they are assigned to now. If an endpoint's own check were ever wrong or missing, the query would still come back empty.
- **How.** Each transaction runs as the role `physioai_app`, which has no way round the policies, and carries who is asking in two settings (`backend/app/rls.py`). A request starts as nobody and becomes somebody only once its token has been checked. The identity lasts for one transaction, so it cannot leak to the next request on the same connection.
- **Who sees what.** A patient: their own rows. A physiotherapist: the clinical rows of patients assigned to them now, so reassignment moves access in the database too. An admin: who is assigned to whom and the consent records they can retrieve for audit, but no plans, sessions or repetitions. Nobody signed in: nothing.
- **The system's own work** (the reminder scheduler, linking a newly registered patient, seeding) steps up on purpose, in `rls.system(...)`; those are the only places.
- **Guard.** A test lists every table as either protected or exempt with a reason, and fails when a new table is on neither list. `tests/test_rls.py` goes round the API and tries to read, change and insert another patient's rows directly.

Tables without a policy, on purpose: `accounts`, `auth_sessions`, `login_attempts` and `invite_codes` (needed to work out who is asking in the first place), `exercise_templates` (the same for everyone), `audit_log`, and the model registry's three tables (nothing in them is about a patient). A name or email in `accounts` is therefore protected by the endpoints' checks only.

Data minimization (user story 8.2):

- **No pictures, ever.** The video stays in the browser and only joint positions leave it. The API has no way to receive a picture, and the database has no column that could hold one: `backend/tests/test_data_minimization.py` lists every binary column and fails if any appears other than the model registry's weights.
- **What a session keeps.** The camera check's measurements, its own copy of the prescription and thresholds, and for each repetition the angles measured, its tier and feedback, and (when a classifier judged it) its probability. The frame-by-frame angles sent for the classifier are read and never stored.
- **How much.** Measured by `pytest -s tests/test_data_minimization.py` (row data, indexes not counted): a typical session of 36 repetitions takes about 8.6 KB, and the largest plan allowed (10 sets of 50) at most about 253 KB, under the story's 500 KB per session. A repetition beyond the prescription is refused (`rep_out_of_range`), as a set beyond it already was, so no session can grow past the largest plan.
- **The dataset.** REHAB24-6 is CC BY-NC 4.0 (academic, non-commercial). `ml/.gitignore` keeps the dataset, its landmarks and trained weights out of the repository.
- **Not decided yet:** how long session data is kept (the retention rule of 8.2).

The trained classifier and its registry (user stories 4.1 and 4.3):

- **Training** is in `ml/` (see `ml/README.md`): REHAB24-6's videos are tracked with the app's own pose model and measured with the app's own feature code, split by subject (no person in more than one of train, validation and test), and a small 1-D CNN learns "correct" or "incorrect" per repetition. Every model has a record of exactly what it was trained on and how it scored on the held-out test subjects.
- **The API runs the model itself, without PyTorch** (`backend/app/classifier.py`, NumPy only). The export step holds the exported weights to PyTorch's own answers and writes nothing if they differ. Weights are plain arrays, loaded with pickling switched off, so an uploaded file is data and never code.
- **Registry** (`backend/app/model_registry.py`, tables `scoring_models`, `model_evaluations`, `model_promotions`, migration 0013). An admin registers a model under **Scoring Models**. The API refuses a model without a held-out evaluation, one whose splits put any subject in two splits, splits other than the ones its record names, and weights that are not the recorded model's. A registered model is a candidate and scores nothing.
- **Promotion is a decision, never automatic.** An admin promotes a candidate with a written reason, and the API refuses unless the candidate agrees with the expert labels at least as often as the model in production **on the same held-out set**. That needs the current model evaluated there too: `python -m rehab.evaluate --rule` scores the app's rule on the very same repetitions.
- **Rollback** puts the previous production model back in one request. Weights and records live in the database, so it needs no deployment. A model that was never in production cannot be "rolled back" to; it has to pass the gate.
- **Kept for good.** Evaluation records and decisions cannot be changed or deleted: a database trigger refuses, whoever asks. Every registration, evaluation, promotion and rollback is in the audit log.
- **What the model decides.** A session is scored by the model that was in production when it started and keeps it, whatever is promoted or rolled back meanwhile. With a classifier, the app sends what it measured in every frame of each repetition (angles, not pictures; read and not stored), the server stores the model's probability and version with the repetition, and the form score is the share of repetitions judged correct. **The RED / AMBER / INFO tiers and the safety pause always come from the thresholds, never from the model.** An exercise the model was not trained on, or a session whose repetitions came without frames, is scored by the rule, and the stored version says so.
- The gate is "at least as good as the current model on the same held-out set". The 85% agreement target of 4.1 is shown beside every result and an admin promoting below it is warned, but it is not what the gate checks.
- **Result so far:** The first model trained on the real dataset (`rehab-cnn-202610120844-23109ddc`, 12 Oct 2026) agrees with the expert labels on **60.7%** of the 366 held-out test repetitions (balanced accuracy 60.1%), where always answering "correct" would score 60.1%. **The 85% target is not met.** It scored 95.6% on the people it was trained on and 75.3% on the validation subjects, so it has learnt the training subjects rather than the movement: there are only 5 full training subjects. The app's rule (`rules-1`) scores 51.4% on the same repetitions (balanced 59.4%): it calls 177 of the 220 correct repetitions incorrect, which says the shipped thresholds are too strict for what the camera really measures. Neither is good enough to rely on; the rule stays in production and this model has not been promoted. The record is `ml/model_records/rehab-cnn-202610120844-23109ddc.json` and both evaluations are in `ml/evaluations/`.
- The model is tested on REHAB24-6's annotated repetitions. In the app a repetition's first and last frame come from the app's own counting, so agreement in live use is not measured by any of this. REHAB24-6 is CC BY-NC 4.0: academic, non-commercial use only; the dataset, landmarks and weights are not in the repository.

The severity thresholds that ship with the five exercises are provisional starting values. They have not yet been derived from the REHAB24-6 labels or reviewed clinically; see the note at the top of `backend/migrations/versions/0003_exercise_templates_and_plans.py`.

The spoken coach (asked for after trying a session from a distance):

- During a session the app **speaks**: where to stand during the camera check, the exercise and its instructions at the start, each repetition's count, the correction for a repetition that needs one, the end of each set with how long to rest, and the summary. It is the browser's own speech (`web/voice_bridge.js`); nothing is downloaded or recorded.
- **Alert tones.** An AMBER repetition sounds two short beeps before its correction. A RED repetition sounds an alarm and says "Stop", cutting off whatever was being said. A set or session that completes sounds a chime.
- The coach adds nothing of its own: every correction it speaks is the server's message for a repetition the server has stored and judged (`lib/features/session/narrator.dart`). The same small correction on repetition after repetition is said the first time and then on every third.
- A speaker button on the session screen switches it off and on. On a device that cannot speak the button is not shown and the session works as before.
- Not checked by ear: the tests check what the app asks the voice to say and which tone goes with it, not how it sounds on a given laptop. A RED pause still has to be confirmed on the screen.

The audit log (user story 8.3):

- Template edits and threshold changes (with the old and new values), switching an exercise on or off, role changes, moving a patient to another physiotherapist, plan assignment and prescription edits are each recorded with who did it, when, and what changed. A refused action leaves no entry.
- **Append-only, in the database.** A trigger on `audit_log` refuses every UPDATE and DELETE, whoever asks: an admin, a physiotherapist, a patient or the API itself (migration 0014; `tests/test_audit_log.py` tries each). The API has no endpoint that edits or deletes an entry.
- The database's owner can still empty a table with TRUNCATE (the tests do, between cases). The API's own role is not allowed to.

Graceful degradation (user story 9.2):

- **A dropped connection loses no repetition.** Repetitions counted while the server cannot be reached wait in order and are sent again every two seconds with the same key, so each is stored exactly once when the connection returns. The count on screen keeps up meanwhile and a notice says the last repetition is not saved yet. `test/degradation_test.dart` holds this for a full minute without a connection.
- **Nothing waits for ever without a retry.** Every request gives up after 20 seconds and every loading state has "Try again". The one screen that could hang, "Starting your camera…", now offers a retry after 20 seconds.
- **Performance budget:** each request the Home, My Plan and live-session screens make must be answered within 300 ms, and ending a session with its summary within 3 seconds. `tests/test_performance.py` measures this inside the API for a patient with 30 past sessions.
- Not done: the queue of unsent repetitions lives in the open page, so closing the tab while offline loses what was not yet sent. Feedback and the RED pause come from the server, so they arrive only once the connection is back. Load times on a real mobile connection and the 99% uptime target need the hosted demo, which does not exist yet.

Not built yet: push notifications, chat and feedback, and a hosted demo environment.

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

Run `tool/fetch_pose_assets.sh` once (from `frontend/`, in Git Bash) before a demo. It downloads the pose tracker (MediaPipe Tasks Vision and the pose model, both Apache-2.0, about 25 MB, kept out of the repository) into `web/pose/`. With it, a session starts without the internet; without it, the app downloads the same files every time a session opens. `physioPose.status().loadedFrom` in the browser console says which was used.

The app talks to `http://localhost:8000/api/v1` by default. To point it elsewhere, add `--dart-define=API_BASE_URL=https://your-host/api/v1`.

### Demo accounts

`python -m app.seed` creates one admin, one physiotherapist and one patient. Their emails and passwords are the `SEED_*` values in `backend/.env` (copied from `.env.example`). They are for local development only; the seed refuses to run when `ENVIRONMENT=production`.

`python -m app.seed --test-patients` also creates five test patients of the demo physiotherapist (`ali`, `sara`, `bilal`, `hina` and `usman`, each `@physioai.test`), who sign in with `SEED_TEST_PATIENT_PASSWORD`. Each has a plan with every exercise that is switched on, 2 sets of 5, starting from a different exercise, so all the exercises can be tried without editing anybody's plan. Running it again changes nothing.

`python -m app.seed --team` creates an admin account for each person in `SEED_TEAM_ADMINS` (written as `Full Name <email>`, separated by commas), all with `SEED_TEAM_PASSWORD`. Add `--reset-passwords` to set the passwords of team and test accounts that already exist to the values now in `.env`; no other account's password is touched. These are simple passwords for local development only.

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

## CI/CD (user story 9.1)

Every pull request, and every push to `dev` or `main`, runs `.github/workflows/ci.yml`: lint, format check and the tests of the API (against a real PostgreSQL) and of the app. A run takes under two minutes. A newer push replaces the run before it.

Two things have to be switched on in the repository's settings by an owner; the workflow cannot do them itself:

1. **A failing check blocks merging, and nothing reaches `main` or `dev` without review.** Settings > Branches > Add branch ruleset (or "Add rule"), for `main` and again for `dev`: require a pull request before merging with 1 approval, require status checks to pass and pick "Backend (lint + tests)" and "Frontend (analyze + tests)", and do not allow bypassing. Until this is set, GitHub shows the checks but still lets a red pull request be merged, and still accepts a direct push.
2. **Deploying the demo.** The `deploy-demo` job runs after the checks pass on `main`, but only once the repository variable `DEPLOY_DEMO` is `true`. It builds the web app (with the pose tracker included) and publishes it with GitHub Pages; choose "GitHub Actions" as the source under Settings > Pages and set the variable `API_BASE_URL` to the demo API's address. If the secret `BACKEND_DEPLOY_HOOK_URL` is set (a deploy hook of the host the API runs on, such as Render), it is called first so the API is redeployed from `main` too. No host for the API has been chosen yet, so this job has never run.

## Using Supabase

Put the Supabase connection string in `backend/.env` as `DATABASE_URL`, set a `JWT_SECRET` of at least 32 characters, then run `alembic upgrade head`. Authentication is handled by this API (password hashing, tokens, lockout), with its tables stored in the Supabase database; Supabase's own Auth service is not used.

## Conventions

- `dev` is where finished work is collected. Branch from `dev`, open a pull request into `dev`, and merge only when CI is green.
- `main` is what is deployed. It only changes when `dev` is merged into it for a deployment; nothing is pushed to `main` directly.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), for example `feat(auth): add invite code registration`.
- Database changes go through Alembic: edit `app/models.py`, then `alembic revision --autogenerate -m "what changed"`.
