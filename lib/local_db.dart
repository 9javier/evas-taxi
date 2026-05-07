import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class LocalDb {
  LocalDb._init();
  static final LocalDb instance = LocalDb._init();

  static const String _prefix = 'driver_';

  Future<void> saveDriver(Map<String, dynamic> driver) async {
    final uid = (driver['uid'] ?? '') as String;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$uid', jsonEncode(driver));
  }

  Future<Map<String, dynamic>?> getDriver(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString('$_prefix$uid');
    if (jsonStr == null) return null;
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  Future<void> clearDriver(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$uid');
  }

  Future<void> close() async {}
}
