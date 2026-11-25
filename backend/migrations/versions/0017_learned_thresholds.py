"""thresholds learned from REHAB24-6, from the side the app films each exercise

Revision ID: 0017
Revises: 0016
Create Date: 2026-11-25

The thresholds shipped in migration 0003 were starting values set by hand.
Measured from the side the app films each exercise from (migration 0015), they
paused every leg lunge repetition, correct ones included, and 72% of push-ups,
and agreed with the expert labels on 58.6% of the test subjects' repetitions.

These are learned from the labelled repetitions of the 8 non-test subjects
(ml/rehab/thresholds.py, ml/evaluations/thresholds-app-view.json) and agree
with the labels on 75.8% of the test subjects' (balanced
75.9%); 1 of 61 correct test repetitions reaches RED, against 15
with the old values.

- AMBER: for a check the data shows to tell incorrect from correct (bootstrap
  95% interval of its separation above chance), the value with the best
  balanced accuracy; for one without signal from this camera view, the 98th
  percentile of correct repetitions, so it only warns beyond what they do.
- INFO: the 75th percentile of correct repetitions.
- RED: for a check with signal, the 98th percentile of correct repetitions;
  a check without signal cannot pause a session.

Checks with signal: leg-abduction trunk_lean, leg-abduction knee_bend, push-ups hip_sag, squats knee_valgus.

An exercise is only changed when its checks are still exactly as shipped, so an
admin's own edits are kept. It gets a new version, so sessions already
recorded keep the thresholds they were judged against.
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0017"
down_revision: Union[str, Sequence[str], None] = "0016"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# slug -> check key -> [INFO, AMBER, RED]
SHIPPED = {
    "arm-abduction": {
        "trunk_lean": [
            5,
            10,
            20
        ],
        "elbow_bend": [
            10,
            20,
            None
        ]
    },
    "leg-abduction": {
        "trunk_lean": [
            5,
            10,
            20
        ],
        "knee_bend": [
            10,
            20,
            None
        ]
    },
    "leg-lunge": {
        "knee_valgus": [
            5,
            10,
            15
        ],
        "knee_forward": [
            10,
            20,
            30
        ],
        "trunk_lean": [
            10,
            20,
            None
        ]
    },
    "push-ups": {
        "hip_sag": [
            5,
            12,
            20
        ],
        "depth": [
            10,
            25,
            None
        ]
    },
    "squats": {
        "knee_valgus": [
            5,
            10,
            15
        ],
        "trunk_lean": [
            10,
            20,
            30
        ],
        "depth": [
            10,
            25,
            None
        ]
    }
}
LEARNED = {
    "arm-abduction": {
        "trunk_lean": [
            2.5,
            4.0,
            None
        ],
        "elbow_bend": [
            26.0,
            37.0,
            None
        ]
    },
    "leg-abduction": {
        "trunk_lean": [
            17.0,
            19.0,
            21.0
        ],
        "knee_bend": [
            11.0,
            13.5,
            None
        ]
    },
    "leg-lunge": {
        "knee_valgus": [
            101.0,
            112.0,
            None
        ],
        "knee_forward": [
            46.0,
            57.5,
            None
        ],
        "trunk_lean": [
            13.5,
            18.5,
            None
        ]
    },
    "push-ups": {
        "hip_sag": [
            25.0,
            31.0,
            33.0
        ],
        "depth": [
            22.0,
            45.0,
            None
        ]
    },
    "squats": {
        "knee_valgus": [
            3.0,
            5.0,
            10.0
        ],
        "trunk_lean": [
            5.0,
            8.5,
            None
        ],
        "depth": [
            56.5,
            70.5,
            None
        ]
    }
}

_templates = sa.table(
    "exercise_templates",
    sa.column("slug", sa.String),
    sa.column("checks", sa.JSON),
    sa.column("version", sa.Integer),
)


def _levels(checks: list[dict]) -> dict[str, list]:
    return {c["key"]: [c["info"], c["amber"], c.get("red")] for c in checks}


def _move(source: dict, target: dict) -> None:
    connection = op.get_bind()
    rows = connection.execute(sa.select(_templates.c.slug, _templates.c.checks)).all()
    for slug, checks in rows:
        if slug not in source or _levels(checks) != {k: list(v) for k, v in source[slug].items()}:
            continue
        moved = [
            {**c, "info": target[slug][c["key"]][0], "amber": target[slug][c["key"]][1], "red": target[slug][c["key"]][2]}
            for c in checks
        ]
        connection.execute(
            _templates.update()
            .where(_templates.c.slug == slug)
            .values(checks=moved, version=_templates.c.version + 1)
        )


def upgrade() -> None:
    """Upgrade schema."""
    _move(SHIPPED, LEARNED)


def downgrade() -> None:
    """Downgrade schema."""
    _move(LEARNED, SHIPPED)
