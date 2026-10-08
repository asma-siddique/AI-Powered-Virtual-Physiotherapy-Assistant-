"""exercise templates and plans

Creates the exercise library and the plan tables, and adds the five exercises
the project supports (the REHAB24-6 set).

The severity thresholds inserted here are PROVISIONAL starting values chosen so
the rest of the system has something to work with. They have not been derived
from the REHAB24-6 labels or reviewed clinically yet; that is the model work
tracked in the sprint plan. Change them through the admin API
(PATCH /api/v1/admin/exercises/{id}), which versions and audits every edit.

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-08

"""
import uuid
from datetime import datetime, timezone
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '0003'
down_revision: Union[str, Sequence[str], None] = '0002'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _check(key, label, measure, info, amber, red, message, unit='degrees'):
    return {
        'key': key, 'label': label, 'measure': measure, 'unit': unit,
        'info': info, 'amber': amber, 'red': red, 'corrective_message': message,
    }


DEFAULT_EXERCISES = [
    {
        'slug': 'arm-abduction',
        'name': 'Arm Abduction',
        'domain': 'Shoulder rehabilitation',
        'body_area': 'shoulder',
        'primary_targets': 'Deltoid, rotator cuff',
        'target_joints': ['shoulder', 'elbow', 'hip'],
        'movement_pattern': 'Standing, the arm is raised sideways from the hip to shoulder height '
                            'with the elbow straight, then lowered under control.',
        'instructions': 'Stand tall facing the camera with your arms by your sides. Raise your arm out '
                        'to the side until it is level with your shoulder, keeping the elbow straight '
                        'and your body upright. Lower it slowly.',
        'checks': [
            _check('trunk_lean', 'Trunk lean', 'Sideways lean of the trunk away from vertical',
                   5, 10, 20, 'Keep your body upright. Do not lean away as you lift your arm.'),
            _check('elbow_bend', 'Elbow straightness', 'Elbow flexion during the lift',
                   10, 20, None, 'Keep your elbow straight as you raise your arm.'),
        ],
    },
    {
        'slug': 'leg-abduction',
        'name': 'Leg Abduction',
        'domain': 'Hip and gluteal rehabilitation',
        'body_area': 'hip',
        'primary_targets': 'Gluteus medius and minimus',
        'target_joints': ['hip', 'knee', 'ankle'],
        'movement_pattern': 'Standing on one leg, the other leg moves out to the side with the knee '
                            'straight and the trunk upright, then returns.',
        'instructions': 'Stand tall, holding a chair for balance if you need to. Move one leg out to '
                        'the side, keeping it straight and your body upright. Bring it back slowly.',
        'checks': [
            _check('trunk_lean', 'Trunk lean', 'Sideways lean of the trunk away from vertical',
                   5, 10, 20, 'Stay upright. Do not lean over as your leg moves out.'),
            _check('knee_bend', 'Leg straightness', 'Knee flexion of the moving leg',
                   10, 20, None, 'Keep the moving leg straight.'),
        ],
    },
    {
        'slug': 'leg-lunge',
        'name': 'Leg Lunge',
        'domain': 'Knee and functional rehabilitation',
        'body_area': 'knee',
        'primary_targets': 'Quadriceps, hip stabilisers',
        'target_joints': ['hip', 'knee', 'ankle'],
        'movement_pattern': 'A step forward, lowering the body until the front knee is bent to about '
                            '90 degrees with the knee over the ankle, then pushing back up.',
        'instructions': 'Stand tall, then take a step forward and lower yourself until your front knee '
                        'is bent to about a right angle. Keep your chest up and your front knee over '
                        'your ankle. Push back to standing.',
        'checks': [
            _check('knee_valgus', 'Knee alignment', 'Inward deviation of the front knee from the hip-ankle line',
                   5, 10, 15, 'Keep your front knee in line with your toes.'),
            _check('knee_forward', 'Knee position', 'Forward angle of the front shin beyond vertical',
                   10, 20, 30, 'Do not let your front knee move past your toes.'),
            _check('trunk_lean', 'Back posture', 'Forward lean of the trunk beyond the expected range',
                   10, 20, None, 'Keep your chest up and your back straight.'),
        ],
    },
    {
        'slug': 'push-ups',
        'name': 'Push-ups',
        'domain': 'Core and upper-body rehabilitation',
        'body_area': 'upper_body',
        'primary_targets': 'Pectorals, triceps, core stabilisers',
        'target_joints': ['shoulder', 'elbow', 'hip', 'knee', 'ankle'],
        'movement_pattern': 'From a straight-body plank, the elbows bend to lower the chest towards the '
                            'floor, then press back up, keeping the body in one line.',
        'instructions': 'Start in a plank with your hands under your shoulders and your body in a '
                        'straight line. Bend your elbows to lower your chest, then push back up. Keep '
                        'your hips level throughout.',
        'checks': [
            _check('hip_sag', 'Body line', 'Deviation of the hips from the shoulder-ankle line',
                   5, 12, 20, 'Keep your body in a straight line. Do not let your hips drop or rise.'),
            _check('depth', 'Depth', 'Elbow angle short of 90 degrees at the lowest point',
                   10, 25, None, 'Lower your chest a little further if it is comfortable.'),
        ],
    },
    {
        'slug': 'squats',
        'name': 'Squats',
        'domain': 'Functional, whole-body rehabilitation',
        'body_area': 'whole_body',
        'primary_targets': 'Quadriceps, glutes, core',
        'target_joints': ['hip', 'knee', 'ankle'],
        'movement_pattern': 'Feet shoulder-width apart, the hips and knees bend to lower the body as if '
                            'sitting back, chest up and knees over the toes, then stand.',
        'instructions': 'Stand with your feet shoulder-width apart. Bend your knees and push your hips '
                        'back as if sitting on a chair, keeping your chest up and your knees in line '
                        'with your toes. Stand back up slowly.',
        'checks': [
            _check('knee_valgus', 'Knee alignment', 'Inward deviation of the knees from the hip-ankle line',
                   5, 10, 15, 'Keep your knees in line with your toes. Do not let them move inward.'),
            _check('trunk_lean', 'Back posture', 'Forward lean of the trunk beyond the expected range',
                   10, 20, 30, 'Lift your chest and keep your back straight.'),
            _check('depth', 'Depth', 'Knee angle short of the target depth',
                   10, 25, None, 'Lower a little further if it is comfortable.'),
        ],
    },
]


def upgrade() -> None:
    """Upgrade schema."""
    templates = op.create_table('exercise_templates',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('slug', sa.String(length=60), nullable=False),
    sa.Column('name', sa.String(length=80), nullable=False),
    sa.Column('domain', sa.String(length=80), nullable=False),
    sa.Column('body_area', sa.String(length=30), nullable=False),
    sa.Column('primary_targets', sa.String(length=160), nullable=False),
    sa.Column('target_joints', sa.JSON(), nullable=False),
    sa.Column('movement_pattern', sa.Text(), nullable=False),
    sa.Column('instructions', sa.Text(), nullable=False),
    sa.Column('checks', sa.JSON(), nullable=False),
    sa.Column('is_active', sa.Boolean(), server_default=sa.text('true'), nullable=False),
    sa.Column('version', sa.Integer(), server_default='1', nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('updated_at', sa.DateTime(timezone=True), nullable=False),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('slug')
    )
    op.create_table('exercise_plans',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('patient_id', sa.Uuid(), nullable=False),
    sa.Column('physiotherapist_id', sa.Uuid(), nullable=False),
    sa.Column('name', sa.String(length=80), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), nullable=False),
    sa.Column('archived_at', sa.DateTime(timezone=True), nullable=True),
    sa.ForeignKeyConstraint(['patient_id'], ['accounts.id'], ),
    sa.ForeignKeyConstraint(['physiotherapist_id'], ['accounts.id'], ),
    sa.PrimaryKeyConstraint('id')
    )
    op.create_index('ix_exercise_plans_patient', 'exercise_plans', ['patient_id', 'created_at'], unique=False)
    op.create_index('uq_exercise_plans_active', 'exercise_plans', ['patient_id'], unique=True, postgresql_where=sa.text('archived_at IS NULL'))
    op.create_table('plan_exercises',
    sa.Column('id', sa.Uuid(), nullable=False),
    sa.Column('plan_id', sa.Uuid(), nullable=False),
    sa.Column('exercise_template_id', sa.Uuid(), nullable=False),
    sa.Column('position', sa.Integer(), nullable=False),
    sa.Column('sets', sa.Integer(), nullable=False),
    sa.Column('reps', sa.Integer(), nullable=False),
    sa.Column('rest_seconds', sa.Integer(), nullable=False),
    sa.Column('difficulty', sa.Enum('easy', 'medium', 'hard', name='plan_difficulty'), nullable=False),
    sa.Column('note', sa.String(length=200), nullable=True),
    sa.ForeignKeyConstraint(['exercise_template_id'], ['exercise_templates.id'], ),
    sa.ForeignKeyConstraint(['plan_id'], ['exercise_plans.id'], ),
    sa.PrimaryKeyConstraint('id'),
    sa.UniqueConstraint('plan_id', 'position', name='uq_plan_exercises_position')
    )

    now = datetime.now(timezone.utc)
    op.bulk_insert(templates, [
        {**exercise, 'id': uuid.uuid4(), 'is_active': True, 'version': 1, 'created_at': now, 'updated_at': now}
        for exercise in DEFAULT_EXERCISES
    ])


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table('plan_exercises')
    op.drop_index('uq_exercise_plans_active', table_name='exercise_plans', postgresql_where=sa.text('archived_at IS NULL'))
    op.drop_index('ix_exercise_plans_patient', table_name='exercise_plans')
    op.drop_table('exercise_plans')
    op.drop_table('exercise_templates')
    sa.Enum(name='plan_difficulty').drop(op.get_bind())
