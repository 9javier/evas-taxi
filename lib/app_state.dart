import 'package:flutter/foundation.dart';

// Notifiers globales para controlar la pestaña seleccionada y el travelId activo
final ValueNotifier<int> tabsIndexNotifier = ValueNotifier<int>(0);
final ValueNotifier<String?> activeTravelIdNotifier = ValueNotifier<String?>(null);

// Notifier que indica si el conductor está en viaje (viaje_status: in_progress).
// Se pone true al iniciar navegación (pasajero recogido) y false al finalizar.
final ValueNotifier<bool> driverOnTripNotifier = ValueNotifier<bool>(false);

// ID del segundo viaje aceptado mientras hay uno activo (viaje_status: queued).
// Se limpia cuando ese viaje se convierte en el viaje activo.
final ValueNotifier<String?> pendingTravelIdNotifier = ValueNotifier<String?>(null);

// Label del vehículo activo del conductor — se muestra en el tab de viaje.
// Formato: "MODEL · PLATE" (ej. "ACCORD · XYZ")
final ValueNotifier<String> activeVehicleLabelNotifier = ValueNotifier<String>('');

// Señal de cancelación por parte del pasajero: contiene el travelId cancelado.
// TravelScreen lo escucha para limpiar el viaje y mostrar el modal de aviso.
final ValueNotifier<String?> passengerCanceledNotifier = ValueNotifier<String?>(null);

// Cuando es true el listener de authStateChanges en main.dart no navega automáticamente.
// Se activa durante el flujo OTP para evitar que la app vaya a WelcomeScreen antes de
// verificar que el número de teléfono corresponde a un conductor registrado.
bool skipAuthNavigation = false;
