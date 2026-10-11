# Reading REHAB24-6's annotations (SCRUM-26).
import pytest

from rehab.segmentation import SLUGS, SegmentationError, read_segmentation
from tests.helpers import HEADER, write_segmentation


def test_the_real_file_format_is_read(tmp_path):
    path = tmp_path / "Segmentation.csv"
    # The first rows of the real file, as published.
    path.write_text(
        "\ufeff"
        + HEADER
        + "\nPM_000;1;1;1;180;377;front;0;right arm;0;3;0;1"
        + "\nPM_002;5;1;1;1000;1225;half-profile;0;right arm;0;2;0;0\n",
        encoding="utf-8",
    )
    first, second = read_segmentation(path)
    assert (first.video_id, first.repetition, first.exercise, first.person) == (
        "PM_000",
        1,
        "arm-abduction",
        1,
    )
    assert (first.first_frame, first.last_frame, first.correct) == (180, 377, True)
    assert (first.orientation, first.subtype, first.lights_on) == ("front", "right arm", False)
    assert second.correct is False and second.key == "PM_002#5"


def test_only_the_five_supported_exercises_are_kept(tmp_path):
    reps = read_segmentation(write_segmentation(tmp_path / "s.csv", people=1, reps_per_video=2))
    # REHAB24-6's exercise 2 (arm VW) is not one of PhysioAI's.
    assert sorted({r.exercise for r in reps}) == sorted(SLUGS)
    assert len(reps) == 5 * 2


@pytest.mark.parametrize(
    "row, problem",
    [
        ("PM_000;1;1;1;300;200;front;0;;0;0;0;1", "not after"),
        ("PM_000;1;1;1;100;200;front;0;;0;0;0;2", "0 or 1"),
        ("PM_000;1;1;one;100;200;front;0;;0;0;0;1", "line 2"),
    ],
)
def test_a_row_that_cannot_be_trusted_stops_the_reading(tmp_path, row, problem):
    path = tmp_path / "s.csv"
    path.write_text(HEADER + "\n" + row + "\n")
    with pytest.raises(SegmentationError, match=problem):
        read_segmentation(path)


def test_missing_columns_and_duplicates_are_errors(tmp_path):
    path = tmp_path / "s.csv"
    path.write_text("video_id;exercise_id\nPM_000;1\n")
    with pytest.raises(SegmentationError, match="missing columns"):
        read_segmentation(path)
    path.write_text(HEADER + "\nPM_000;1;1;1;1;9;front;0;;0;0;0;1\nPM_000;1;1;1;1;9;front;0;;0;0;0;1\n")
    with pytest.raises(SegmentationError, match="twice"):
        read_segmentation(path)
