import Flutter
import UIKit
import GoogleMaps // Google Maps SDK

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Google Maps API Key: Pega tu API key aquí
    GMSServices.provideAPIKey("AIzaSyDElBu8oLUbkYFD4ptEy-6vpIfxaTOK3Xs")
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
