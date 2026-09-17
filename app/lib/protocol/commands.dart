import 'dart:typed_data';

import 'frame.dart';

/// Catalogo de comandos. Puerto de `tools/ringlab/ringlab/commands.py`.
///
/// El estado de verificacion de cada comando esta en `docs/PROTOCOLO-R21M.md`.

// --- App -> anillo ---------------------------------------------------------

const int cmdSetTime = 0x0100; // VERIFICADO
const int cmdSettingHeartMonitor = 0x010C;
const int cmdSettingSpo2Monitor = 0x0126;

const int cmdGetDeviceInfo = 0x0200; // VERIFICADO
const int cmdGetNowStep = 0x020C; // VERIFICADO (responde; formato sin resolver)

const int cmdStartMeasurement = 0x032F; // VERIFICADO los 3 tipos

const int cmdHistorySport = 0x0502;
const int cmdHistorySleep = 0x0504; // VERIFICADO que es aceptado
const int cmdHistoryHeart = 0x0506; // VERIFICADO que es aceptado
const int cmdHistoryBlood = 0x0508;
const int cmdHistorySpo2 = 0x0509;

// --- Anillo -> app ---------------------------------------------------------

const int evtMeasureDone = 0x040E; // VERIFICADO

const int evtStoredSleep = 0x0513;
const int evtStoredHeart = 0x0515;
const int evtStoredBlood = 0x0517;
const int evtStoredSpo2 = 0x0518;

const int evtLiveHeart = 0x0601; // VERIFICADO
const int evtLiveSpo2 = 0x0602; // VERIFICADO
const int evtLiveBlood = 0x0603; // VERIFICADO

/// Respuestas de una sola palabra observadas en el anillo.
const int ackOk = 0x00;
const int ackRejected = 0xFE;

const Map<int, String> commandNames = {
  cmdSetTime: 'SettingTime',
  cmdSettingHeartMonitor: 'SettingHeartMonitor',
  cmdSettingSpo2Monitor: 'SettingSpo2Monitor',
  cmdGetDeviceInfo: 'GetDeviceInfo',
  cmdGetNowStep: 'GetNowStep',
  cmdStartMeasurement: 'AppStartMeasurement',
  cmdHistorySport: 'Health_HistorySport',
  cmdHistorySleep: 'Health_HistorySleep',
  cmdHistoryHeart: 'Health_HistoryHeart',
  cmdHistoryBlood: 'Health_HistoryBlood',
  cmdHistorySpo2: 'Health_HistorySpo2',
  evtMeasureDone: 'MeasureComplete',
  evtStoredSleep: 'StoredSleepChunk',
  evtStoredHeart: 'StoredHeartRecord',
  evtStoredBlood: 'StoredBloodRecord',
  evtStoredSpo2: 'StoredSpo2Record',
  evtLiveHeart: 'Real_UploadHeart',
  evtLiveSpo2: 'Real_UploadBloodOxygen',
  evtLiveBlood: 'Real_UploadBlood',
};

String commandName(int code) =>
    commandNames[code] ?? 'desconocido_${code.toRadixString(16).padLeft(4, '0').toUpperCase()}';

enum MeasureType {
  heart(0x00, 'Ritmo cardíaco'),
  bloodPressure(0x01, 'Presión arterial'),
  spo2(0x02, 'Oxígeno en sangre');

  const MeasureType(this.id, this.label);
  final int id;
  final String label;

  static MeasureType? fromId(int id) {
    for (final t in MeasureType.values) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Margen antes de considerar que una medición falló, con holgura sobre los
  /// tiempos medidos en el anillo real (§6 de docs/PROTOCOLO-R21M.md).
  Duration get expectedDuration => switch (this) {
        MeasureType.heart => const Duration(seconds: 90),
        MeasureType.bloodPressure => const Duration(seconds: 90),
        MeasureType.spo2 => const Duration(seconds: 120),
      };
}

Uint8List frameOf(int code, [List<int> payload = const []]) =>
    buildFrame(code >> 8, code & 0xFF, payload);

// --- Constructores ---------------------------------------------------------

/// `01 00` + `[año u16 LE][mes][día][h][m][s][00]`.
///
/// Hay que llamarlo en cada conexión: el RTC del anillo no avanza solo y los
/// registros heredan la última hora escrita.
Uint8List setTime(DateTime when) => frameOf(cmdSetTime, [
      when.year & 0xFF,
      (when.year >> 8) & 0xFF,
      when.month,
      when.day,
      when.hour,
      when.minute,
      when.second,
      0x00,
    ]);

/// `02 00` con payload ASCII "GC".
Uint8List getDeviceInfo() => frameOf(cmdGetDeviceInfo, [0x47, 0x43]);

Uint8List getNowStep() => frameOf(cmdGetNowStep);

Uint8List startMeasurement(MeasureType kind) => frameOf(cmdStartMeasurement, [0x01, kind.id]);

Uint8List stopMeasurement() => frameOf(cmdStartMeasurement, [0x00, 0x00]);

Uint8List setHeartMonitor({required bool enabled, required int minutes}) =>
    frameOf(cmdSettingHeartMonitor, [enabled ? 1 : 0, minutes & 0xFF]);

Uint8List setSpo2Monitor({required bool enabled, required int minutes}) =>
    frameOf(cmdSettingSpo2Monitor, [enabled ? 1 : 0, minutes & 0xFF]);

Uint8List queryHistory(int code) => frameOf(code);
