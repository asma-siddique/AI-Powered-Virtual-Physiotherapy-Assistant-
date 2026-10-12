import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_picker_stub.dart'
    if (dart.library.js_interop) 'file_picker_web.dart'
    as platform;

/// A text file the person chose from their own device.
class PickedTextFile {
  const PickedTextFile({required this.name, required this.text});

  final String name;
  final String text;
}

/// Lets the person choose a text file; null when they choose none. [accept]
/// is what the chooser offers, such as `.json`.
typedef TextFilePicker = Future<PickedTextFile?> Function(String accept);

/// Thrown where the app cannot open a file chooser yet.
class FilePickingUnsupported implements Exception {
  const FilePickingUnsupported();
}

/// Thrown when the chosen file is larger than the app reads.
class PickedFileTooLarge implements Exception {
  const PickedFileTooLarge(this.name);

  final String name;
}

final textFilePickerProvider = Provider<TextFilePicker>(
  (ref) => platform.pickTextFile,
);
