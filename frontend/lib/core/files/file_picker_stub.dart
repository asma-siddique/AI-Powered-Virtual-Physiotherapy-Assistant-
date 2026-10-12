import 'file_picker.dart';

/// Outside the browser there is no file chooser to open yet.
Future<PickedTextFile?> pickTextFile(String accept) =>
    throw const FilePickingUnsupported();
