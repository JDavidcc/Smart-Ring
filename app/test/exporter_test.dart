import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:smart_ring/data/database.dart';
import 'package:smart_ring/data/exporter.dart';
import 'package:smart_ring/data/models.dart';
import 'package:smart_ring/data/ring_repository.dart';
import 'package:smart_ring/protocol/decoders.dart' as proto;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Ejercita la exportación de punta a punta contra un directorio temporal real.
/// Es una ruta que, hasta ahora, nunca se había ejecutado.
void main() {
  late RingDatabase db;
  late RingRepository repo;
  late DataExporter exporter;
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await RingDatabase.open(path: inMemoryDatabasePath);
    repo = RingRepository(db);
    exporter = DataExporter(repo);
    tmp = await Directory.systemTemp.createTemp('ringtest');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  Future<void> sembrarDatos() async {
    // Valores reales medidos con el anillo el 2026-09-17.
    await repo.saveReading(Reading(
      takenAt: DateTime(2026, 9, 17, 11, 48),
      kind: ReadingKind.heartRate,
      source: ReadingSource.live,
      heartRate: 76,
    ));
    await repo.saveReading(Reading(
      takenAt: DateTime(2026, 9, 17, 11, 51),
      kind: ReadingKind.spo2,
      source: ReadingSource.live,
      spo2: 98,
    ));
    await repo.saveReading(Reading(
      takenAt: DateTime(2026, 9, 17, 11, 53),
      kind: ReadingKind.bloodPressure,
      source: ReadingSource.live,
      systolic: 112,
      diastolic: 73,
      pulseFromBp: 78,
    ));
    await repo.saveActivity(DailyActivity(
      day: DateTime(2026, 9, 17),
      steps: 195,
      distanceMeters: 123,
      calories: 8,
      rawHex: 'C3 00 00 08 00 7B 00 00 00 00 00 00 00 00',
    ));
    await repo.saveSleepNights([
      proto.SleepNight(
        start: proto.tsFromDevice(800000000),
        end: proto.tsFromDevice(800028000),
        segments: [
          proto.SleepSegment(
            stage: proto.SleepStage.deep,
            start: proto.tsFromDevice(800000000),
            durationSeconds: 1800,
          ),
        ],
      ),
    ]);
  }

  Future<Map<String, String>> exportar() async {
    final rutas = await exporter.exportOnly(baseDir: tmp);
    return {for (final r in rutas) p.basename(r): File(r).readAsStringSync()};
  }

  test('genera los cinco CSV y el JSON', () async {
    await sembrarDatos();
    final files = await exportar();
    expect(
      files.keys,
      containsAll([
        'ritmo_cardiaco.csv',
        'oxigeno.csv',
        'presion.csv',
        'actividad.csv',
        'sueno.csv',
        'anillo_completo.json',
      ]),
    );
  });

  test('el CSV de pulso lleva cabecera y el valor real', () async {
    await sembrarDatos();
    final csv = (await exportar())['ritmo_cardiaco.csv']!.trim().split('\n');
    expect(csv.first, 'fecha_hora,bpm,origen');
    expect(csv, hasLength(2));
    expect(csv[1], contains('76'));
    expect(csv[1], contains('live'));
  });

  test('el CSV de presión advierte que es estimada', () async {
    await sembrarDatos();
    final csv = (await exportar())['presion.csv']!;
    expect(csv, contains('No son una medición médica'));
    expect(csv, contains('112,73,78'));
  });

  test('la actividad conserva el hex crudo', () async {
    await sembrarDatos();
    final csv = (await exportar())['actividad.csv']!;
    expect(csv, contains('2026-09-17,195,123,8'));
    expect(csv, contains('C3 00 00 08 00 7B'));
  });

  test('el JSON es válido y contiene todas las secciones', () async {
    await sembrarDatos();
    final json = jsonDecode((await exportar())['anillo_completo.json']!) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(['ritmo_cardiaco', 'oxigeno', 'presion', 'actividad', 'sueno', 'aviso']),
    );
    expect((json['ritmo_cardiaco'] as List).first['bpm'], 76);
    expect((json['oxigeno'] as List).first['spo2_pct'], 98);
    expect((json['presion'] as List).first['sistolica'], 112);
    expect((json['actividad'] as List).first['pasos'], 195);
    expect(((json['sueno'] as List).first['etapas'] as List).first['etapa'], 'deep');
  });

  test('exportar sin datos no falla: produce archivos con solo cabecera', () async {
    // Caso real: el usuario exporta antes de haber medido nada.
    final files = await exportar();
    expect(files, isNotEmpty);
    expect(files['ritmo_cardiaco.csv']!.trim(), 'fecha_hora,bpm,origen');
    final json = jsonDecode(files['anillo_completo.json']!) as Map<String, dynamic>;
    expect(json['ritmo_cardiaco'], isEmpty);
  });

  test('cada exportación va a su propia carpeta', () async {
    await sembrarDatos();
    final a = await exporter.exportOnly(baseDir: tmp);
    final b = await exporter.exportOnly(baseDir: tmp);
    expect(p.dirname(a.first), isNot(p.dirname(b.first)));
  });
}
