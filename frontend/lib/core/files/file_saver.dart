import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'file_saver_stub.dart'
    if (dart.library.js_interop) 'file_saver_web.dart'
    as platform;

/// Hands a file to the person to keep: a download, in the browser.
typedef FileSaver =
    Future<void> Function(Uint8List bytes, String filename, String mimeType);

/// Thrown where the app cannot save a file yet.
class FileSavingUnsupported implements Exception {
  const FileSavingUnsupported();
}

final fileSaverProvider = Provider<FileSaver>((ref) => platform.saveFile);
