"""The form score of a session (US 4.2).

This is a transparent rule, not the trained classifier of US 4.1: until that
model exists, a session is scored from the severity tier the server already
stored for each repetition. Every score is saved together with the version of
the rule that produced it, so when the classifier replaces this, old sessions
still say how they were scored.

The points per tier are starting values chosen for this project. They have
not been derived from REHAB24-6 or reviewed clinically.
"""

from collections.abc import Iterable, Mapping
from typing import Any

from app import severity

VERSION = "rules-1"

# What one repetition is worth, by its tier.
POINTS = {severity.OK: 100, severity.INFO: 85, severity.AMBER: 55, severity.RED: 0}


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
