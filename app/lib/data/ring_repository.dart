import 'package:sqflite/sqflite.dart';

import '../protocol/decoders.dart' as proto;
import 'database.dart';
import 'models.dart';

/// Acceso a los datos locales. Único punto por el que la UI toca la base.
class RingRepository {
  RingRepository(this._db);

  final RingDatabase _db;
  Database get _raw => _db.db;

  // --- Lecturas -----------------------------------------------------------

  /// Guarda una lectura. Ignora duplicados (mismo instante, métrica y origen),
  /// que es lo que pasa al re-sincronizar el mismo historial dos veces.
  Future<void> saveReading(Reading r) async {
    await _raw.insert(
      'readings',
      r.toRow(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> saveReadings(Iterable<Reading> readings) async {
    final batch = _raw.batch();
    for (final r in readings) {
      batch.insert('readings', r.toRow(), conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Reading>> readings({
    ReadingKind? kind,
    DateTime? from,
    DateTime? to,
    int limit = 500,
  }) async {
    final where = <String>[];
    final args = <Object?>[];
    if (kind != null) {
      where.add('kind = ?');
      args.add(kind.id);
    }
    if (from != null) {
      where.add('taken_at >= ?');
      args.add(from.millisecondsSinceEpoch);
    }
    if (to != null) {
      where.add('taken_at <= ?');
      args.add(to.millisecondsSinceEpoch);
    }
    final rows = await _raw.query(
      'readings',
      where: where.isEmpty ? null : where.join(' AND '),
      whereArgs: args.isEmpty ? null : args,
      orderBy: 'taken_at DESC',
      limit: limit,
    );
    return rows.map(Reading.fromRow).toList();
  }

  Future<Reading?> latest(ReadingKind kind) async {
    final rows = await readings(kind: kind, limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // --- Sueño --------------------------------------------------------------

  /// Guarda las noches decodificadas del anillo, sin duplicar las ya conocidas.
  Future<int> saveSleepNights(List<proto.SleepNight> nights) async {
    var inserted = 0;
    for (final n in nights) {
      final id = await _raw.insert(
        'sleep_nights',
        {
          'start_at': n.start.millisecondsSinceEpoch,
          'end_at': n.end.millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (id == 0) continue; // ya estaba
      inserted++;
      final batch = _raw.batch();
      for (final s in n.segments) {
        batch.insert('sleep_segments', {
          'night_id': id,
          'stage': s.stage?.name ?? 'unknown',
          'start_at': s.start.millisecondsSinceEpoch,
          'duration_s': s.durationSeconds,
        });
      }
      await batch.commit(noResult: true);
    }
    return inserted;
  }

  Future<List<StoredSleepNight>> sleepNights({int limit = 30}) async {
    final nights = await _raw.query('sleep_nights', orderBy: 'start_at DESC', limit: limit);
    final out = <StoredSleepNight>[];
    for (final n in nights) {
      final segs = await _raw.query(
        'sleep_segments',
        where: 'night_id = ?',
        whereArgs: [n['id']],
        orderBy: 'start_at ASC',
      );
      out.add(StoredSleepNight(
        id: n['id'] as int,
        start: DateTime.fromMillisecondsSinceEpoch(n['start_at'] as int),
        end: DateTime.fromMillisecondsSinceEpoch(n['end_at'] as int),
        segments: segs
            .map((s) => StoredSleepSegment(
                  stage: s['stage'] as String,
                  start: DateTime.fromMillisecondsSinceEpoch(s['start_at'] as int),
                  durationSeconds: s['duration_s'] as int,
                ))
            .toList(),
      ));
    }
    return out;
  }

  // --- Actividad ----------------------------------------------------------

  /// Guarda el contador del día. El anillo lo reinicia a medianoche, así que
  /// conservamos el MÁXIMO visto: una caída significa reinicio, no retroceso.
  Future<void> saveActivity(DailyActivity a) async {
    final key = _dayKey(a.day);
    final existing = await _raw.query('activity_daily', where: 'day = ?', whereArgs: [key]);
    final prevSteps = existing.isEmpty ? 0 : existing.first['steps'] as int;
    final prevDist = existing.isEmpty ? 0 : existing.first['distance_m'] as int;
    final prevCal = existing.isEmpty ? 0 : existing.first['calories'] as int;

    await _raw.insert(
      'activity_daily',
      {
        'day': key,
        'steps': a.steps > prevSteps ? a.steps : prevSteps,
        'distance_m': a.distanceMeters > prevDist ? a.distanceMeters : prevDist,
        'calories': a.calories > prevCal ? a.calories : prevCal,
        'raw_hex': a.rawHex,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<DailyActivity>> activity({int days = 30}) async {
    final rows = await _raw.query('activity_daily', orderBy: 'day DESC', limit: days);
    return rows
        .map((r) => DailyActivity(
              day: DateTime.parse(r['day'] as String),
              steps: r['steps'] as int,
              distanceMeters: r['distance_m'] as int,
              calories: r['calories'] as int,
              rawHex: r['raw_hex'] as String?,
            ))
        .toList();
  }

  Future<DailyActivity?> today() async {
    final rows = await _raw.query(
      'activity_daily',
      where: 'day = ?',
      whereArgs: [_dayKey(DateTime.now())],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return DailyActivity(
      day: DateTime.parse(r['day'] as String),
      steps: r['steps'] as int,
      distanceMeters: r['distance_m'] as int,
      calories: r['calories'] as int,
      rawHex: r['raw_hex'] as String?,
    );
  }

  // --- Batería ------------------------------------------------------------

  Future<void> saveBattery(BatterySample s) async {
    await _raw.insert('battery_log', {
      'taken_at': s.takenAt.millisecondsSinceEpoch,
      'percent': s.percent,
      'state_raw': s.stateRaw,
    });
  }

  Future<BatterySample?> latestBattery() async {
    final rows = await _raw.query('battery_log', orderBy: 'taken_at DESC', limit: 1);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return BatterySample(
      takenAt: DateTime.fromMillisecondsSinceEpoch(r['taken_at'] as int),
      percent: r['percent'] as int,
      stateRaw: r['state_raw'] as int?,
    );
  }

  static String _dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
