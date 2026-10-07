final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
final _mobile = RegExp(r'^\+?\d{10,15}$');

String? validateFullName(String? value) {
  if ((value ?? '').trim().length < 2) return 'Enter your full name.';
  return null;
}

String? validateIdentifier(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return 'Enter your email or mobile number.';
  if (text.contains('@')) {
    return _email.hasMatch(text) ? null : 'Enter a valid email address.';
  }
  final digits = text.replaceAll(RegExp(r'[\s\-().]'), '');
  return _mobile.hasMatch(digits)
      ? null
      : 'Enter a valid email address or mobile number.';
}

String? validateNewPassword(String? value) {
  final text = value ?? '';
  final strong =
      text.length >= 8 &&
      RegExp(r'[A-Za-z]').hasMatch(text) &&
      RegExp(r'\d').hasMatch(text);
  return strong
      ? null
      : 'Use at least 8 characters, including a letter and a number.';
}

String? validateRequired(String? value, String message) =>
    (value ?? '').trim().isEmpty ? message : null;
