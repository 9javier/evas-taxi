import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class LocalDb {
  LocalDb._init();
  static final LocalDb instance = LocalDb._init();
  static Database? _db;

  Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await _initDB('local.db');
    return _db!;
  }

  Future<Database> _initDB(String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, fileName);
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE driver(
      uid TEXT PRIMARY KEY,
      json TEXT
    )
    ''');
  }

  Future<void> saveDriver(Map<String, dynamic> driver) async {
    final database = await db;
    final uid = (driver['uid'] ?? '') as String;
    final jsonStr = jsonEncode(driver);
    await database.insert(
      'driver',
      {'uid': uid, 'json': jsonStr},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getDriver(String uid) async {
    final database = await db;
    final maps = await database.query('driver', where: 'uid = ?', whereArgs: [uid], limit: 1);
    if (maps.isEmpty) return null;
    return jsonDecode(maps.first['json'] as String) as Map<String, dynamic>;
  }

  Future<void> clearDriver(String uid) async {
    final database = await db;
    await database.delete('driver', where: 'uid = ?', whereArgs: [uid]);
  }

  Future<void> close() async {
    final database = _db;
    if (database != null) {
      await database.close();
      _db = null;
    }
  }
}

