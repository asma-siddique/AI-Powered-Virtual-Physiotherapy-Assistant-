# PhysioAI: REHAB24-6 correctness classifier

User stories 4.1 and 4.3 (SCRUM-26, SCRUM-47, SCRUM-48): a model trained on the REHAB24-6 dataset that judges whether a repetition was done correctly, grounded in the dataset's expert labels rather than hand-written rules, recorded so that every model can be traced to the exact data it was trained on, and put into the app only by an admin's decision, on evidence, with a way back.

| Step | Module | What it produces |
|---|---|---|
| 1. Read the annotations | `rehab/segmentation.py` | repetitions of the 5 supported exercises with their correct/incorrect labels |
| 2. Split by subject | `rehab/splits.py` | `splits/rehab24_splits.json` (committed): no person in more than one split |
| 3. Track the videos | `rehab/extract.py` | `data/landmarks/*.npz`: the 33 MediaPipe landmarks per frame, measured the way the app measures them |
| 4. Build examples | `rehab/dataset.py` | `data/reps.npz` + `.json` manifest: each repetition as joint angles and checks from the app's own feature code |
| 5. Train and record | `rehab/train.py` | `models/<version>/` (weights, not committed) and `model_records/<version>.json` (committed) |
| 6. Package for the API | `rehab/export.py` | `models/<version>/registration.json`: the record, the splits and the weights as the API runs them |
| 7. Evaluate on the held-out subjects | `rehab/evaluate.py` | `evaluations/<version>.json` for a model, or for the app's rule on the very same repetitions |

Why these choices:

- **Same measurements as the app.** The videos are tracked with the same MediaPipe model as the web app (`pose_landmarker_lite`), mirrored the same way, and every frame goes through `backend/app/pose_features.py`, the Python twin of the app's feature code. The dataset's motion-capture skeletons use a different body model and are not used.
- **Split by subject, never by frame or repetition.** Otherwise the model is tested on people it has already seen. 2 subjects for validation and 2 for test, chosen by a fixed rule from the annotation file (see `splits.py`), so everyone gets the same split.
- **Nothing guessed.** A value whose landmarks were not clearly in view is masked, not invented; a repetition with no pose in most of its frames is left out and counted in the manifest.
- **The API runs what was tested.** The API has no PyTorch; it runs the network with NumPy (`backend/app/classifier.py`). `rehab.export` holds the exported arrays to PyTorch's own output on random repetitions and writes nothing if they differ, and `rehab.evaluate` scores a model through that same NumPy code.
- **Traceable.** Each model's record holds its version, the checksums of the annotations, splits, landmarks and dataset it was trained on, its settings, and its validation and test results. The test subjects are used once, after the model is chosen.

## Licence

REHAB24-6 is [CC BY-NC 4.0](https://zenodo.org/records/13305826): academic, non-commercial use only, citing Černek, Sedmidubsky and Budikova, "REHAB24-6: Physical Therapy Dataset for Analyzing Pose Estimation Methods", SISAP 2024. The dataset, the landmarks and the trained weights stay out of the repository (`ml/.gitignore`).

## Setup (once)

From the repository root, in PowerShell:

```powershell
cd ml
py -3.11 -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
pytest
```

All tests should pass (they use small stand-ins for the dataset, so they run before anything is downloaded).

Download into `ml/data/`:

1. From https://zenodo.org/records/13305826: **`Segmentation.csv`** (53 kB) and **`videos.zip`** (2.7 GB). The skeleton zips are not needed. Unzip the videos into `ml/data/videos/`.
2. The pose model the app uses: https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_lite/float16/1/pose_landmarker_lite.task, saved as `ml/data/pose_landmarker_lite.task`.

## Running it (from `ml/`, venv active)

```powershell
# 2. Subject-wise splits (seconds). Commit the result.
python -m rehab.splits --segmentation data/Segmentation.csv --out splits/rehab24_splits.json

# 3a. Check that every video is found for both cameras (seconds)
python -m rehab.extract --videos data/videos --segmentation data/Segmentation.csv --model data/pose_landmarker_lite.task --out data/landmarks --list

# 3b. Track them (long: about one to a few hours on a laptop; it can be stopped and started again)
python -m rehab.extract --videos data/videos --segmentation data/Segmentation.csv --model data/pose_landmarker_lite.task --out data/landmarks

# 4. Build the examples (minutes)
python -m rehab.dataset --segmentation data/Segmentation.csv --splits splits/rehab24_splits.json --landmarks data/landmarks --out data/reps.npz

# 5. Train and record (minutes on a CPU)
python -m rehab.train --data data/reps.npz --out models
```

`rehab.train` prints the test agreement against the expert labels, per exercise, next to what always answering "correct" would score, and whether the 85% target of user story 4.1 is met. Commit `splits/rehab24_splits.json` and the new file in `model_records/`; share the weights in `models/<version>/model.pt` with the team separately.

## Putting a model into the app (user story 4.3)

```powershell
# 6. Package the trained model for the API (seconds). Refuses if the API would answer differently from PyTorch.
python -m rehab.export --model models/<version> --splits splits/rehab24_splits.json

# 7a. The model on the held-out test subjects, run the way the API runs it
python -m rehab.evaluate --data data/reps.npz --model models/<version>

# 7b. The app's rule on the very same repetitions, so the two can be compared
python -m rehab.evaluate --data data/reps.npz --rule --segmentation data/Segmentation.csv --landmarks data/landmarks
```

Then, signed in to the app as an admin, under **Scoring Models**:

1. **Register a model**: choose `models/<version>/registration.json`. The API checks it again itself: it refuses a model without a held-out evaluation, one whose splits put any subject in two splits, splits other than the ones in the record, and weights that are not the recorded model's. The model becomes a *candidate* and scores nothing.
2. **Add an evaluation**: choose `evaluations/rules-1.json` (step 7b), so the model in production has a result on the same held-out set.
3. **Promote**: shows both results side by side and asks for a reason. The API refuses unless the candidate agrees with the expert labels at least as often as the current model on the same set. Nothing is ever promoted automatically.
4. **Roll back** puts the previous model back at once: weights and records are in the database, so no deployment is needed.

Every evaluation and every decision is kept for good; the database refuses to change or delete them. A session keeps the model it started with, and each session and repetition stores the version that judged it.

What the model does and does not decide once promoted: the session's **form score** becomes the share of repetitions it judged correct. The **RED / AMBER / INFO tiers and the safety pause stay with the thresholds**; a model never pauses or fails to pause a session. An exercise the model was not trained on, or a repetition the app sent no frames for, is scored by the rule, and the stored version says so.

## Results so far

All numbers are agreement with the expert labels on the two test subjects (2 and 4, 366 examples), whom no choice was made on.

| Model | Test agreement | Balanced accuracy | How it was chosen |
|---|---|---|---|
| `rehab-cnn-202611121625-ae9b9741` (in production locally) | 65.0% | 62.2% | `rehab.crossval`: 6 settings, 4 folds over the 8 non-test subjects; winner mirror + time shift + noise at 20 epochs (67.4% pooled on held-out subjects); then trained on all 8 |
| `rehab-cnn-202611121625-ae9b9741` on the corrected data | 66.4% | 64.6% | the same model, with the lunge's knee-forward angle measured on the front leg (below) |
| `rehab-cnn-202611121716-5ff772ab` (candidate, refused by the gate) | 62.8% | 60.3% | the cross-validation winner's settings, retrained on the corrected data |
| `rehab-cnn-202610120844-23109ddc` (first model) | 60.7% | 60.1% | best epoch on the 2 validation subjects (75.3% there) |
| `rules-1` with the shipped thresholds | 51.4% | 59.4% | hand-set |
| always answering "correct" | 60.1% | 50.0% | for comparison |

By exercise, the production model scores: arm abduction 48.8%, push-ups 75.0%, leg abduction 77.4%, leg lunge 58.8%, squats 70.2% (on the corrected data: 50.0%, 75.0%, 83.3%, 57.5%, 70.2%). The 85% target is not met.

**The lunge's knee-forward fix.** The angle of the shin from vertical was taken from whichever leg came first, which in a side-on lunge was often the back leg (median 77 degrees). It now comes from the front leg, the one whose knee is higher in the picture (median 36 degrees), in both the app (`pose_features.dart`) and the API (`pose_features.py`), held to a new shared test case. `data/reps.npz` was rebuilt (the old one is kept as `reps-v1.npz`). The retrained model (`evaluations/rehab-cnn-202611121716-5ff772ab.json`) did better on lunges (70.0%) and arm abduction (62.2%) but worse on squats (48.8%) and overall; registered as a candidate, the gate refused it (`not_better`: 62.8% against 66.4% on the same test set), so it is not used. The corrected measurement alone does not separate correct from incorrect lunges (median 36.4 against 36.8 degrees).

Cross-validation over the non-test subjects (`evaluations/crossval-202611121624.json`, pooled held-out agreement): baseline 65.8%, mirror 66.7%, mirror + jitter 67.4%, small 65.1%, small + mirror + jitter 65.3%, regularised + mirror + jitter 66.7%. The differences are small: with 10 people the estimate itself moves by a few points.

### The patient's own reference (`rehab.personal`, in the app as `personal-2`)

Why the classifier stalls: the dataset's description says the physiotherapist "suggested different exercise mistakes for each subject". Within one person, correct and incorrect repetitions do differ, but how they differ changes from person to person (for front-view arm abduction, person 2's incorrect repetitions raise the arm higher, person 9's lower). A model judging people it has never seen learns the training people's mistakes; on front-view arm abduction the production classifier gets 2 of 21 test repetitions right, confidently the wrong way round.

What works: judge each repetition by its distance from the same person's own first correct repetitions. For each recording, only repetitions filmed from the side the app asks for are used (the camera angle is labelled per repetition: people sometimes turn mid-recording). The reference is the mean of the first 2 correct ones. The distance (`app.personal.distance`, the function the API runs) is taken over the exercise's own channels (its target joints on both sides and its checks); on each channel the difference is divided by its spread, how much correct repetitions typically differ from their own reference there (median, learned, at least 0.5 degrees), and the distance is the mean of those. The cut per exercise is the one with the best balanced accuracy. Spreads and cuts are learned from the data; the API loads them from `backend/app/personal_model.json`, written by `--ship`.

```
python -m rehab.personal --data data/reps.npz --segmentation data/Segmentation.csv \
    --model models/rehab-cnn-202611121625-ae9b9741 --ship ../backend/app/personal_model.json
```

| | Agreement | Balanced |
|---|---|---|
| Cross-validation, 8 non-test subjects (each fold's spreads and cuts from the other folds), 308 reps | 78.2% | 78.2% |
| **Test subjects, learned on all 8 others, 79 reps** | **83.5%** | **84.0%** |
| Production classifier on the same 79 test reps | 63.3% | 63.2% |
| Always "correct" on them | 51.9% | 50% |

By exercise on test: push-ups 100%, leg abduction 93.8%, arm abduction 88.2%, lunge 75%, squats 62.5%. Recorded in `evaluations/personal-2.json`; `backend/tests/test_personal.py` holds the API's shipped model to it.

How the variant was chosen, on the 8 non-test subjects only (cross-validated balanced accuracy): every channel, plain degrees (the first version, `personal-1`) 75.6%; the exercise's own channels 77.9%; every channel scaled by its spread 77.9%; **own channels scaled by spread 78.2%**; root-mean-square or 90th percentile instead of the mean, the largest difference per channel, or a time-warped alignment (DTW): 70.9 to 78.1%. Choosing the variant per exercise inside the training folds gave 78.4%, no better within the noise, so the single simpler variant was kept. Adding the threshold checks to the distance in a logistic regression made it worse (73.9%). The choice was made before the test subjects were scored.

Checked before trusting it:

- **Not just "later in the recording".** Every recording has its correct repetitions first, so distance could have measured drift. It does not: correct repetitions stay about 4 degrees from the reference all the way through, and the distance jumps to about 10 degrees at the first incorrect one, and stays there.
- **How many reference repetitions:** 1 gives 71.6%, 2 gives 76.0%, 3 gives 74.2% (cross-validation, first version). 2 it is.
- **Tried and not better:** the classifier trained on the app's view only (63.6% cross-validated, against 66.1% for all views); the classifier fed each repetition's difference from the reference (74.8% at its best epoch, 62.0% at a fixed one: unstable); a logistic regression on per-channel differences (70.1%).

Limits: the honest expectation for new people is the cross-validated **78%**; 83.5% is on 79 test repetitions, a small number, so the true figure could be several points either way. Squats is the weak exercise (62.5% on test). In the dataset the reference and the judged repetitions are in the same recording; in the app the reference comes from an earlier, supervised session, possibly with a slightly different camera position. That has not been measured.

### Thresholds learned from the labels (`rehab.thresholds`, in the app since migration 0017)

```
python -m rehab.thresholds --data data/reps.npz --segmentation data/Segmentation.csv \
    --landmarks data/landmarks --out evaluations/thresholds-app-view.json
```

Every level is learned from the 8 non-test subjects' labelled repetitions, filmed from the side the app films each exercise from (migration 0015), because that is how the app measures them:

- **Does the check carry signal?** Its separation (the chance an incorrect repetition measures higher than a correct one; 0.5 is none) with a bootstrap 95% interval. Only a check whose interval lies above 0.5 counts.
- **AMBER:** for a check with signal, the value with the best balanced accuracy against the labels; for one without, just above the 98th percentile of correct repetitions, so it only warns beyond what they do.
- **INFO:** the 75th percentile of correct repetitions.
- **RED:** for a check with signal, the 98th percentile of correct repetitions (above AMBER). A check without signal cannot pause a session: nothing in the data links it to incorrect form.

| Exercise | Check | Separation (95% interval) | INFO / AMBER / RED, shipped → learned |
|---|---|---|---|
| Arm abduction | trunk lean | 0.52 (0.37–0.66), none | 5 / 10 / 20 → 2.5 / 4 / none |
| Arm abduction | elbow straightness | 0.48 (0.34–0.64), none | 10 / 20 / none → 26 / 37 / none |
| Leg abduction | trunk lean | **0.79 (0.69–0.87)** | 5 / 10 / 20 → 17 / 19 / 21 |
| Leg abduction | leg straightness | **0.81 (0.71–0.89)** | 10 / 20 / none → 11 / 13.5 / none |
| Leg lunge | knee alignment | 0.32 (0.19–0.45), reversed | 5 / 10 / 15 → 101 / 112 / none |
| Leg lunge | knee position | 0.41 (0.28–0.56), none | 10 / 20 / 30 → 46 / 57.5 / none |
| Leg lunge | back posture | 0.56 (0.41–0.69), none | 10 / 20 / none → 13.5 / 18.5 / none |
| Push-ups | body line | **0.82 (0.73–0.91)** | 5 / 12 / 20 → 25 / 31 / 33 |
| Push-ups | depth | 0.57 (0.46–0.69), none | 10 / 25 / none → 22 / 45 / none |
| Squats | knee alignment | **0.71 (0.58–0.84)** | 5 / 10 / 15 → 3 / 5 / 10 |
| Squats | back posture | 0.55 (0.39–0.69), none | 10 / 20 / 30 → 5 / 8.5 / none |
| Squats | depth | 0.35 (0.21–0.49), reversed | 10 / 25 / none → 56.5 / 70.5 / none |

On the test subjects, filmed the app's way, a repetition with no check at AMBER counted as correct agrees with the labels **75.8%** of the time (balanced 75.9%), against **58.6%** with the shipped values. How often they pause (RED) on the test subjects' repetitions: shipped values paused every lunge repetition and 72% of push-ups, 15 of 61 correct repetitions in all; learned values pause 40% of leg abductions and 39% of push-ups, 1 of 61 correct repetitions.

What the table says about the checks themselves: 4 of 12 tell incorrect from correct from the side the app films. "Reversed" means a higher value goes with *correct* form: from the side, the lunge's "knee alignment" measures knee bend, so a deep, correct lunge reads high; from the front, the squat's "depth" is foreshortened. Arm abduction and the lunge are left without a check that can pause a session. That follows from the data, but it is a safety decision a physiotherapist should confirm; an admin can set any level under Admin > Exercise Library.

The earlier derivations are kept for the record and superseded: `thresholds-202611121608.json` (view-blind) and `thresholds-202611121614.json` / `thresholds-202611121800.json` (each check in its own ideal view, which is not how the app films).

A note on the test subjects: they have been scored several times (each model, each threshold derivation, `personal-1` and `personal-2`). Every choice of settings, variants or thresholds was made on the other eight subjects; the test numbers were not used to choose anything.

## Not yet done


- The 85% target is shown next to every result but is not what the gate checks: the gate is "at least as good as the model in production on the same held-out set". An admin promoting a model below the target is warned and has to give a reason.
- The model is evaluated on REHAB24-6's annotated repetitions. In the app a repetition's first and last frame come from the app's own counting, which starts a little later and ends a little earlier, so agreement in live use is not measured by any of this.
- RED / AMBER / INFO thresholds derived from the labels: REHAB24-6 labels a repetition only as correct or incorrect, so the severity tiers still need clinical review.
