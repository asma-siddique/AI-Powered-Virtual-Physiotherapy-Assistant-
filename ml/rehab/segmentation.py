"""Reading REHAB24-6's repetition annotations (Segmentation.csv).

The file is semicolon-separated, one row per repetition, with the columns
video_id, repetition_number, exercise_id, person_id, first_frame, last_frame,
cam17_orientation, mocap_erroneous, exercise_subtype, lights_on,
extra_person_in_cam17, extra_person_in_cam18 and correctness (1 correct,
0 incorrect). Frames are numbered at 30 FPS.

Only the five exercises PhysioAI supports are kept; REHAB24-6's sixth
(exercise 2, "arm VW") is left out.
"""

from __future__ import annotations

import csv
import hashlib
from dataclasses import dataclass
from pathlib import Path

# REHAB24-6 exercise number -> PhysioAI exercise slug.
EXERCISES = {
    1: "arm-abduction",
    3: "push-ups",
    4: "leg-abduction",
    5: "leg-lunge",
    6: "squats",
}
SLUGS = tuple(EXERCISES[number] for number in sorted(EXERCISES))

REQUIRED_COLUMNS = (
    "video_id",
    "repetition_number",
    "exercise_id",
    "person_id",
    "first_frame",
    "last_frame",
    "correctness",
)


@dataclass(frozen=True)
class Repetition:
    video_id: str
    repetition: int
    exercise: str  # PhysioAI slug
    person: int
    first_frame: int
    last_frame: int
    correct: bool
    orientation: str  # towards camera 17: front, half-profile or profile
    subtype: str  # e.g. "right arm", "front leg left"; may be empty
    lights_on: bool
    mocap_erroneous: bool

    @property
    def key(self) -> str:
        return f"{self.video_id}#{self.repetition}"


class SegmentationError(ValueError):
    pass


def file_sha256(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_segmentation(path: Path) -> list[Repetition]:
    """The repetitions of the supported exercises, in file order. A row that
    cannot be read is an error rather than silently skipped: the labels are
    the ground truth everything else is judged against."""
    text = Path(path).read_text(encoding="utf-8-sig")
    rows = csv.DictReader(text.splitlines(), delimiter=";")
    missing = [c for c in REQUIRED_COLUMNS if c not in (rows.fieldnames or [])]
    if missing:
        raise SegmentationError(f"{path}: missing columns {missing}")
    repetitions = []
    for line, row in enumerate(rows, start=2):
        if not any((value or "").strip() for value in row.values()):
            continue
        try:
            exercise_id = int(row["exercise_id"])
            if exercise_id not in EXERCISES:
                continue
            first, last = int(row["first_frame"]), int(row["last_frame"])
            correctness = int(row["correctness"])
            person, repetition = int(row["person_id"]), int(row["repetition_number"])
        except (TypeError, ValueError) as error:
            raise SegmentationError(f"{path}, line {line}: {error}") from error
        if last <= first:
            raise SegmentationError(f"{path}, line {line}: last_frame is not after first_frame")
        if correctness not in (0, 1):
            raise SegmentationError(f"{path}, line {line}: correctness must be 0 or 1")
        repetitions.append(
            Repetition(
                video_id=row["video_id"].strip(),
                repetition=repetition,
                exercise=EXERCISES[exercise_id],
                person=person,
                first_frame=first,
                last_frame=last,
                correct=correctness == 1,
                orientation=(row.get("cam17_orientation") or "").strip(),
                subtype=(row.get("exercise_subtype") or "").strip(),
                lights_on=(row.get("lights_on") or "0").strip() == "1",
                mocap_erroneous=(row.get("mocap_erroneous") or "0").strip() == "1",
            )
        )
    keys = [r.key for r in repetitions]
    if len(keys) != len(set(keys)):
        raise SegmentationError(f"{path}: a repetition appears twice")
    return repetitions
