import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import '../protocol/commands.dart';
import '../protocol/decoders.dart';
import '../protocol/frame.dart';
import 'ring_uuids.dart';

/// Una línea del registro de tramas, para la consola de depuración.
class TraceEntry {
  TraceEntry({
    required this.at,
    required this.outgoing,
    required this.label,
    required this.hex,
    this.note,
  });

  final DateTime at;
  final bool outgoing;
  final String label;
  final String hex;
  final String? note;
}

/// Conexión con el anillo: MTU, suscripciones, cola de comandos y reensamblado.
///
/// Reglas obtenidas midiendo el anillo real (ver `docs/PROTOCOLO-R21M.md`):
///  - Un solo comando en vuelo: el anillo corta la conexión ante tramas solapadas.
///  - Hay que sincronizar la hora en cada conexión; el RTC no avanza solo.
///  - Las respuestas llegan por el MISMO canal donde se escribe (`be940001`).
///  - `be940001`, `be940003` y `fea1` son `indicate`, no `notify`.
///  - El despacho de tramas va SIEMPRE antes que el registro/presentación: un
///    fallo al formatear no puede dejar colgado a quien espera una respuesta.
///    (Fue un bug real en la herramienta Python; ver §6 del documento.)
class RingConnection {
  RingConnection(this.deviceId);

  final String deviceId;

  final _subs = <StreamSubscription<Uint8List>>[];
  final _reassemblers = <String, FrameReassembler>{};
  final _waiters = <_Waiter>[];

  final _frames = StreamController<Frame>.broadcast();
  final _live = StreamController<LiveReading>.broadcast();
  final _activity = StreamController<ActivityCounters>.broadcast();
  final _trace = StreamController<TraceEntry>.broadcast();

  /// Todas las tramas decodificadas que emite el anillo.
  Stream<Frame> get frames => _frames.stream;

  /// Lecturas en vivo (`06 01` / `06 02` / `06 03`).
  Stream<LiveReading> get liveReadings => _live.stream;

  /// Contador de actividad (`fea1`).
  Stream<ActivityCounters> get activityCounters => _activity.stream;

  /// Registro de tramas para la consola de depuración.
  Stream<TraceEntry> get trace => _trace.stream;

  int mtu = 23;
  bool _connected = false;

  bool get isConnected => _connected;

  Future<void> connect({Duration timeout = const Duration(seconds: 25)}) async {
    await UniversalBle.connect(deviceId, timeout: timeout);
    _connected = true;

    // En Android se puede pedir MTU; en iOS se negocia solo (~185, igual que en
    // Windows). El reensamblado es obligatorio en ambos casos, no una mejora.
    try {
      mtu = await UniversalBle.requestMtu(deviceId, 517);
    } catch (_) {
      mtu = 185;
    }

    final services = await UniversalBle.discoverServices(deviceId);
    final found = <String, String>{}; // característica -> servicio
    for (final s in services) {
      for (final c in s.characteristics) {
        found[c.uuid.toLowerCase()] = s.uuid;
      }
    }
    if (!found.containsKey(RingUuids.commandChar)) {
      throw StateError(
        'No se encontró el canal de comandos (be940001). '
        '¿Es realmente un anillo de la familia R21M?',
      );
    }

    await _subscribe(RingUuids.commandService, RingUuids.commandChar, 'be940001',
        framed: true, indicate: true);
    await _subscribe(RingUuids.commandService, RingUuids.notifyChar, 'be940003',
        framed: true, indicate: true);
    await _subscribe(RingUuids.activityService, RingUuids.activityChar, 'fea1',
        framed: false, indicate: true);
    await _subscribe(RingUuids.heartRateService, RingUuids.heartRateChar, '2a37',
        framed: false, indicate: false);

    // El RTC del anillo conserva la última hora escrita: sin esto, los registros
    // del historial salen fechados mal.
    await syncTime();
  }

  Future<void> _subscribe(
    String service,
    String characteristic,
    String token, {
    required bool framed,
    required bool indicate,
  }) async {
    try {
      if (indicate) {
        await UniversalBle.subscribeIndications(deviceId, service, characteristic);
      } else {
        await UniversalBle.subscribeNotifications(deviceId, service, characteristic);
      }
      _subs.add(
        UniversalBle.characteristicValueStream(deviceId, characteristic)
            .listen((data) => _onData(token, data, framed: framed)),
      );
    } catch (e) {
      // Una característica opcional que falle no debe impedir usar el anillo.
      _emitTrace(false, token, '', note: 'no se pudo suscribir: $e');
    }
  }

  void _onData(String token, Uint8List data, {required bool framed}) {
    if (!framed) {
      // `fea1` y `2a37` van crudas, sin formato de trama.
      if (token == 'fea1' && !_activity.isClosed) {
        _activity.add(ActivityCounters(data));
      }
      _emitTrace(false, token, hexOf(data));
      return;
    }

    final r = _reassemblers.putIfAbsent(token, FrameReassembler.new);
    List<Frame> frames;
    try {
      frames = r.feed(data);
    } on BadFrame catch (e) {
      r.reset();
      _emitTrace(false, token, hexOf(data), note: e.message);
      return;
    }

    if (frames.isEmpty) {
      _emitTrace(false, token, hexOf(data), note: 'fragmento, esperando resto');
      return;
    }

    for (final f in frames) {
      // Despacho primero, presentación después. Ver nota de la clase.
      _dispatch(f);
      _emitTrace(false, token, hexOf(f.payload), label: commandName(f.code));
    }
  }

  void _dispatch(Frame f) {
    if (!_frames.isClosed) _frames.add(f);

    final live = decodeLive(f.code, f.payload);
    if (live != null && !_live.isClosed) _live.add(live);

    for (final w in List<_Waiter>.from(_waiters)) {
      if (w.code == f.code && !w.completer.isCompleted) {
        w.completer.complete(f);
        _waiters.remove(w);
      }
    }
  }

  void _emitTrace(bool outgoing, String token, String hex, {String? label, String? note}) {
    if (_trace.isClosed) return;
    _trace.add(TraceEntry(
      at: DateTime.now(),
      outgoing: outgoing,
      label: label ?? token,
      hex: hex,
      note: note,
    ));
  }

  /// Envía una trama. `universal_ble` ya serializa los comandos por dispositivo,
  /// lo que nos da gratis el "un comando en vuelo" que el anillo exige.
  Future<void> send(Uint8List raw) async {
    _emitTrace(true, 'be940001', hexOf(raw),
        label: commandName(parseFrame(raw, verifyCrc: false).code));
    await UniversalBle.write(
      deviceId,
      RingUuids.commandService,
      RingUuids.commandChar,
      raw,
    );
  }

  /// Envía y espera la respuesta con el mismo grupo/comando.
  Future<Frame> request(Uint8List raw, {Duration timeout = const Duration(seconds: 10)}) async {
    final code = parseFrame(raw, verifyCrc: false).code;
    final w = _Waiter(code);
    _waiters.add(w);
    try {
      await send(raw);
      return await w.completer.future.timeout(timeout);
    } finally {
      _waiters.remove(w);
    }
  }

  /// Espera un evento que el anillo enviará por su cuenta (p. ej. `04 0E`).
  Future<Frame> waitFor(int code, {required Duration timeout}) {
    final w = _Waiter(code);
    _waiters.add(w);
    return w.completer.future.timeout(timeout).whenComplete(() => _waiters.remove(w));
  }

  Future<void> syncTime() => send(setTime(DateTime.now()));

  Future<DeviceInfo?> readDeviceInfo() async {
    final f = await request(getDeviceInfo());
    return decodeDeviceInfo(f.payload);
  }

  Future<ActivityCounters> readActivity() async {
    final f = await request(getNowStep());
    return ActivityCounters(f.payload);
  }

  /// Consulta un historial y recoge los registros hasta que deje de llegar nada.
  ///
  /// El anillo responde primero con `[estado][conteo]` y luego empuja los
  /// registros. No hay marca de fin, así que cerramos por silencio.
  Future<List<Frame>> fetchHistory(
    int queryCode, {
    Duration quietPeriod = const Duration(seconds: 3),
    Duration maxWait = const Duration(seconds: 45),
  }) async {
    final collected = <Frame>[];
    final sub = _frames.stream.listen((f) {
      // Ignoramos el eco de la consulta y los datos en vivo.
      if (f.code != queryCode && (f.code >> 8) == 0x05) collected.add(f);
    });

    try {
      await send(queryHistory(queryCode));
      final deadline = DateTime.now().add(maxWait);
      var lastCount = -1;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(quietPeriod);
        if (collected.length == lastCount) break; // silencio: terminó
        lastCount = collected.length;
      }
      return collected;
    } finally {
      await sub.cancel();
    }
  }

  Future<void> dispose() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    for (final w in _waiters) {
      if (!w.completer.isCompleted) {
        w.completer.completeError(StateError('Conexión cerrada'));
      }
    }
    _waiters.clear();
    await _frames.close();
    await _live.close();
    await _activity.close();
    await _trace.close();
    try {
      await UniversalBle.disconnect(deviceId);
    } catch (_) {}
    _connected = false;
  }
}

class _Waiter {
  _Waiter(this.code);
  final int code;
  final completer = Completer<Frame>();
}
