// ...existing code...

class Env {
  // URL del Cloud Function que acepta viajes. Mover aquí para facilitar cambios y pruebas.
  static const String acceptTravelUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/acceptTravel';
  // URL del Cloud Function que finaliza viajes.
  static const String completeTravelUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/completeTravel';
  // URL del Cloud Function que notifica al pasajero que el conductor llegó
  static const String notifyDriverArrivedUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/notifyDriverArrivedUrl';
  // URL de Cloud Function que notifica al conductor que está cerca
  static const String notifyDriverNearUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/testFCM';
  // URL del Cloud Function que actualiza el estado del viaje
  static const String updateTravelStatusUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/updateTravelStatus';
  // URL del Cloud Function que promueve el viaje en cola a activo al terminar el 1er viaje
  static const String promoteQueuedTravelUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/promoteQueuedTravel';
  // URL del Cloud Function que cancela un viaje activo (antes de in_progress)
  static const String cancellOperationTravelTaskUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/cancellOperationTravelTask';
  // URL del Cloud Function que rescata notificaciones pendientes no procesadas
  static const String claimPendingBackgroundMessageUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/claimPendingBackgroundMessage';
}

class Config {
  // API Key de Google Maps para Directions y Mapas
  static const String googleMapsApiKey = 'AIzaSyDElBu8oLUbkYFD4ptEy-6vpIfxaTOK3Xs';
}

// ...existing code...
