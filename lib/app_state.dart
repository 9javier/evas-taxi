import 'package:flutter/foundation.dart';

// Notifiers globales para controlar la pestaña seleccionada y el travelId activo
final ValueNotifier<int> tabsIndexNotifier = ValueNotifier<int>(0);
final ValueNotifier<String?> activeTravelIdNotifier = ValueNotifier<String?>(null);

// Notifier que indica si el conductor está en viaje (on_trip).
// Se pone true al iniciar navegación/viaje y false al finalizar.
final ValueNotifier<bool> driverOnTripNotifier = ValueNotifier<bool>(false);
