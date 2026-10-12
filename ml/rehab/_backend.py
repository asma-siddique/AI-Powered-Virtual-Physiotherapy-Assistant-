"""Makes the backend's feature code importable from ml/, so training uses the
very same angle calculation as the app (app.pose_features, the Python twin of
frontend/lib/features/session/pose/pose_features.dart), and so a model is
exported and evaluated with the very code the API runs it with
(app.classifier)."""

import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[2] / "backend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from app import classifier, scoring, severity  # noqa: E402
from app.pose import LANDMARKS, MIN_VISIBILITY  # noqa: E402
from app.pose_features import depth_shortfall, frame_features  # noqa: E402

__all__ = [
    "BACKEND",
    "LANDMARKS",
    "MIN_VISIBILITY",
    "classifier",
    "depth_shortfall",
    "frame_features",
    "scoring",
    "severity",
]
