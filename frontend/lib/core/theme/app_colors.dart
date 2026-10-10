import 'package:flutter/material.dart';

/// "Clinical Precision" palette from the PhysioAI design system: a deep
/// clinical teal for the patient's side, navy for authority and the
/// physiotherapist's portal, and a fixed set of severity colours.
///
/// The older names (teal, purple, success...) are kept as aliases so every
/// screen picks up the new palette without changing what it asks for.
abstract final class AppColors {
  // Primary
  static const primary = Color(0xFF006A6A); // Deep clinical teal
  static const primaryDark = Color(0xFF004D4D); // Pressed state
  static const primaryTint = Color(0xFFE0F2F1); // Tint backgrounds
  static const primaryMint = Color(0xFF00BFA5); // Accent, AI dots

  // Secondary
  static const navy = Color(0xFF1A3C5E); // Headers, authority
  static const navyLight = Color(0xFF2A5278); // Secondary text on dark
  static const navyDeep = Color(0xFF0D1F2D); // Immersive backgrounds
  static const navyTint = Color(0xFFE6EDF4);

  // The administrator's own accent, so each portal reads differently.
  static const admin = Color(0xFF4A3F8C);
  static const adminTint = Color(0xFFEFEDF9);

  // Severity: these never change.
  static const severityRed = Color(0xFFC62828);
  static const severityRedBg = Color(0xFFFFEBEE);
  static const severityAmber = Color(0xFFE65100);
  static const severityAmberBg = Color(0xFFFFF3E0);
  static const severityInfo = Color(0xFF1565C0);
  static const severityInfoBg = Color(0xFFE3F2FD);
  static const severityGreen = Color(0xFF2E7D32);
  static const severityGreenBg = Color(0xFFE8F5E9);

  // Neutrals
  static const background = Color(0xFFF4F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceAlt = Color(0xFFF0F4F8);
  static const border = Color(0xFFDDE3EA);
  static const divider = Color(0xFFE8EDF2);
  static const text = Color(0xFF0D1F2D);
  static const textMuted = Color(0xFF546E7A);
  static const textHint = Color(0xFF90A4AE);
  static const disabled = Color(0xFFB0BEC5);

  // Aliases used across the app.
  static const teal = primaryMint;
  static const tealDark = primary;
  static const tealTint = primaryTint;

  static const purple = navy;
  static const purpleDark = navyDeep;
  static const purpleTint = navyTint;

  static const success = severityGreen;
  static const successTint = severityGreenBg;
  static const warning = severityAmber;
  static const warningTint = severityAmberBg;
  static const error = severityRed;
  static const errorTint = severityRedBg;
  static const info = severityInfo;
  static const infoTint = severityInfoBg;

  // Gradients
  static const heroGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF006A6A), Color(0xFF004D4D)],
  );
  static const cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF1A3C5E), Color(0xFF006A6A)],
  );

  /// Soft lavender-to-mint wash behind hologram scenes.
  static const holoGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEAF0FB), Color(0xFFE3F4F3), Color(0xFFF1ECFA)],
  );

  /// The immersive session background.
  static const sessionGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0B1A27), Color(0xFF0D1F2D), Color(0xFF102A3A)],
  );
}
