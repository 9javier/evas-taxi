import 'dart:async';
import 'package:firebase_database/firebase_database.dart';

/// Maneja la presencia online/offline del conductor en RTDB.
///
/// Flujo:
///  1. Escucha .info/connected para saber si hay conexión activa.
///  2. Al conectarse: registra onDisconnect(false) en el servidor ANTES
///     de escribir true — garantiza que si la app muere, RTDB lo marca offline.
///  3. Al desconectarse: RTDB ejecuta el handler automáticamente.
///  4. Una Cloud Function escucha presence/{driverId} y sincroniza
///     isOnline en Firestore cuando el valor cambia a false.
class DriverPresenceService {
  DriverPresenceService._();
  static final instance = DriverPresenceService._();

  StreamSubscription<DatabaseEvent>? _connectedSub;
  String? _driverId;

  Future<void> start(String driverId) async {
    if (_driverId == driverId) return; // ya activo para este driver
    await _cancelSubscription();
    _driverId = driverId;

    final presenceRef  = FirebaseDatabase.instance.ref('presence/$driverId');
    final connectedRef = FirebaseDatabase.instance.ref('.info/connected');

    _connectedSub = connectedRef.onValue.listen((event) async {
      if (event.snapshot.value != true) return;
      // Registrar onDisconnect PRIMERO — crítico para no dejar estado "online" huérfano
      await presenceRef.onDisconnect().set(false);
      await presenceRef.set(true);
    });
  }

  /// Llama esto solo en logout explícito. Para cierre de app el onDisconnect lo maneja RTDB.
  Future<void> stop() async {
    final id = _driverId;
    await _cancelSubscription();
    if (id != null) {
      try {
        await FirebaseDatabase.instance.ref('presence/$id').set(false);
      } catch (_) {}
    }
  }

  Future<void> _cancelSubscription() async {
    await _connectedSub?.cancel();
    _connectedSub = null;
    _driverId = null;
  }
}
