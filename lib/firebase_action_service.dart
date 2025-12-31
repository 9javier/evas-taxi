import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

class FirebaseActionService {
  /// Llama al endpoint Cloud Function para aceptar un viaje.
  /// El endpoint espera JSON { travelId, driverId } vía POST.
  /// Retorna true si la función responde con status 200.
  static Future<bool> acceptTravel(String travelId, String driverId) async {
    if (travelId.isEmpty || driverId.isEmpty) return false;

    try {
      final resp = await http
          .post(Uri.parse(Env.acceptTravelUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'travelId': travelId, 'driverId': driverId}))
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        return true;
      }
      return false;
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

  /// Llama al endpoint Cloud Function para notificar que el conductor llegó o está cerca.
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
}
