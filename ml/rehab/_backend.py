"""Makes the backend's feature code importable from ml/, so training uses the
very same angle calculation as the app (app.pose_features, the Python twin of
frontend/lib/features/session/pose/pose_features.dart)."""

import sys
from pathlib import Path

BACKEND = Path(__file__).resolve().parents[2] / "backend"
if str(BACKEND) not in sys.path:
    sys.path.insert(0, str(BACKEND))

from app.pose import LANDMARKS, MIN_VISIBILITY  # noqa: E402
from app.pose_features import frame_features  # noqa: E402

__all__ = ["LANDMARKS", "MIN_VISIBILITY", "frame_features"]
