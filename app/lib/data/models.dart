/// Modelos de dominio que se guardan en la base local.
library;

enum ReadingKind {
  heartRate('hr', 'Ritmo cardíaco', 'bpm'),
  spo2('spo2', 'Oxígeno en sangre', '%'),
  bloodPressure('bp', 'Presión arterial', 'mmHg');

  const ReadingKind(this.id, this.label, this.unit);
  final String id;
  final String label;
  final String unit;

  static ReadingKind fromId(String id) =>
      ReadingKind.values.firstWhere((k) => k.id == id, orElse: () => ReadingKind.heartRate);
}

enum ReadingSource {
  live('live'),
  history('history');

  const ReadingSource(this.id);
  final String id;
}

class Reading {
  const Reading({
    this.id,
    required this.takenAt,
    required this.kind,
    required this.source,
    this.heartRate,
    this.spo2,
    this.systolic,
    this.diastolic,
    this.pulseFromBp,
  });

  final int? id;
  final DateTime takenAt;
  final ReadingKind kind;
  final ReadingSource source;
  final int? heartRate;
  final int? spo2;
  final int? systolic;
  final int? diastolic;
  final int? pulseFromBp;

  /// Valor principal para graficar. En presión usamos la sistólica.
  double? get primaryValue => switch (kind) {
        ReadingKind.heartRate => heartRate?.toDouble(),
        ReadingKind.spo2 => spo2?.toDouble(),
        ReadingKind.bloodPressure => systolic?.toDouble(),
      };

  String get display => switch (kind) {
        ReadingKind.heartRate => '${heartRate ?? '--'} bpm',
        ReadingKind.spo2 => '${spo2 ?? '--'} %',
        ReadingKind.bloodPressure => '${systolic ?? '--'}/${diastolic ?? '--'} mmHg',
      };

  Map<String, Object?> toRow() => {
        'taken_at': takenAt.millisecondsSinceEpoch,
        'kind': kind.id,
        'heart_rate': heartRate,
        'spo2': spo2,
        'systolic': systolic,
        'diastolic': diastolic,
        'pulse_from_bp': pulseFromBp,
        'source': source.id,
      };

  static Reading fromRow(Map<String, Object?> r) => Reading(
        id: r['id'] as int?,
        takenAt: DateTime.fromMillisecondsSinceEpoch(r['taken_at'] as int),
        kind: ReadingKind.fromId(r['kind'] as String),
        source: (r['source'] as String) == 'history' ? ReadingSource.history : ReadingSource.live,
        heartRate: r['heart_rate'] as int?,
        spo2: r['spo2'] as int?,
        systolic: r['systolic'] as int?,
        diastolic: r['diastolic'] as int?,
        pulseFromBp: r['pulse_from_bp'] as int?,
      );
}

class StoredSleepNight {
  const StoredSleepNight({
    this.id,
    required this.start,
    required this.end,
    required this.segments,
  });

  final int? id;
  final DateTime start;
  final DateTime end;
  final List<StoredSleepSegment> segments;

  Duration get totalInBed => end.difference(start);

  Duration durationOf(String stage) => Duration(
        seconds: segments
            .where((s) => s.stage == stage)
            .fold(0, (sum, s) => sum + s.durationSeconds),
      );

  Duration get asleep => Duration(
        seconds: segments
            .where((s) => s.stage != 'awake')
            .fold(0, (sum, s) => sum + s.durationSeconds),
      );
}

class StoredSleepSegment {
  const StoredSleepSegment({
    required this.stage,
    required this.start,
    required this.durationSeconds,
  });

  final String stage;
  final DateTime start;
  final int durationSeconds;
}

class DailyActivity {
  const DailyActivity({
    required this.day,
    required this.steps,
    required this.distanceMeters,
    required this.calories,
    this.rawHex,
  });

  final DateTime day;
  final int steps;
  final int distanceMeters;
  final int calories;

  /// Crudo del anillo. El formato del contador aún no está resuelto (§8 del
  /// documento de protocolo), así que lo conservamos para poder reinterpretarlo
  /// sin volver a capturar.
  final String? rawHex;
}

class BatterySample {
  const BatterySample({required this.takenAt, required this.percent, this.stateRaw});
  final DateTime takenAt;
  final int percent;
  final int? stateRaw;
}
