/// Coordinates the viewer's two independent durable records. In particular,
/// unchanged poses and failed pose writes must not skip accepted discoveries.
abstract final class VrlzViewerSaveBarrier {
  static Future<VrlzViewerSaveResult> save({
    Future<void> Function()? writePose,
    Future<bool> Function()? flushExpedition,
  }) async {
    Object? poseError;
    try {
      await writePose?.call();
    } catch (error) {
      poseError = error;
    }
    var expeditionSaved = true;
    try {
      expeditionSaved = await flushExpedition?.call() ?? true;
    } catch (_) {
      expeditionSaved = false;
    }
    return VrlzViewerSaveResult(poseError, expeditionSaved);
  }
}

final class VrlzViewerSaveResult {
  const VrlzViewerSaveResult(this.poseError, this.expeditionSaved);
  final Object? poseError;
  final bool expeditionSaved;
  bool get saved => poseError == null && expeditionSaved;
}
