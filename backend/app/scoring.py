"""The form score of a session (US 4.2).

Two things can produce it, and every score is saved with the version of the
one that did:

- the transparent rule below ("rules-1"), from the severity tier the server
  stored for each repetition;
- a trained classifier (US 4.1), once an admin has promoted one (US 4.3): the
  share of the session's repetitions it judged to be done correctly.

Which of them is to score a session is fixed when the session starts
(app.model_registry).

The points per tier are starting values chosen for this project. They have
not been derived from REHAB24-6 or reviewed clinically.
"""

from collections.abc import Iterable, Mapping
from typing import Any

from app import severity

VERSION = "rules-1"

# What one repetition is worth, by its tier.
POINTS = {severity.OK: 100, severity.INFO: 85, severity.AMBER: 55, severity.RED: 0}


# A repetition counts as done correctly from this probability up; the same
# cut the classifier is evaluated with (ml/rehab/train.py).
CORRECT_FROM = 0.5


def classifier_score(probabilities: Iterable[float]) -> tuple[int | None, int]:
    """The score from 0 to 100 a classifier gives a session: the share of the
    repetitions it judged that it found correct, and how many it judged."""
    judged = [probability >= CORRECT_FROM for probability in probabilities]
    if not judged:
        return None, 0
    return round(100 * sum(judged) / len(judged)), len(judged)


def is_scorable(measures: Mapping[str, Any]) -> bool:
    """A repetition can be scored when at least one of its checks was
    measured. One where nothing was in view says nothing about form."""
    return any(value is not None for value in measures.values())


def form_score(repetitions: Iterable[tuple[str, Mapping[str, Any]]]) -> tuple[int | None, int]:
    """The session's score from 0 to 100 and how many repetitions it is based
    on, from each repetition's (tier, measures). The score is None, never 0,
    when there was nothing to score."""
    points = [POINTS[tier] for tier, measures in repetitions if is_scorable(measures)]
    if not points:
        return None, 0
    return round(sum(points) / len(points)), len(points)
