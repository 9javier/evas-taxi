import 'dart:async';

/// Simple guard que evita mostrar la misma notificación repetida
/// en un intervalo configurable (por defecto 1 minuto).
class NotificationGuard {
  static final Set<String> _recent = {};
  static Timer? _timer;
  static Duration _ttl = const Duration(minutes: 1);
  static bool debug = false; // activar para logs

  static bool tryAdd(String id) {
    final normalized = id.trim().toLowerCase();
    if (normalized.isEmpty) {
      if (debug) print('[NotificationGuard] tryAdd: id vacío');
      return false;
    }
    if (_recent.contains(normalized)) {
      if (debug) print('[NotificationGuard] tryAdd: ya existe $normalized -> IGNORADO');
      return false;
    }
    _recent.add(normalized);
    if (debug) print('[NotificationGuard] tryAdd: agregado $normalized (count=${_recent.length})');
    _ensureTimer();
    return true;
  }

  static void _ensureTimer() {
    _timer ??= Timer.periodic(_ttl, (_) {
      if (debug) print('[NotificationGuard] limpiando cache de IDs');
      _recent.clear();
    });
  }

  static void clear() {
    if (debug) print('[NotificationGuard] clear()');
    _recent.clear();
  }

  static void dispose() {
    if (debug) print('[NotificationGuard] dispose()');
    _timer?.cancel();
    _timer = null;
    _recent.clear();
  }
}
