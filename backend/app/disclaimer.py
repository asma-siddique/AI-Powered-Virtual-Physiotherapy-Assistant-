"""The advisory a patient must acknowledge before their first live session.

The wording lives on the server so the acknowledgment screen and the Help page
always show exactly the same text, and so each consent record can name the
version that was agreed to. Change the wording and CURRENT_VERSION together:
patients are then asked to acknowledge the new version."""

CURRENT_VERSION = "2026-10"

DISCLAIMER = {
    "title": "Before your first session",
    "intro": "A few things to know so you can exercise safely and confidently.",
    "points": [
        {
            "heading": "PhysioAI gives movement feedback.",
            "body": "It watches your form through your camera and suggests small corrections in real time.",
        },
        {
            "heading": "It does not diagnose.",
            "body": "PhysioAI does not diagnose medical conditions "
            "and does not replace your physiotherapist.",
        },
        {
            "heading": "Your physiotherapist is in charge.",
            "body": "Your exercises are assigned by your physiotherapist. "
            "The AI only helps you perform them with good form.",
        },
    ],
    "caution": "If you feel sharp pain, dizziness or discomfort, stop and contact your physiotherapist.",
    "acknowledgment": "I understand that PhysioAI provides movement feedback only "
    "and does not replace professional medical advice.",
}
