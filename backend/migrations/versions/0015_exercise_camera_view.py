"""each exercise says which way the patient faces the camera

Revision ID: 0015
Revises: 0014
Create Date: 2026-11-12

Several checks only measure what they claim from one side: knee valgus and a
sideways trunk lean from the front; a forward lean, hip sag, depth and knee
position from the side. Measured on REHAB24-6, "knee valgus" seen from the
side is really knee bend (about 90 degrees in a squat). The camera check now
makes the patient face the camera, or stand side-on to it, as the exercise
needs, and from the side it asks for each joint on the near side only (the far
side is hidden behind the body: both knees pass the visibility rule in 18% of
side-view frames, both elbows in 1%).

Lunges and push-ups are side-on; the rest face the camera. Squats faces the
camera because its knee valgus check is the one that can pause a session.
The instructions of the shipped exercises say so, unless an admin has already
changed them.
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = "0015"
down_revision: Union[str, Sequence[str], None] = "0014"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

# slug -> (view, words put in front of the shipped instructions)
VIEWS = {
    "arm-abduction": ("front", None),  # its instructions already say "facing the camera"
    "leg-abduction": ("front", "Face the camera."),
    "leg-lunge": ("side", "Stand side-on to the camera."),
    "push-ups": ("side", "Set up side-on to the camera."),
    "squats": ("front", "Face the camera."),
}
# The instructions as migration 0003 shipped them: only these are changed.
SHIPPED = {
    "leg-abduction": "Stand tall, holding a chair for balance if you need to. Move one leg out to "
    "the side, keeping it straight and your body upright. Bring it back slowly.",
    "leg-lunge": "Stand tall, then take a step forward and lower yourself until your front knee "
    "is bent to about a right angle. Keep your chest up and your front knee over "
    "your ankle. Push back to standing.",
    "push-ups": "Start in a plank with your hands under your shoulders and your body in a "
    "straight line. Bend your elbows to lower your chest, then push back up. Keep "
    "your hips level throughout.",
    "squats": "Stand with your feet shoulder-width apart. Bend your knees and push your hips "
    "back as if sitting on a chair, keeping your chest up and your knees in line "
    "with your toes. Stand back up slowly.",
}


def upgrade() -> None:
    """Upgrade schema."""
    op.add_column(
        "exercise_templates",
        sa.Column("camera_view", sa.String(length=5), server_default="front", nullable=False),
    )
    op.create_check_constraint(
        "ck_exercise_templates_camera_view", "exercise_templates", "camera_view IN ('front', 'side')"
    )
    templates = sa.table(
        "exercise_templates",
        sa.column("slug", sa.String),
        sa.column("camera_view", sa.String),
        sa.column("instructions", sa.Text),
        sa.column("version", sa.Integer),
    )
    for slug, (view, words) in VIEWS.items():
        if view != "front":
            op.execute(templates.update().where(templates.c.slug == slug).values(camera_view=view))
        if words is not None:
            # A new version, so sessions already recorded keep saying which one they used.
            op.execute(
                templates.update()
                .where(templates.c.slug == slug, templates.c.instructions == SHIPPED[slug])
                .values(instructions=f"{words} {SHIPPED[slug]}", version=templates.c.version + 1)
            )


def downgrade() -> None:
    """Downgrade schema."""
    templates = sa.table("exercise_templates", sa.column("slug", sa.String), sa.column("instructions", sa.Text))
    for slug, (_, words) in VIEWS.items():
        if words is not None:
            op.execute(
                templates.update()
                .where(templates.c.slug == slug, templates.c.instructions == f"{words} {SHIPPED[slug]}")
                .values(instructions=SHIPPED[slug])
            )
    op.drop_constraint("ck_exercise_templates_camera_view", "exercise_templates")
    op.drop_column("exercise_templates", "camera_view")
