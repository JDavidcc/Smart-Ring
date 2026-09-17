import 'dart:async';

import '../protocol/commands.dart';
import '../protocol/decoders.dart';
import 'ring_connection.dart';

/// Estado de una medición en curso, para pintarlo en la UI.
class MeasurementProgress {
  const MeasurementProgress({
    required this.type,
    required this.elapsed,
    this.latest,
    this.result,
    this.error,
  });

  final MeasureType type;
  final Duration elapsed;
  final LiveReading? latest;
  final MeasureResult? result;
  final String? error;

  bool get finished => result != null || error != null;

  /// Hasta ~50 s de silencio antes del primer valor es NORMAL en este anillo
  /// (medido: HR ~22 s, presión ~18 s, SpO2 ~48 s). La UI no debe alarmar antes.
  bool get waitingForFirstValue => latest == null && !finished;
}

/// Ejecuta el ciclo completo de una medición: disparar, recoger valores en vivo,
/// esperar el evento de fin `04 0E` y detener siempre, pase lo que pase.
Stream<MeasurementProgress> runMeasurement(
  RingConnection ring,
  MeasureType type,
) async* {
  final started = DateTime.now();
  final controller = StreamController<MeasurementProgress>();
  LiveReading? latest;

  Duration elapsed() => DateTime.now().difference(started);

  final liveSub = ring.liveReadings.listen((r) {
    // Filtramos lecturas de otro tipo: el anillo puede emitir varias clases.
    final relevant = switch (type) {
      MeasureType.heart => r.heartRate != null,
      MeasureType.spo2 => r.spo2 != null,
      MeasureType.bloodPressure => r.systolic != null,
    };
    if (!relevant) return;
    latest = r;
    controller.add(MeasurementProgress(type: type, elapsed: elapsed(), latest: r));
  });

  final ticker = Timer.periodic(const Duration(seconds: 1), (_) {
    controller.add(MeasurementProgress(type: type, elapsed: elapsed(), latest: latest));
  });

  unawaited(() async {
    try {
      await ring.send(startMeasurement(type));
      final done = await ring.waitFor(evtMeasureDone, timeout: type.expectedDuration);
      final result = decodeMeasureDone(done.payload);
      controller.add(MeasurementProgress(
        type: type,
        elapsed: elapsed(),
        latest: latest,
        result: result,
      ));
    } on TimeoutException {
      controller.add(MeasurementProgress(
        type: type,
        elapsed: elapsed(),
        latest: latest,
        error: 'El anillo no respondió a tiempo. Comprueba que lo llevas '
            'bien ajustado y con el sensor hacia la palma.',
      ));
    } catch (e) {
      controller.add(MeasurementProgress(
        type: type,
        elapsed: elapsed(),
        latest: latest,
        error: '$e',
      ));
    } finally {
      // Detener siempre: si no, el anillo sigue midiendo y gastando bateria.
      try {
        await ring.send(stopMeasurement());
      } catch (_) {}
      ticker.cancel();
      await liveSub.cancel();
      await controller.close();
    }
  }());

  yield* controller.stream;
}
