import 'dart:io';

import 'package:path/path.dart' as p;
// Reexporta la API de sqflite y añade el backend FFI que necesita el escritorio.
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Base de datos local. Todo se queda en el dispositivo: sin nube ni cuentas.
class RingDatabase {
  RingDatabase._(this.db);

  final Database db;

  static const _version = 1;

  static bool _ffiReady = false;

  /// En escritorio (Windows/Linux/macOS) sqflite necesita el backend FFI;
  /// en Android e iOS usa el SQLite del sistema. Esto permite correr la misma
  /// app en la PC para probarla contra el anillo sin depender del teléfono.
  static void _ensureDesktopBackend() {
    if (_ffiReady) return;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    _ffiReady = true;
  }

  /// [path] solo se usa en las pruebas, para abrir una base en memoria.
  static Future<RingDatabase> open({String? path}) async {
    _ensureDesktopBackend();
    path ??= p.join(await getDatabasesPath(), 'smart_ring.db');
    final db = await openDatabase(
      path,
      version: _version,
      onCreate: (db, _) async => _createSchema(db),
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
    );
    return RingDatabase._(db);
  }

  static Future<void> _createSchema(Database db) async {
    // Una fila por lectura puntual. `kind` distingue la métrica; los campos no
    // aplicables quedan en NULL.
    await db.execute('''
      CREATE TABLE readings (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        taken_at    INTEGER NOT NULL,        -- epoch ms, hora local del teléfono
        kind        TEXT    NOT NULL,        -- 'hr' | 'spo2' | 'bp'
        heart_rate  INTEGER,
        spo2        INTEGER,
        systolic    INTEGER,
        diastolic   INTEGER,
        pulse_from_bp INTEGER,               -- 3.er byte de 06 03 (hipótesis)
        source      TEXT    NOT NULL         -- 'live' | 'history'
      )
    ''');

    // Evita duplicar al re-sincronizar el mismo historial dos veces.
    await db.execute(
      'CREATE UNIQUE INDEX idx_readings_dedup ON readings(taken_at, kind, source)',
    );
    await db.execute('CREATE INDEX idx_readings_at ON readings(taken_at)');

    await db.execute('''
      CREATE TABLE sleep_nights (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        start_at  INTEGER NOT NULL,
        end_at    INTEGER NOT NULL,
        UNIQUE(start_at, end_at)
      )
    ''');

    await db.execute('''
      CREATE TABLE sleep_segments (
        id        INTEGER PRIMARY KEY AUTOINCREMENT,
        night_id  INTEGER NOT NULL REFERENCES sleep_nights(id) ON DELETE CASCADE,
        stage     TEXT    NOT NULL,          -- 'deep' | 'light' | 'rem' | 'awake'
        start_at  INTEGER NOT NULL,
        duration_s INTEGER NOT NULL
      )
    ''');

    // El contador de pasos del anillo se reinicia a medianoche: guardamos el
    // máximo visto por día en lugar de acumular, para que un reinicio no reste.
    await db.execute('''
      CREATE TABLE activity_daily (
        day         TEXT PRIMARY KEY,        -- 'YYYY-MM-DD'
        steps       INTEGER NOT NULL DEFAULT 0,
        distance_m  INTEGER NOT NULL DEFAULT 0,
        calories    INTEGER NOT NULL DEFAULT 0,
        raw_hex     TEXT,                    -- crudo: el formato aún no está resuelto
        updated_at  INTEGER NOT NULL
      )
    ''');

    // Instantáneas de batería, útiles para ver el consumo real del anillo.
    await db.execute('''
      CREATE TABLE battery_log (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        taken_at    INTEGER NOT NULL,
        percent     INTEGER NOT NULL,
        state_raw   INTEGER
      )
    ''');
  }

  Future<void> close() => db.close();
}
