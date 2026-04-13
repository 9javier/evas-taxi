import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Callback top-level requerido por flutter_foreground_task.
// Se ejecuta en un isolate separado; la lógica GPS vive en el isolate principal
// (DriverLocationService). Este handler solo existe para satisfacer la API del plugin.
@pragma('vm:entry-point')
void foregroundTaskCallback() {
  FlutterForegroundTask.setTaskHandler(_GpsKeepAliveHandler());
}

class _GpsKeepAliveHandler extends TaskHandler {
  // El trabajo real (GPS + Firestore) lo hace DriverLocationService en el isolate principal.
  // Este handler solo mantiene vivo el foreground service de Android.

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}
