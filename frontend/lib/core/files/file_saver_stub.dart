import 'dart:typed_data';

import 'file_saver.dart';

/// Outside the browser there is no download to hand the file to yet.
Future<void> saveFile(Uint8List bytes, String filename, String mimeType) =>
    throw const FileSavingUnsupported();
