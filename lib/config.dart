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
}

class Config {
  // API Key de Google Maps para Directions y Mapas
  static const String googleMapsApiKey = 'AIzaSyDElBu8oLUbkYFD4ptEy-6vpIfxaTOK3Xs';
}

// ...existing code...
