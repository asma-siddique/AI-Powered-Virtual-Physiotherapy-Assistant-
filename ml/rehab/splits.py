"""Subject-wise train / validation / test splits of REHAB24-6 (SCRUM-26).

User story 4.1 requires the split to be made by subject, never by frame or
repetition, so that no person appears in more than one split: otherwise the
model is tested on people it has already seen and its accuracy is inflated.

REHAB24-6 has 10 subjects. Two go to validation and two to test. Of every
possible choice, the one picked is the one where validation and test each
hold both correct and incorrect repetitions of every exercise, and whose share
of repetitions is closest to 20% each; ties go to the lowest subject numbers.
The choice depends only on the annotation file, so anyone who runs this gets
the same split, and it is written down with the file's checksum.

    python -m rehab.splits --segmentation data/Segmentation.csv --out splits/rehab24_splits.json
"""

from __future__ import annotations

import argparse
import itertools
import json
from collections import Counter
from collections.abc import Sequence
from pathlib import Path

from rehab.segmentation import SLUGS, Repetition, file_sha256, read_segmentation

SPLITS = ("train", "val", "test")
HELD_OUT_SUBJECTS = 2  # in each of validation and test
TARGET_SHARE = 0.2


class SplitError(ValueError):
    pass


def _covers_every_case(reps: Sequence[Repetition]) -> bool:
    seen = {(r.exercise, r.correct) for r in reps}
    return all((slug, label) in seen for slug in SLUGS for label in (True, False))


def choose_split(repetitions: Sequence[Repetition]) -> dict[str, list[int]]:
    """Subjects per split, following the rule in the module docstring."""
    people = sorted({r.person for r in repetitions})
    if len(people) < 2 * HELD_OUT_SUBJECTS + 1:
        raise SplitError(f"need at least {2 * HELD_OUT_SUBJECTS + 1} subjects, found {len(people)}")
    by_person: dict[int, list[Repetition]] = {}
    for r in repetitions:
        by_person.setdefault(r.person, []).append(r)
    total = len(repetitions)

    best: tuple[float, tuple[int, ...], tuple[int, ...]] | None = None
    for val in itertools.combinations(people, HELD_OUT_SUBJECTS):
        rest = [p for p in people if p not in val]
        for test in itertools.combinations(rest, HELD_OUT_SUBJECTS):
            val_reps = [r for p in val for r in by_person[p]]
            test_reps = [r for p in test for r in by_person[p]]
            if not (_covers_every_case(val_reps) and _covers_every_case(test_reps)):
                continue
            cost = abs(len(val_reps) / total - TARGET_SHARE) + abs(len(test_reps) / total - TARGET_SHARE)
            candidate = (round(cost, 12), test, val)
            if best is None or candidate < best:
                best = candidate
    if best is None:
        raise SplitError(
            "no subject-wise split gives validation and test both correct and incorrect "
            "repetitions of every exercise"
        )
    _, test, val = best
    train = [p for p in people if p not in val and p not in test]
    return {"train": train, "val": list(val), "test": list(test)}


def describe(repetitions: Sequence[Repetition], subjects: dict[str, list[int]]) -> dict:
    """Counts per split, exercise and label, to read and to check."""
    summary = {}
    for name in SPLITS:
        members = set(subjects[name])
        reps = [r for r in repetitions if r.person in members]
        counts = Counter((r.exercise, r.correct) for r in reps)
        summary[name] = {
            "subjects": subjects[name],
            "repetitions": len(reps),
            "by_exercise": {
                slug: {"correct": counts[(slug, True)], "incorrect": counts[(slug, False)]} for slug in SLUGS
            },
        }
    return summary


def build(segmentation: Path) -> dict:
    repetitions = read_segmentation(segmentation)
    subjects = choose_split(repetitions)
    return {
        "dataset": "REHAB24-6",
        "segmentation_sha256": file_sha256(segmentation),
        "rule": "subject-wise; 2 validation and 2 test subjects; both labels of every exercise in each; "
        "repetition share closest to 20% each; ties to the lowest subject numbers",
        "subjects": subjects,
        "summary": describe(repetitions, subjects),
    }


def load(path: Path) -> dict:
    record = json.loads(Path(path).read_text())
    subjects = record["subjects"]
    every = [p for name in SPLITS for p in subjects[name]]
    if len(every) != len(set(every)):
        raise SplitError(f"{path}: a subject is in more than one split")
    return record


def split_of(record: dict) -> dict[int, str]:
    """Subject -> the split it belongs to."""
    return {p: name for name in SPLITS for p in record["subjects"][name]}


def main(argv: Sequence[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--segmentation", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    record = build(args.segmentation)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(record, indent=2) + "\n")
    for name in SPLITS:
        s = record["summary"][name]
        print(f"{name:5}  subjects {s['subjects']}  repetitions {s['repetitions']}")
    print(f"written to {args.out}")


if __name__ == "__main__":
    main()
