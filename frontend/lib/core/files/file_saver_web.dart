import 'dart:js_interop';
import 'dart:typed_data';

import 'file_saver.dart';

/// web/file_bridge.js: turns bytes into a browser download.
@JS('physioFiles')
external _FileBridge? get _bridge;

extension type _FileBridge._(JSObject _) implements JSObject {
  external void save(JSUint8Array bytes, JSString filename, JSString mimeType);
}

Future<void> saveFile(Uint8List bytes, String filename, String mimeType) async {
  final bridge = _bridge;
  if (bridge == null) throw const FileSavingUnsupported();
  bridge.save(bytes.toJS, filename.toJS, mimeType.toJS);
}
