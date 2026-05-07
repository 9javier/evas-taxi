import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) throw UnsupportedError('Web no soportado en esta app.');
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.android:
        return android;
      default:
        throw UnsupportedError(
          'Plataforma no soportada: $defaultTargetPlatform',
        );
    }
  }

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAInIINb90pZrvdLvdUL9Skkfe6lTb3Ytc',
    appId: '1:628462975918:ios:a8a8f7fbf2d09f69c9663f',
    messagingSenderId: '628462975918',
    projectId: 'taxiusa-atlanta',
    storageBucket: 'taxiusa-atlanta.firebasestorage.app',
    databaseURL: 'https://taxiusa-atlanta-default-rtdb.firebaseio.com',
    iosBundleId: 'com.evastaxi.driver',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyB7mUbWB1NVSa_HLOM2f1rvc_h8p-Vsoyk',
    appId: '1:628462975918:android:acc6704f63433549c9663f',
    messagingSenderId: '628462975918',
    projectId: 'taxiusa-atlanta',
    storageBucket: 'taxiusa-atlanta.firebasestorage.app',
    databaseURL: 'https://taxiusa-atlanta-default-rtdb.firebaseio.com',
  );
}
