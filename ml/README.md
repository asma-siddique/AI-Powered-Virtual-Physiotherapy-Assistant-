# PhysioAI: REHAB24-6 correctness classifier

User story 4.1 (SCRUM-26, SCRUM-47, SCRUM-48): a model trained on the REHAB24-6 dataset that judges whether a repetition was done correctly, grounded in the dataset's expert labels rather than hand-written rules, and recorded so that every model can be traced to the exact data it was trained on.

| Step | Module | What it produces |
|---|---|---|
| 1. Read the annotations | `rehab/segmentation.py` | repetitions of the 5 supported exercises with their correct/incorrect labels |
| 2. Split by subject | `rehab/splits.py` | `splits/rehab24_splits.json` (committed): no person in more than one split |
| 3. Track the videos | `rehab/extract.py` | `data/landmarks/*.npz`: the 33 MediaPipe landmarks per frame, measured the way the app measures them |
| 4. Build examples | `rehab/dataset.py` | `data/reps.npz` + `.json` manifest: each repetition as joint angles and checks from the app's own feature code |
| 5. Train and record | `rehab/train.py` | `models/<version>/` (weights, not committed) and `model_records/<version>.json` (committed) |

Why these choices:

- **Same measurements as the app.** The videos are tracked with the same MediaPipe model as the web app (`pose_landmarker_lite`), mirrored the same way, and every frame goes through `backend/app/pose_features.py`, the Python twin of the app's feature code. The dataset's motion-capture skeletons use a different body model and are not used.
- **Split by subject, never by frame or repetition.** Otherwise the model is tested on people it has already seen. 2 subjects for validation and 2 for test, chosen by a fixed rule from the annotation file (see `splits.py`), so everyone gets the same split.
- **Nothing guessed.** A value whose landmarks were not clearly in view is masked, not invented; a repetition with no pose in most of its frames is left out and counted in the manifest.
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

## Not yet done

- Using the model in the app (the score is still the rule in `backend/app/scoring.py`), and gated promotion and rollback (user story 4.3).
- RED / AMBER / INFO thresholds derived from the labels: REHAB24-6 labels a repetition only as correct or incorrect, so the severity tiers still need clinical review.
