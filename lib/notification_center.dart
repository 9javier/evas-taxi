// filepath: c:\Users\Dell\StudioProjects\evas_taxi_driver\lib\notification_center.dart
import 'package:flutter/material.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

final List<Map<String, dynamic>> _pendingTravelNotificationsQueue = [];

typedef PendingHandler = void Function(String travelId, BuildContext ctx, String? phone);

PendingHandler? _handler;

void registerPendingHandler(PendingHandler h) {
  _handler = h;
}

void addPendingNotification(String id, String? phone) {
  _pendingTravelNotificationsQueue.add({'id': id, 'phone': phone, 'timestamp': DateTime.now()});
  // intentar procesar pronto
  Future.delayed(const Duration(milliseconds: 500), tryHandlePendingNotifications);
}

void tryHandlePendingNotifications() {
  final ctx = navigatorKey.currentContext;
  if (ctx == null) return;
  if (_handler == null) return;
  final now = DateTime.now();
  final toProcess = _pendingTravelNotificationsQueue
      .where((item) => now.difference(item['timestamp'] as DateTime).inSeconds <= 30)
      .toList();
  _pendingTravelNotificationsQueue.removeWhere((item) => toProcess.contains(item));
  for (final item in toProcess) {
    try {
      _handler?.call(item['id'] as String, ctx, item['phone'] as String?);
    } catch (_) {}
  }
}

