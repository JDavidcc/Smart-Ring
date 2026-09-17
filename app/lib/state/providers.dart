import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ble/ring_connection.dart';
import '../ble/ring_scanner.dart';
import '../data/database.dart';
import '../data/exporter.dart';
import '../data/models.dart';
import '../data/ring_repository.dart';
import '../protocol/commands.dart';
import '../protocol/decoders.dart';
import '../protocol/frame.dart';

// --- Datos locales ----------------------------------------------------------

final databaseProvider = FutureProvider<RingDatabase>((ref) async {
  final db = await RingDatabase.open();
  ref.onDispose(db.close);
  return db;
});

final repositoryProvider = FutureProvider<RingRepository>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  return RingRepository(db);
});

final exporterProvider = FutureProvider<DataExporter>((ref) async {
  return DataExporter(await ref.watch(repositoryProvider.future));
});

// --- Escaneo ----------------------------------------------------------------

final scanProvider = StreamProvider.autoDispose<List<DiscoveredRing>>((ref) {
  ref.onDispose(RingScanner.stop);
  return RingScanner.scan();
});

// --- Conexión ---------------------------------------------------------------

enum ConnectionStatus { disconnected, connecting, connected, error }

class RingState {
  const RingState({
    this.status = ConnectionStatus.disconnected,
    this.deviceId,
    this.deviceName,
    this.info,
    this.infoReadAt,
    this.mtu = 0,
    this.error,
  });

  final ConnectionStatus status;
  final String? deviceId;
  final String? deviceName;
  final DeviceInfo? info;

  /// Cuándo se leyó [info] del anillo. Sin esto no se puede saber si lo que se
  /// ve en pantalla es fresco o un valor viejo que sobrevivió a un fallo.
  final DateTime? infoReadAt;

  final int mtu;
  final String? error;

  bool get isConnected => status == ConnectionStatus.connected;

  RingState copyWith({
    ConnectionStatus? status,
    String? deviceId,
    String? deviceName,
    DeviceInfo? info,
    DateTime? infoReadAt,
    int? mtu,
    String? error,
  }) =>
      RingState(
        status: status ?? this.status,
        deviceId: deviceId ?? this.deviceId,
        deviceName: deviceName ?? this.deviceName,
        info: info ?? this.info,
        infoReadAt: infoReadAt ?? this.infoReadAt,
        mtu: mtu ?? this.mtu,
        error: error,
      );
}

class RingController extends Notifier<RingState> {
  RingConnection? _connection;
  StreamSubscription<LiveReading>? _liveSub;
  StreamSubscription<ActivityCounters>? _activitySub;
  StreamSubscription<Frame>? _doneSub;
  StreamSubscription<TraceEntry>? _traceSub;

  static const _prefsKey = 'ultimo_anillo';

  @override
  RingState build() {
    ref.onDispose(() {
      _liveSub?.cancel();
      _activitySub?.cancel();
      _doneSub?.cancel();
      _traceSub?.cancel();
      _connection?.dispose();
    });
    return const RingState();
  }

  RingConnection? get connection => _connection;

  /// Reconecta con el último anillo usado, si lo hay.
  Future<void> reconnectLast() async {
    final prefs = await SharedPreferences.getInstance();
    final id = prefs.getString(_prefsKey);
    if (id != null) await connect(id, null);
  }

  Future<void> connect(String deviceId, String? name) async {
    if (state.status == ConnectionStatus.connecting) return;
    state = state.copyWith(status: ConnectionStatus.connecting, deviceId: deviceId, deviceName: name);

    final conn = RingConnection(deviceId);
    try {
      await RingScanner.stop();
      await conn.connect();
      _connection = conn;

      final info = await conn.readDeviceInfo();
      if (info != null) {
        final repo = await ref.read(repositoryProvider.future);
        await repo.saveBattery(BatterySample(
          takenAt: DateTime.now(),
          percent: info.batteryPct,
          stateRaw: info.batteryStateRaw,
        ));
      }

      _listenForData(conn);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, deviceId);

      state = state.copyWith(
        status: ConnectionStatus.connected,
        info: info,
        infoReadAt: DateTime.now(),
        mtu: conn.mtu,
      );
    } catch (e) {
      await conn.dispose();
      _connection = null;
      state = RingState(
        status: ConnectionStatus.error,
        deviceId: deviceId,
        deviceName: name,
        error: _friendlyError(e),
      );
    }
  }

  /// Lecturas en vivo aún sin confirmar, por tipo de medición.
  ///
  /// NO se guardan al vuelo. El anillo emite `06 01` con valores plausibles
  /// incluso estando en la mesa, y solo después manda `04 0E` con resultado 02
  /// ("no puesto"). Verificado: midiendo con el anillo quitado llegaron tres
  /// lecturas de 75 bpm antes del rechazo. Guardarlas sería meter datos falsos
  /// en el historial del usuario.
  final Map<MeasureType, LiveReading> _pending = {};

  /// Registro de tramas que sobrevive a la navegación entre pantallas.
  ///
  /// La consola de depuración se suscribía al abrirse y perdía todo al salir,
  /// así que era imposible refrescar en otra pantalla y volver a leer el
  /// resultado. Ahora el buffer vive aquí, mientras dure la conexión.
  final List<TraceEntry> traceHistory = [];
  static const _traceLimit = 3000;

  void _listenForData(RingConnection conn) {
    _traceSub = conn.trace.listen((e) {
      traceHistory.add(e);
      if (traceHistory.length > _traceLimit) {
        traceHistory.removeRange(0, traceHistory.length - _traceLimit);
      }
    });

    _liveSub = conn.liveReadings.listen((r) {
      final type = _typeOf(r);
      if (type != null) _pending[type] = r;
    });

    // La confirmación es lo único que autoriza a persistir.
    _doneSub = conn.frames.where((f) => f.code == evtMeasureDone).listen((f) async {
      final result = decodeMeasureDone(f.payload);
      final type = result?.type;
      final reading = type == null ? null : _pending.remove(type);
      if (result == null || !result.succeeded || reading == null) return;
      await _commit(type!, reading);
    });

    _activitySub = conn.activityCounters.listen(_saveActivity);
  }

  static MeasureType? _typeOf(LiveReading r) {
    if (r.heartRate != null) return MeasureType.heart;
    if (r.spo2 != null) return MeasureType.spo2;
    if (r.systolic != null) return MeasureType.bloodPressure;
    return null;
  }

  /// Persiste una sola lectura por medición confirmada: el valor final. Guardar
  /// también los intermedios llenaría el historial de ruido.
  Future<void> _commit(MeasureType type, LiveReading r) async {
    final repo = await ref.read(repositoryProvider.future);
    final now = DateTime.now();
    await repo.saveReading(switch (type) {
      MeasureType.heart => Reading(
          takenAt: now,
          kind: ReadingKind.heartRate,
          source: ReadingSource.live,
          heartRate: r.heartRate,
        ),
      MeasureType.spo2 => Reading(
          takenAt: now,
          kind: ReadingKind.spo2,
          source: ReadingSource.live,
          spo2: r.spo2,
        ),
      MeasureType.bloodPressure => Reading(
          takenAt: now,
          kind: ReadingKind.bloodPressure,
          source: ReadingSource.live,
          systolic: r.systolic,
          diastolic: r.diastolic,
          pulseFromBp: r.pulseFromBp,
        ),
    });
  }

  Future<void> _saveActivity(ActivityCounters a) async {
    if (!a.isValid || a.isAllZero) return;
    final repo = await ref.read(repositoryProvider.future);
    await repo.saveActivity(DailyActivity(
      day: DateTime.now(),
      steps: a.steps,
      distanceMeters: a.distanceMeters,
      calories: a.calories,
      // Seguimos guardando el crudo: es barato y deja reinterpretar sin recapturar.
      rawHex: a.raw.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ').toUpperCase(),
    ));
  }

  /// Lee el contador de actividad del anillo y lo guarda.
  ///
  /// Hay que llamarlo activamente: `fea1` no empuja nada en este modelo.
  Future<ActivityCounters?> refreshActivity() async {
    final conn = _connection;
    if (conn == null) return null;
    final a = await conn.readActivity();
    await _saveActivity(a);
    return a;
  }

  /// Relee la información del anillo. Lanza si falla.
  ///
  /// Antes se tragaba los errores y dejaba el valor anterior en pantalla, lo que
  /// hacía indistinguible "el dato no cambió" de "no se pudo leer" — y eso
  /// invalida cualquier observación hecha sobre la pantalla.
  Future<DeviceInfo?> refreshInfo() async {
    final conn = _connection;
    if (conn == null) throw StateError('Sin conexión con el anillo');
    final info = await conn.readDeviceInfo();
    if (info != null) {
      state = state.copyWith(info: info, infoReadAt: DateTime.now());
      final repo = await ref.read(repositoryProvider.future);
      await repo.saveBattery(BatterySample(
        takenAt: DateTime.now(),
        percent: info.batteryPct,
        stateRaw: info.batteryStateRaw,
      ));
    }
    return info;
  }

  /// Descarga el historial almacenado y lo guarda localmente.
  /// Devuelve cuántos registros nuevos entraron.
  Future<int> syncHistory() async {
    final conn = _connection;
    if (conn == null) return 0;
    final repo = await ref.read(repositoryProvider.future);
    var nuevos = 0;

    for (final (code, kind) in [
      (cmdHistoryHeart, ReadingKind.heartRate),
      (cmdHistoryBlood, ReadingKind.bloodPressure),
      (cmdHistorySpo2, ReadingKind.spo2),
    ]) {
      final frames = await conn.fetchHistory(code);
      final lecturas = <Reading>[];
      for (final f in frames) {
        final s = decodeStored(f.code, f.payload);
        if (s == null) continue;
        lecturas.add(Reading(
          takenAt: s.at,
          kind: kind,
          source: ReadingSource.history,
          heartRate: s.heartRate,
          spo2: s.spo2,
          systolic: s.systolic,
          diastolic: s.diastolic,
        ));
      }
      await repo.saveReadings(lecturas);
      nuevos += lecturas.length;
    }

    // Sueño: los bloques 05 13 hay que concatenarlos antes de decodificar.
    final sleepFrames = await conn.fetchHistory(cmdHistorySleep);
    final blob = <int>[];
    for (final f in sleepFrames) {
      if (f.code == evtStoredSleep) blob.addAll(f.payload);
    }
    if (blob.isNotEmpty) {
      final nights = decodeSleep(Uint8List.fromList(blob));
      nuevos += await repo.saveSleepNights(nights);
    }

    return nuevos;
  }

  Future<void> disconnect() async {
    await _liveSub?.cancel();
    await _activitySub?.cancel();
    await _doneSub?.cancel();
    await _traceSub?.cancel();
    _liveSub = null;
    _activitySub = null;
    _doneSub = null;
    _traceSub = null;
    _pending.clear();
    traceHistory.clear();
    await _connection?.dispose();
    _connection = null;
    state = const RingState();
  }

  static String _friendlyError(Object e) {
    final s = e.toString();
    if (s.contains('be940001')) return s;
    return 'No se pudo conectar. Comprueba que el anillo esté cerca y que la app '
        'SmartHealth no lo tenga tomado: solo acepta una conexión a la vez.\n\n$s';
  }

}

final ringControllerProvider = NotifierProvider<RingController, RingState>(
  RingController.new,
);

/// Atajo para que la UI acceda a la conexión activa.
final connectionProvider = Provider<RingConnection?>((ref) {
  ref.watch(ringControllerProvider);
  return ref.read(ringControllerProvider.notifier).connection;
});

// --- Consultas para la UI ---------------------------------------------------

final latestReadingProvider =
    FutureProvider.family.autoDispose<Reading?, ReadingKind>((ref, kind) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.latest(kind);
});

final readingsProvider =
    FutureProvider.family.autoDispose<List<Reading>, ReadingKind>((ref, kind) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.readings(kind: kind, limit: 300);
});

final sleepNightsProvider = FutureProvider.autoDispose<List<StoredSleepNight>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.sleepNights();
});

final todayActivityProvider = FutureProvider.autoDispose<DailyActivity?>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.today();
});

final activityHistoryProvider = FutureProvider.autoDispose<List<DailyActivity>>((ref) async {
  final repo = await ref.watch(repositoryProvider.future);
  return repo.activity();
});
