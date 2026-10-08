import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

enum UserRole {
  patient('patient', 'Patient', '/patient'),
  physiotherapist('physiotherapist', 'Physiotherapist', '/physio'),
  admin('admin', 'Admin', '/admin');

  const UserRole(this.apiValue, this.label, this.homePath);

  final String apiValue;
  final String label;
  final String homePath;

  static UserRole fromApi(String value) =>
      values.firstWhere((role) => role.apiValue == value);

  /// Each role keeps one accent colour everywhere it is named.
  Color get accent => switch (this) {
    UserRole.patient => AppColors.tealDark,
    UserRole.physiotherapist => AppColors.primary,
    UserRole.admin => AppColors.purple,
  };

  Color get tint => switch (this) {
    UserRole.patient => AppColors.tealTint,
    UserRole.physiotherapist => AppColors.primaryTint,
    UserRole.admin => AppColors.purpleTint,
  };

  IconData get icon => switch (this) {
    UserRole.patient => Icons.accessibility_new_rounded,
    UserRole.physiotherapist => Icons.medical_services_outlined,
    UserRole.admin => Icons.admin_panel_settings_outlined,
  };
}

class Account {
  const Account({
    required this.id,
    required this.fullName,
    required this.role,
    this.email,
    this.mobile,
    this.isActive = true,
    this.createdAt,
  });

  factory Account.fromJson(Map<String, dynamic> json) => Account(
    id: json['id'] as String,
    fullName: json['full_name'] as String,
    email: json['email'] as String?,
    mobile: json['mobile'] as String?,
    role: UserRole.fromApi(json['role'] as String),
    isActive: json['is_active'] as bool? ?? true,
    createdAt: DateTime.tryParse(json['created_at'] as String? ?? ''),
  );

  final String id;
  final String fullName;
  final String? email;
  final String? mobile;
  final UserRole role;
  final bool isActive;
  final DateTime? createdAt;

  String get contact => email ?? mobile ?? '';

  /// "Dr. Sarah Malik" -> "Sarah"; "Jane Cooper" -> "Jane".
  String get firstName {
    final parts = fullName
        .split(' ')
        .where((p) => p.isNotEmpty && !p.endsWith('.'))
        .toList();
    return parts.isEmpty ? fullName : parts.first;
  }

  String get initials {
    final parts = fullName
        .split(' ')
        .where((p) => p.isNotEmpty && !p.endsWith('.'))
        .toList();
    if (parts.isEmpty) return '?';
    final first = parts.first[0];
    final last = parts.length > 1 ? parts.last[0] : '';
    return (first + last).toUpperCase();
  }
}

class PersonRef {
  const PersonRef({required this.id, required this.fullName});

  factory PersonRef.fromJson(Map<String, dynamic> json) => PersonRef(
    id: json['id'] as String,
    fullName: json['full_name'] as String,
  );

  final String id;
  final String fullName;
}

/// The signed-in person, plus (for patients) their physiotherapist and
/// whether they have acknowledged the advisory.
class SessionUser {
  const SessionUser({
    required this.account,
    this.physiotherapist,
    this.advisoryAcknowledged,
  });

  factory SessionUser.fromJson(Map<String, dynamic> json) => SessionUser(
    account: Account.fromJson(json['account'] as Map<String, dynamic>),
    physiotherapist: json['physiotherapist'] == null
        ? null
        : PersonRef.fromJson(json['physiotherapist'] as Map<String, dynamic>),
    advisoryAcknowledged: json['advisory_acknowledged'] as bool?,
  );

  final Account account;
  final PersonRef? physiotherapist;

  /// Null for physiotherapists and admins, who are never asked.
  final bool? advisoryAcknowledged;

  /// True while a patient still has to read and acknowledge the advisory.
  bool get needsAdvisory =>
      account.role == UserRole.patient && advisoryAcknowledged == false;

  SessionUser copyWith({bool? advisoryAcknowledged}) => SessionUser(
    account: account,
    physiotherapist: physiotherapist,
    advisoryAcknowledged: advisoryAcknowledged ?? this.advisoryAcknowledged,
  );
}
