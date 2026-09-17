import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ring/data/database.dart';
import 'package:smart_ring/data/models.dart';
import 'package:smart_ring/data/ring_repository.dart';
import 'package:smart_ring/protocol/decoders.dart' as proto;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Pruebas de la lógica de persistencia sobre una base en memoria.
///
/// Cubre sobre todo las reglas que NO son obvias y que vienen de cómo se
/// comporta el anillo de verdad: el contador de pasos que se reinicia a
/// medianoche y la re-sincronización del mismo historial.
void main() {
  late RingDatabase db;
  late RingRepository repo;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    db = await RingDatabase.open(path: inMemoryDatabasePath);
    repo = RingRepository(db);
  });

  tearDown(() async => db.close());

  group('Lecturas', () {
    test('guarda y recupera por métrica', () async {
      final t = DateTime(2026, 9, 17, 11, 48);
      await repo.saveReading(Reading(
        takenAt: t,
        kind: ReadingKind.heartRate,
        source: ReadingSource.live,
        heartRate: 76,
      ));
      await repo.saveReading(Reading(
        takenAt: t,
        kind: ReadingKind.spo2,
        source: ReadingSource.live,
        spo2: 98,
      ));

      final hr = await repo.readings(kind: ReadingKind.heartRate);
      expect(hr, hasLength(1));
      expect(hr.first.heartRate, 76);
      expect(hr.first.display, '76 bpm');

      final spo2 = await repo.latest(ReadingKind.spo2);
      expect(spo2!.spo2, 98);
    });

    test('re-sincronizar el mismo historial no duplica', () async {
      // Caso real: el anillo reenvía los mismos registros en cada consulta.
      final lote = List.generate(
        5,
        (i) => Reading(
          takenAt: DateTime(2026, 9, 17, 10, i),
          kind: ReadingKind.heartRate,
          source: ReadingSource.history,
          heartRate: 70 + i,
        ),
      );
      await repo.saveReadings(lote);
      await repo.saveReadings(lote);
      await repo.saveReadings(lote);

      expect(await repo.readings(kind: ReadingKind.heartRate), hasLength(5));
    });

    test('una lectura en vivo y una del historial al mismo instante coexisten', () async {
      final t = DateTime(2026, 9, 17, 11, 0);
      await repo.saveReading(Reading(
        takenAt: t, kind: ReadingKind.heartRate, source: ReadingSource.live, heartRate: 76));
      await repo.saveReading(Reading(
        takenAt: t, kind: ReadingKind.heartRate, source: ReadingSource.history, heartRate: 76));

      expect(await repo.readings(kind: ReadingKind.heartRate), hasLength(2));
    });

    test('filtra por rango de fechas', () async {
      for (var d = 10; d <= 20; d++) {
        await repo.saveReading(Reading(
          takenAt: DateTime(2026, 9, d),
          kind: ReadingKind.heartRate,
          source: ReadingSource.history,
          heartRate: 60 + d,
        ));
      }
      final r = await repo.readings(
        kind: ReadingKind.heartRate,
        from: DateTime(2026, 9, 15),
        to: DateTime(2026, 9, 17, 23, 59),
      );
      expect(r, hasLength(3));
    });

    test('devuelve la más reciente primero', () async {
      await repo.saveReading(Reading(
        takenAt: DateTime(2026, 9, 17, 8), kind: ReadingKind.heartRate,
        source: ReadingSource.history, heartRate: 60));
      await repo.saveReading(Reading(
        takenAt: DateTime(2026, 9, 17, 20), kind: ReadingKind.heartRate,
        source: ReadingSource.history, heartRate: 90));

      expect((await repo.latest(ReadingKind.heartRate))!.heartRate, 90);
    });
  });

  group('Actividad: el contador se reinicia a medianoche', () {
    test('un valor mayor actualiza', () async {
      final hoy = DateTime(2026, 9, 17, 9);
      await repo.saveActivity(DailyActivity(
        day: hoy, steps: 1200, distanceMeters: 800, calories: 45));
      await repo.saveActivity(DailyActivity(
        day: hoy, steps: 3400, distanceMeters: 2300, calories: 120));

      final a = (await repo.activity()).first;
      expect(a.steps, 3400);
      expect(a.distanceMeters, 2300);
    });

    test('una CAÍDA no borra el máximo del día', () async {
      // Esto es lo que pasa cuando el anillo se reinicia o pierde el contador:
      // sin esta regla, el día se quedaría en 0 pasos.
      final hoy = DateTime(2026, 9, 17, 9);
      await repo.saveActivity(DailyActivity(
        day: hoy, steps: 8000, distanceMeters: 5000, calories: 300));
      await repo.saveActivity(DailyActivity(
        day: hoy, steps: 12, distanceMeters: 8, calories: 1));

      final a = (await repo.activity()).first;
      expect(a.steps, 8000, reason: 'una caída es un reinicio, no un retroceso');
      expect(a.distanceMeters, 5000);
      expect(a.calories, 300);
    });

    test('días distintos se cuentan por separado', () async {
      await repo.saveActivity(DailyActivity(
        day: DateTime(2026, 9, 16), steps: 9000, distanceMeters: 6000, calories: 350));
      await repo.saveActivity(DailyActivity(
        day: DateTime(2026, 9, 17), steps: 300, distanceMeters: 200, calories: 12));

      final dias = await repo.activity();
      expect(dias, hasLength(2));
      expect(dias.first.steps, 300, reason: 'el más reciente va primero');
      expect(dias.last.steps, 9000);
    });

    test('conserva el hex crudo para poder reinterpretarlo', () async {
      // El formato del contador aún no está resuelto: el crudo es la red de
      // seguridad para recalcular sin volver a capturar.
      await repo.saveActivity(DailyActivity(
        day: DateTime(2026, 9, 17),
        steps: 0,
        distanceMeters: 0,
        calories: 0,
        rawHex: '2C 01 00 58 02 00 2D 00',
      ));
      expect((await repo.activity()).first.rawHex, '2C 01 00 58 02 00 2D 00');
    });
  });

  group('Sueño', () {
    proto.SleepNight noche(int startSec, int endSec) => proto.SleepNight(
          start: proto.tsFromDevice(startSec),
          end: proto.tsFromDevice(endSec),
          segments: [
            proto.SleepSegment(
              stage: proto.SleepStage.deep,
              start: proto.tsFromDevice(startSec),
              durationSeconds: 1800,
            ),
            proto.SleepSegment(
              stage: proto.SleepStage.light,
              start: proto.tsFromDevice(startSec + 1800),
              durationSeconds: 3600,
            ),
            proto.SleepSegment(
              stage: proto.SleepStage.awake,
              start: proto.tsFromDevice(startSec + 5400),
              durationSeconds: 600,
            ),
          ],
        );

    test('guarda una noche con sus etapas', () async {
      expect(await repo.saveSleepNights([noche(800000000, 800028000)]), 1);

      final noches = await repo.sleepNights();
      expect(noches, hasLength(1));
      expect(noches.first.segments, hasLength(3));
      expect(noches.first.durationOf('deep'), const Duration(minutes: 30));
      expect(noches.first.durationOf('light'), const Duration(hours: 1));
      expect(noches.first.durationOf('awake'), const Duration(minutes: 10));
    });

    test('el tiempo dormido excluye lo despierto', () async {
      await repo.saveSleepNights([noche(800000000, 800028000)]);
      final n = (await repo.sleepNights()).first;
      expect(n.asleep, const Duration(minutes: 90));
    });

    test('re-sincronizar la misma noche no la duplica', () async {
      final n = noche(800000000, 800028000);
      expect(await repo.saveSleepNights([n]), 1);
      expect(await repo.saveSleepNights([n]), 0, reason: 'ya estaba guardada');
      expect(await repo.sleepNights(), hasLength(1));

      // Y tampoco debe duplicar las etapas de la noche ya conocida.
      expect((await repo.sleepNights()).first.segments, hasLength(3));
    });
  });

  group('Batería', () {
    test('guarda instantáneas y devuelve la última', () async {
      await repo.saveBattery(BatterySample(
        takenAt: DateTime(2026, 9, 17, 10), percent: 100, stateRaw: 0x02));
      await repo.saveBattery(BatterySample(
        takenAt: DateTime(2026, 9, 17, 18), percent: 94, stateRaw: 0x00));

      final b = await repo.latestBattery();
      expect(b!.percent, 94);
      expect(b.stateRaw, 0x00);
    });
  });
}
