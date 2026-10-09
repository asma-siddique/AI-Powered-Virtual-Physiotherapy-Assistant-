import 'dart:async';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';

import 'pose_models.dart';
import 'pose_source.dart';

/// web/pose_bridge.js: the camera and MediaPipe Pose Landmarker.
@JS('physioPose')
external _PoseBridge? get _bridge;

extension type _PoseBridge._(JSObject _) implements JSObject {
  /// Resolves to "ok" or to the name of what went wrong.
  external JSPromise<JSString> start();
  external JSNumber aspect();
  external JSObject element();
  external void onFrame(JSFunction? callback);
  external void stop();
}

const _viewType = 'physioai-camera';
bool _viewRegistered = false;

PoseSource createPoseSource() => _WebPoseSource();

class _WebPoseSource implements PoseSource {
  final _frames = StreamController<PoseFrame>.broadcast();
  double _aspect = 4 / 3;

  @override
  double get aspectRatio => _aspect;

  @override
  Stream<PoseFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {
    final bridge = _bridge;
    if (bridge == null) throw const CameraException(CameraProblem.unsupported);
    final String outcome;
    try {
      outcome = (await bridge.start().toDart).toDart;
    } catch (_) {
      throw const CameraException(CameraProblem.failed);
    }
    switch (outcome) {
      case 'ok':
        break;
      case 'permission_denied':
        throw const CameraException(CameraProblem.permissionDenied);
      case 'no_camera':
        throw const CameraException(CameraProblem.noCamera);
      case 'unsupported':
        throw const CameraException(CameraProblem.unsupported);
      default:
        throw const CameraException(CameraProblem.failed);
    }
    final aspect = bridge.aspect().toDartDouble;
    if (aspect.isFinite && aspect > 0) _aspect = aspect;
    if (!_viewRegistered) {
      ui_web.platformViewRegistry.registerViewFactory(
        _viewType,
        (int _) => _bridge!.element(),
      );
      _viewRegistered = true;
    }
    bridge.onFrame(
      ((JSFloat32Array data) {
        if (!_frames.isClosed) _frames.add(PoseFrame.fromPacked(data.toDart));
      }).toJS,
    );
  }

  @override
  Widget preview() => const HtmlElementView(viewType: _viewType);

  @override
  Future<void> stop() async {
    _bridge?.onFrame(null);
    _bridge?.stop();
    await _frames.close();
  }
}
