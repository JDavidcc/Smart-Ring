import 'dart:typed_data';

import 'commands.dart';
import 'frame.dart';

/// Decodificadores de payload. Puerto de `tools/ringlab/ringlab/decoders.py`.
///
/// Lo VERIFICADO contra el anillo real y lo que sigue siendo HIPOTESIS esta
/// marcado aqui y detallado en `docs/PROTOCOLO-R21M.md`.

/// El anillo cuenta segundos desde 2000-01-01. HIPOTESIS heredada del R11M:
/// no se ha podido confirmar porque el anillo aun no tiene historial.
final DateTime epoch2000 = DateTime.utc(2000, 1, 1);

DateTime tsFromDevice(int seconds) => epoch2000.add(Duration(seconds: seconds));

int u16(List<int> b, [int off = 0]) => b[off] | (b[off + 1] << 8);
int u24(List<int> b, [int off = 0]) => b[off] | (b[off + 1] << 8) | (b[off + 2] << 16);
int u32(List<int> b, [int off = 0]) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

// --- Advertisement ---------------------------------------------------------

/// Firma del advertisement del R21M. VERIFICADO contra `lecturas-ble/` y en vivo.
const int yuchengCompanyId = 0x7810;
const int yuchengMfrLen = 27;

class RingAdvertisement {
  const RingAdvertisement({this.name, this.serviceUuids16 = const [], this.companyId, this.mac, this.batteryPct});

  final String? name;
  final List<int> serviceUuids16;
  final int? companyId;
  final String? mac;

  /// Bateria en %, legible SIN conectarse. VERIFICADO: coincide con el byte 5
  /// de la respuesta a `02 00`, obtenido por un camino independiente.
  final int? batteryPct;

  bool get isRing => companyId == yuchengCompanyId;
}

/// Decodifica el manufacturer data del anillo (lo que expone flutter_blue_plus
/// ya parseado, sin el company id).
RingAdvertisement decodeManufacturerData(int companyId, List<int> md, {String? name}) {
  if (companyId != yuchengCompanyId || md.length != yuchengMfrLen) {
    // Fuera de esa firma las posiciones no significan nada: no inventamos valores.
    return RingAdvertisement(name: name, companyId: companyId);
  }
  final mac = md
      .sublist(md.length - 6)
      .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(':');
  return RingAdvertisement(name: name, companyId: companyId, mac: mac, batteryPct: md[18]);
}

// --- Info del dispositivo --------------------------------------------------

/// Byte 4 de la respuesta `02 00`.
///
/// La doc del R11M lo describe como estado del cargador (00 = fuera, 01 =
/// cargando). En este anillo **NO lo es**: vale `0x02` de forma constante, tanto
/// con el anillo cargando como fuera del cargador (verificado con dos lecturas
/// byte a byte idénticas separadas 3½ horas). Su significado real se desconoce.
const Map<int, String> batteryStateNames = {
  0x00: 'Fuera del cargador',
  0x01: 'Cargando',
};

class DeviceInfo {
  const DeviceInfo({required this.batteryPct, required this.batteryStateRaw, required this.raw});

  final int batteryPct;
  final int batteryStateRaw;
  final Uint8List raw;

  /// Etiqueta para el usuario, o `null` si el valor no significa nada conocido.
  /// La UI debe omitirla en ese caso en vez de mostrar ruido de depuración.
  String? get batteryStateLabel => batteryStateNames[batteryStateRaw];

  /// Siempre con el valor crudo: para la consola de depuración.
  String get batteryState =>
      batteryStateLabel ??
      'Sin documentar (0x${batteryStateRaw.toRadixString(16).padLeft(2, '0').toUpperCase()})';

  /// Solo afirmamos "cargando" cuando el valor esta documentado. `0x02` -> null.
  bool? get isCharging => switch (batteryStateRaw) { 0x00 => false, 0x01 => true, _ => null };
}

DeviceInfo? decodeDeviceInfo(Uint8List payload) {
  if (payload.length <= 5) return null;
  return DeviceInfo(batteryPct: payload[5], batteryStateRaw: payload[4], raw: payload);
}

// --- Medicion en vivo ------------------------------------------------------

class LiveReading {
  const LiveReading({this.heartRate, this.spo2, this.systolic, this.diastolic, this.pulseFromBp});

  final int? heartRate;
  final int? spo2;
  final int? systolic;
  final int? diastolic;

  /// Tercer byte de `06 03`. La doc del R11M lo marca como desconocido; en
  /// nuestras capturas vale 78-80 con un pulso real de 75-76. HIPOTESIS.
  final int? pulseFromBp;
}

LiveReading? decodeLive(int code, Uint8List p) {
  if (p.isEmpty) return null;
  return switch (code) {
    evtLiveHeart => LiveReading(heartRate: p[0]),
    evtLiveSpo2 => LiveReading(spo2: p[0]),
    evtLiveBlood => p.length >= 2
        ? LiveReading(
            systolic: p[0],
            diastolic: p[1],
            pulseFromBp: p.length >= 3 ? p[2] : null,
          )
        : null,
    _ => null,
  };
}

/// Resultado del evento `04 0E`.
class MeasureResult {
  const MeasureResult({required this.type, required this.resultRaw});

  final MeasureType? type;
  final int resultRaw;

  /// VERIFICADO: 0x01 llega tras una medicion buena en los tres tipos.
  bool get succeeded => resultRaw == 0x01;

  /// HIPOTESIS del R11M: 0x02 = anillo no puesto. No se ha provocado aun.
  bool get notWorn => resultRaw == 0x02;

  String get message => switch (resultRaw) {
        0x01 => 'Medición completada',
        0x02 => 'El anillo no está puesto',
        _ => 'Resultado sin documentar (0x${resultRaw.toRadixString(16).padLeft(2, '0')})',
      };
}

MeasureResult? decodeMeasureDone(Uint8List p) =>
    p.length >= 2 ? MeasureResult(type: MeasureType.fromId(p[0]), resultRaw: p[1]) : null;

// --- Registros almacenados (HIPOTESIS: sin datos reales todavia) ------------

class StoredReading {
  const StoredReading({
    required this.at,
    this.heartRate,
    this.spo2,
    this.systolic,
    this.diastolic,
  });

  final DateTime at;
  final int? heartRate;
  final int? spo2;
  final int? systolic;
  final int? diastolic;
}

StoredReading? decodeStored(int code, Uint8List p) => switch (code) {
      evtStoredHeart when p.length >= 6 =>
        StoredReading(at: tsFromDevice(u32(p)), heartRate: p[5]),
      evtStoredBlood when p.length >= 7 =>
        StoredReading(at: tsFromDevice(u32(p)), systolic: p[5], diastolic: p[6]),
      evtStoredSpo2 when p.length >= 9 => StoredReading(at: tsFromDevice(u32(p)), spo2: p[8]),
      _ => null,
    };

// --- Sueno (HIPOTESIS: sin datos reales todavia) ---------------------------

enum SleepStage {
  deep(0xF1, 'Profundo'),
  light(0xF2, 'Ligero'),
  rem(0xF3, 'REM'),
  awake(0xF4, 'Despierto');

  const SleepStage(this.id, this.label);
  final int id;
  final String label;

  static SleepStage? fromId(int id) {
    for (final s in SleepStage.values) {
      if (s.id == id) return s;
    }
    return null;
  }
}

class SleepSegment {
  const SleepSegment({required this.stage, required this.start, required this.durationSeconds});
  final SleepStage? stage;
  final DateTime start;
  final int durationSeconds;
}

class SleepNight {
  const SleepNight({required this.start, required this.end, required this.segments});
  final DateTime start;
  final DateTime end;
  final List<SleepSegment> segments;
}

/// Decodifica un blob de sueno ya reensamblado (todos los pushes `05 13` juntos).
/// Cabecera de 20 bytes por noche que empieza con AF FA, luego entradas de 8 bytes.
List<SleepNight> decodeSleep(Uint8List blob) {
  final nights = <SleepNight>[];
  var i = 0;
  while (i + 20 <= blob.length) {
    if (!(blob[i] == 0xAF && blob[i + 1] == 0xFA)) {
      i++;
      continue;
    }
    final size = u16(blob, i + 2);
    if (size < 20 || i + size > blob.length) break;
    final rec = blob.sublist(i, i + size);
    final segments = <SleepSegment>[];
    for (var off = 20; off + 8 <= size; off += 8) {
      segments.add(SleepSegment(
        stage: SleepStage.fromId(rec[off]),
        start: tsFromDevice(u32(rec, off + 1)),
        durationSeconds: u24(rec, off + 5),
      ));
    }
    nights.add(SleepNight(
      start: tsFromDevice(u32(rec, 4)),
      end: tsFromDevice(u32(rec, 8)),
      segments: segments,
    ));
    i += size;
  }
  return nights;
}

// --- Actividad -------------------------------------------------------------

/// Contador de actividad de `02 0C`. VERIFICADO.
///
///     [pasos u24 LE][calorías u16 LE][distancia_m u24 LE][6 bytes en cero]
///
/// Resuelto con dos lecturas reales separadas por ~100 pasos caminados. La
/// prueba no fue que un campo se pareciera a lo caminado, sino que la razón
/// distancia/pasos se mantiene constante (0.634 y 0.631): la distancia se
/// deriva de los pasos con una zancada de ~0.635 m.
///
/// La doc del R11M acertó la posición de los pasos pero invirtió distancia y
/// calorías. Ver §8 de `docs/PROTOCOLO-R21M.md`.
///
/// OJO: `fea1` NO empuja estos datos pese a lo que dice la doc del R11M. Hay
/// que consultar `02 0C` activamente.
class ActivityCounters {
  const ActivityCounters(this.raw);

  final Uint8List raw;

  bool get isValid => raw.length >= 8;

  bool get isAllZero => raw.every((b) => b == 0);

  int get steps => isValid ? u24(raw, 0) : 0;
  int get calories => isValid ? u16(raw, 3) : 0;
  int get distanceMeters => isValid ? u24(raw, 5) : 0;

  /// Zancada implícita que usa el anillo, en metros. Útil para detectar que el
  /// formato se rompió: si sale fuera de un rango humano, algo cambió.
  double? get strideMeters => steps > 0 ? distanceMeters / steps : null;
}

// --- Heart Rate estandar 0x2A37 -------------------------------------------

class StandardHrm {
  const StandardHrm({required this.bpm, required this.contactSupported, required this.contactDetected});
  final int bpm;
  final bool contactSupported;
  final bool contactDetected;
}

/// VERIFICADO que esta caracteristica NO sirve como fuente: reemite el ultimo
/// valor indefinidamente y reporta "sin contacto" incluso durante una medicion
/// real y exitosa. Se decodifica solo para la consola de depuracion.
StandardHrm? decodeStandardHrm(List<int> data) {
  if (data.length < 2) return null;
  final flags = data[0];
  final wide = (flags & 0x01) != 0;
  return StandardHrm(
    bpm: wide ? u16(data, 1) : data[1],
    contactSupported: (flags & 0x04) != 0,
    contactDetected: (flags & 0x02) != 0,
  );
}

/// Etiqueta legible para la consola de depuracion.
String describeFrame(Frame f) => '${commandName(f.code)} <${hexOf(f.payload)}>';
