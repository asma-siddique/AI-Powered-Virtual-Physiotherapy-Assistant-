"""Severity tiers for one repetition (US 3.4).

The app sends what it measured during a repetition; this module decides how
serious each measurement is, using the thresholds the session was started
with. Nothing here reads the exercise template as it is today, so editing the
thresholds later never changes how a stored repetition was judged.
"""

from collections.abc import Mapping, Sequence
from typing import Any

OK, INFO, AMBER, RED = "ok", "info", "amber", "red"
# From least to most serious.
TIERS = (OK, INFO, AMBER, RED)


def tier_of(value: float, check: Mapping[str, Any]) -> str:
    """How serious one measured value is for one check. A threshold is reached
    at its own value, so a check with RED at 20 is RED at exactly 20."""
    red = check.get("red")
    if red is not None and value >= red:
        return RED
    if value >= check["amber"]:
        return AMBER
    if value >= check["info"]:
        return INFO
    return OK


def classify(
    measures: Mapping[str, float | None], checks: Sequence[Mapping[str, Any]]
) -> tuple[str, list[dict[str, Any]], list[str]]:
    """The repetition's tier (the worst of its checks), the feedback to show
    (one entry for each check at INFO or above, worst first) and the checks that
    could not be measured. A check that was not measured is never guessed."""
    feedback: list[dict[str, Any]] = []
    unmeasured: list[str] = []
    for check in checks:
        value = measures.get(check["key"])
        if value is None:
            unmeasured.append(check["key"])
            continue
        tier = tier_of(value, check)
        if tier != OK:
            feedback.append(
                {
                    "check": check["key"],
                    "label": check["label"],
                    "tier": tier,
                    "value": value,
                    "unit": check.get("unit", "degrees"),
                    "message": check["corrective_message"],
                }
            )
    # Stable sort: checks of the same tier keep the template's order.
    feedback.sort(key=lambda item: TIERS.index(item["tier"]), reverse=True)
    return (feedback[0]["tier"] if feedback else OK), feedback, unmeasured
