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

| Model | Test agreement | Balanced accuracy | Notes |
|---|---|---|---|
| `rehab-cnn-202610120844-23109ddc` | 60.7% of 366 | 60.1% | train 95.6%, validation 75.3%; **85% target not met** |
| `rules-1` (the app's rule) | 51.4% of 366 | 59.4% | calls 177 of 220 correct repetitions incorrect, 1 of 146 incorrect ones correct |
| always answering "correct" | 60.1% | 50.0% | for comparison |

Test subjects 2 and 4, both cameras; 1,010 training, 352 validation and 366 test examples, none skipped. By exercise the model scores: arm abduction 63.4%, push-ups 77.8%, leg abduction 63.1%, leg lunge 48.8%, squats 59.5%.

What this says: the model fits the people it was trained on and does not carry over to new people (there are only 5 full training subjects; subject 10 has 16 examples). It is no better than always answering "correct", so it has not been promoted. The rule's result says the thresholds the app ships with are far too strict for what MediaPipe measures on real people. Things to try next, judged on the validation subjects only: fewer and simpler inputs, stronger regularisation and augmentation (mirroring left and right, time shifts), one small model per exercise, and cross-validation over subjects for a steadier estimate than two test people give.

## Not yet done


- The 85% target is shown next to every result but is not what the gate checks: the gate is "at least as good as the model in production on the same held-out set". An admin promoting a model below the target is warned and has to give a reason.
- The model is evaluated on REHAB24-6's annotated repetitions. In the app a repetition's first and last frame come from the app's own counting, which starts a little later and ends a little earlier, so agreement in live use is not measured by any of this.
- RED / AMBER / INFO thresholds derived from the labels: REHAB24-6 labels a repetition only as correct or incorrect, so the severity tiers still need clinical review.
