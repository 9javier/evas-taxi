import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import 'foreground_task_handler.dart';

/// Servicio simple para publicar la ubicación del chofer en Firestore.
/// - start(): inicia el stream de ubicación con filtro de distancia.
/// - stop(): detiene el stream.
/// Diseñado para ser minimalista y configurable.
class DriverLocationService {
  DriverLocationService._internal();
  static final DriverLocationService _instance = DriverLocationService._internal();
  factory DriverLocationService() => _instance;

  StreamSubscription<Position>? _sub;
  Position? _lastPosition;
  DateTime? _lastSentAt;
  bool _foregroundRunning = false;

  /// Inicia el seguimiento.
  /// [driverId]: id del documento en la colección 'drivers'.
  /// [distanceFilter]: meters que el plugin usa para filtrar eventos.
  /// [minIntervalSeconds]: intervalo mínimo entre envíos a Firestore.
  Future<void> start({required String driverId, int distanceFilter = 25, int minIntervalSeconds = 8}) async {
    try {
      // cancelar si ya existe
      await stop();

      // Migración: si existe un documento con el número de teléfono como id, mover datos al doc con driverId
      try {
        final user = FirebaseAuth.instance.currentUser;
        final phone = user?.phoneNumber;
        if (phone != null && phone.isNotEmpty) {
          final phoneDocRef = FirebaseFirestore.instance.collection('drivers').doc(phone);
          final phoneSnap = await phoneDocRef.get();
          if (phoneSnap.exists) {
            final uidDocRef = FirebaseFirestore.instance.collection('drivers').doc(driverId);
            final data = phoneSnap.data() ?? {};
            // Asegurar que el campo phone quede dentro del documento con uid
            data['phone'] = phone;
            // Mergeamos todos los campos previos (excepto seguiremos escribiendo lat/lng separados luego)
            await uidDocRef.set(data, SetOptions(merge: true));
            // Eliminamos el documento antiguo con phone como id
            await phoneDocRef.delete();
          }
        }
      } catch (e) {
        // No impedir que el servicio siga si la migración falla
      }

      // Asegurar permisos mínimos
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        permission = await Geolocator.requestPermission();
      }

      // Si aun no hay permiso, salir silenciosamente
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return;

      // Levantar el Foreground Service para que Android no mate el proceso en background
      if (!_foregroundRunning) {
        try {
          await FlutterForegroundTask.startService(
            serviceId: 256,
            notificationTitle: "Eva's Taxi",
            notificationText: 'GPS activo',
            callback: foregroundTaskCallback,
          );
          _foregroundRunning = true;
        } catch (_) {}
      }

      final settings = LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: distanceFilter,
      );

      _sub = Geolocator.getPositionStream(locationSettings: settings).listen((pos) async {
        try {
          final now = DateTime.now();
          bool shouldSend = false;

          if (_lastPosition == null) {
            shouldSend = true;
          } else {
            final moved = Geolocator.distanceBetween(
              _lastPosition!.latitude,
              _lastPosition!.longitude,
              pos.latitude,
              pos.longitude,
            );
            if (moved >= distanceFilter) shouldSend = true;
          }

          if (!shouldSend && _lastSentAt != null) {
            if (now.difference(_lastSentAt!).inSeconds >= minIntervalSeconds) {
              shouldSend = true;
            }
          }

          if (shouldSend) {
            _lastPosition = pos;
            _lastSentAt = now;
            await _sendToFirestore(driverId, pos);
          }
        } catch (e) {
          // No lanzar excepción para no romper el stream
          // debugPrint puede agregarse en desarrollo
        }
      });
    } catch (e) {
      // silencioso
    }
  }

  Future<void> stop() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    _sub = null;
    _lastPosition = null;
    _lastSentAt = null;
    // Detener el Foreground Service al terminar el seguimiento
    if (_foregroundRunning) {
      try {
        await FlutterForegroundTask.stopService();
        _foregroundRunning = false;
      } catch (_) {}
    }
  }

  Future<void> _sendToFirestore(String driverId, Position pos) async {
    try {
      // Garantizar que usamos driverId como id del documento en la colección 'drivers'.
      // No creamos documentos con phone como id: asumimos driverId es el uid del conductor.
      if (driverId.isEmpty) return;
      final doc = FirebaseFirestore.instance.collection('drivers').doc(driverId);
      // Guardar solo lat y lng como campos planos para simplicidad y compatibilidad.
      await doc.set({
        'lat': pos.latitude,
        'lng': pos.longitude,
      }, SetOptions(merge: true));
    } catch (e) {
      // silencioso
    }
  }
}
