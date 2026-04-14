import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class FirebaseActionService {
  /// Llama al endpoint Cloud Function para aceptar un viaje.
  /// [queueMode] = true cuando el driver ya tiene un viaje activo y acepta un segundo:
  ///   el viaje se mueve requestTravel → travels con status 'queued' en lugar de 'accepted'.
  /// Retorna true si la función responde con status 200.
  static Future<bool> acceptTravel(String travelId, String driverId, {bool queueMode = false}) async {
    if (travelId.isEmpty || driverId.isEmpty) return false;

    try {
      final resp = await http
          .post(Uri.parse(Env.acceptTravelUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'travelId': travelId, 'driverId': driverId, 'queueMode': queueMode}))
          .timeout(const Duration(seconds: 8));

      return resp.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Llama al endpoint Cloud Function para promover el viaje en cola a activo.
  /// Se usa cuando el conductor termina su 1er viaje y el 2do (queued) debe arrancar.
  /// Retorna true si la función responde con status 200.
  static Future<bool> promoteQueuedTravel(String travelId, String driverId) async {
    if (travelId.isEmpty || driverId.isEmpty) return false;
    try {
      final resp = await http
          .post(Uri.parse(Env.promoteQueuedTravelUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'travelId': travelId, 'driverId': driverId}))
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Llama al endpoint Cloud Function para finalizar un viaje.
  /// Envia { travelId, driverId } y retorna true si status 200.
  static Future<bool> completeTravel(String travelId, String driverId) async {
    if (travelId.isEmpty || driverId.isEmpty) return false;
    try {
      final resp = await http
          .post(Uri.parse(Env.completeTravelUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'travelId': travelId, 'driverId': driverId}))
          .timeout(const Duration(seconds: 8));

      return resp.statusCode == 200;
    } catch (e) {
      return false;
    }
  }

  /// Llama al endpoint Cloud Function para notificar que el conductor llegó (menos de 30 metros).
  /// Env.notifyDriverArrivedUrl debe estar configurado en config.dart
  static Future<bool> notifyDriverArrived(String travelId, String driverId) async {
    if (travelId.isEmpty || driverId.isEmpty) return false;
    try {
      final resp = await http
          .post(Uri.parse(Env.notifyDriverArrivedUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'travelId': travelId, 'driverId': driverId}))
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
  /// Llama al endpoint Cloud Function para notificar que el conductor está cerca (menos de 300 metros).
  /// Env.notifyDriverNearUrl debe estar configurado en config.dart
  static Future<bool> notifyDriverNear(String travelId, String driverId) async {
    if (travelId.isEmpty || driverId.isEmpty) return false;
    try {
      final resp = await http
          .post(Uri.parse(Env.notifyDriverNearUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'travelId': travelId, 'driverId': driverId}))
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
  static Future<bool> updateTravelStatus(String travelId, String status) async {
    if (travelId.isEmpty || status.isEmpty) return false;
    try {
      final resp = await http
          .post(Uri.parse(Env.updateTravelStatusUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'travelId': travelId, 'status': status}))
          .timeout(const Duration(seconds: 8));
      return resp.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}
