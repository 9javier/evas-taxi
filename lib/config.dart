// ...existing code...

class Env {
  // URL del Cloud Function que acepta viajes. Mover aquí para facilitar cambios y pruebas.
  static const String acceptTravelUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/acceptTravel';
  // URL del Cloud Function que finaliza viajes.
  static const String completeTravelUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/completeTravel';
  // URL del Cloud Function que notifica al pasajero que el conductor llegó (o está cerca)
  static const String notifyDriverArrivedUrl = 'https://us-central1-taxiusa-atlanta.cloudfunctions.net/notifyDriverArrivedUrl';
}

class Config {
  // API Key de Google Maps para Directions y Mapas
  static const String googleMapsApiKey = 'AIzaSyDElBu8oLUbkYFD4ptEy-6vpIfxaTOK3Xs';
}

// ...existing code...
