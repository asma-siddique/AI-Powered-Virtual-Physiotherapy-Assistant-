import 'dart:js_interop';

import 'file_picker.dart';

/// web/file_bridge.js: opens the browser's file chooser and reads the file.
@JS('physioFiles')
external _FileBridge? get _bridge;

extension type _FileBridge._(JSObject _) implements JSObject {
  external JSPromise<_Picked?> pick(JSString accept);
}

extension type _Picked._(JSObject _) implements JSObject {
  external JSString get name;

  /// Null when the file is too large to read.
  external JSString? get text;
}

Future<PickedTextFile?> pickTextFile(String accept) async {
  final bridge = _bridge;
  if (bridge == null) throw const FilePickingUnsupported();
  final picked = await bridge.pick(accept.toJS).toDart;
  if (picked == null) return null;
  final text = picked.text;
  if (text == null) throw PickedFileTooLarge(picked.name.toDart);
  return PickedTextFile(name: picked.name.toDart, text: text.toDart);
}
