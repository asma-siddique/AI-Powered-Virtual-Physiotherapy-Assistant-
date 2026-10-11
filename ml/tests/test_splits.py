# Subject-wise splits (SCRUM-26, user story 4.1).
import json

import pytest

from rehab import splits
from rehab.segmentation import file_sha256, read_segmentation
from tests.helpers import write_segmentation


@pytest.fixture
def segmentation(tmp_path):
    return write_segmentation(tmp_path / "Segmentation.csv")


def test_no_subject_is_in_more_than_one_split(segmentation):
    record = splits.build(segmentation)
    groups = record["subjects"]
    members = [p for name in splits.SPLITS for p in groups[name]]
    assert sorted(members) == list(range(1, 11))
    assert len(members) == len(set(members))
    assert (len(groups["train"]), len(groups["val"]), len(groups["test"])) == (6, 2, 2)


def test_validation_and_test_hold_both_labels_of_every_exercise(segmentation):
    summary = splits.build(segmentation)["summary"]
    for name in ("val", "test"):
        for counts in summary[name]["by_exercise"].values():
            assert counts["correct"] > 0 and counts["incorrect"] > 0


def test_the_split_is_the_same_every_time_and_names_its_source(segmentation, tmp_path):
    first = splits.build(segmentation)
    assert splits.build(segmentation) == first
    assert first["segmentation_sha256"] == file_sha256(segmentation)
    out = tmp_path / "splits.json"
    splits.main(["--segmentation", str(segmentation), "--out", str(out)])
    assert json.loads(out.read_text()) == first


def test_subjects_whose_labels_cannot_be_balanced_are_refused(tmp_path):
    path = write_segmentation(tmp_path / "s.csv")
    text = path.read_text().splitlines()
    # Only subject 1 ever does a repetition wrong.
    rows = [text[0]] + [
        line if line.split(";")[3] == "1" else line[: line.rfind(";")] + ";1" for line in text[1:]
    ]
    path.write_text("\n".join(rows) + "\n")
    with pytest.raises(splits.SplitError, match="no subject-wise split"):
        splits.choose_split(read_segmentation(path))


def test_a_split_file_with_a_shared_subject_is_rejected(segmentation, tmp_path):
    record = splits.build(segmentation)
    record["subjects"]["test"].append(record["subjects"]["train"][0])
    path = tmp_path / "bad.json"
    path.write_text(json.dumps(record))
    with pytest.raises(splits.SplitError, match="more than one split"):
        splits.load(path)
