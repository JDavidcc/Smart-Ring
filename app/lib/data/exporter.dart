import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'models.dart';
import 'ring_repository.dart';

/// Exporta los datos locales a CSV (uno por métrica) y a un JSON único.
///
/// Todo sale del dispositivo solo cuando tú lo compartes: la app no manda nada
/// a ningún servidor.
class DataExporter {
  DataExporter(this._repo);

  final RingRepository _repo;

  /// Genera los archivos y abre el diálogo de compartir del sistema.
  Future<List<String>> exportAndShare() async {
    final files = await _writeFiles();
    await SharePlus.instance.share(
      ShareParams(
        files: files.map((f) => XFile(f)).toList(),
        subject: 'Datos del anillo R21M',
      ),
    );
    return files;
  }

  /// Genera los archivos sin compartir. Devuelve las rutas.
  ///
  /// [baseDir] permite fijar dónde escribir; sin él usa el temporal del sistema.
  Future<List<String>> exportOnly({Directory? baseDir}) => _writeFiles(baseDir: baseDir);

  Future<List<String>> _writeFiles({Directory? baseDir}) async {
    final dir = baseDir ?? await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final out = p.join(dir.path, 'anillo-$stamp');
    await Directory(out).create(recursive: true);

    final paths = <String>[];

    final hr = await _repo.readings(kind: ReadingKind.heartRate, limit: 100000);
    paths.add(await _writeCsv(p.join(out, 'ritmo_cardiaco.csv'), [
      'fecha_hora,bpm,origen',
      ...hr.map((r) => '${r.takenAt.toIso8601String()},${r.heartRate ?? ''},${r.source.id}'),
    ]));

    final spo2 = await _repo.readings(kind: ReadingKind.spo2, limit: 100000);
    paths.add(await _writeCsv(p.join(out, 'oxigeno.csv'), [
      'fecha_hora,spo2_pct,origen',
      ...spo2.map((r) => '${r.takenAt.toIso8601String()},${r.spo2 ?? ''},${r.source.id}'),
    ]));

    final bp = await _repo.readings(kind: ReadingKind.bloodPressure, limit: 100000);
    paths.add(await _writeCsv(p.join(out, 'presion.csv'), [
      // La presión de este anillo es ESTIMADA, no medida con manguito.
      '# Valores estimados por el anillo. No son una medición médica.',
      'fecha_hora,sistolica,diastolica,pulso_probable,origen',
      ...bp.map((r) => '${r.takenAt.toIso8601String()},${r.systolic ?? ''},'
          '${r.diastolic ?? ''},${r.pulseFromBp ?? ''},${r.source.id}'),
    ]));

    final activity = await _repo.activity(days: 3650);
    paths.add(await _writeCsv(p.join(out, 'actividad.csv'), [
      '# El formato del contador de actividad aún no está confirmado; se incluye el crudo.',
      'dia,pasos,distancia_m,calorias,crudo_hex',
      ...activity.map((a) => '${_day(a.day)},${a.steps},${a.distanceMeters},'
          '${a.calories},${a.rawHex ?? ''}'),
    ]));

    final nights = await _repo.sleepNights(limit: 3650);
    paths.add(await _writeCsv(p.join(out, 'sueno.csv'), [
      'noche_inicio,noche_fin,etapa,etapa_inicio,duracion_s',
      ...nights.expand((n) => n.segments.map((s) =>
          '${n.start.toIso8601String()},${n.end.toIso8601String()},'
          '${s.stage},${s.start.toIso8601String()},${s.durationSeconds}')),
    ]));

    // JSON único con todo, para análisis programático.
    final json = {
      'exportado_en': DateTime.now().toIso8601String(),
      'dispositivo': 'R21M',
      'aviso': 'La presión arterial es estimada por el anillo, no es una medición médica.',
      'ritmo_cardiaco': hr
          .map((r) => {'fecha_hora': r.takenAt.toIso8601String(), 'bpm': r.heartRate, 'origen': r.source.id})
          .toList(),
      'oxigeno': spo2
          .map((r) => {'fecha_hora': r.takenAt.toIso8601String(), 'spo2_pct': r.spo2, 'origen': r.source.id})
          .toList(),
      'presion': bp
          .map((r) => {
                'fecha_hora': r.takenAt.toIso8601String(),
                'sistolica': r.systolic,
                'diastolica': r.diastolic,
                'pulso_probable': r.pulseFromBp,
                'origen': r.source.id,
              })
          .toList(),
      'actividad': activity
          .map((a) => {
                'dia': _day(a.day),
                'pasos': a.steps,
                'distancia_m': a.distanceMeters,
                'calorias': a.calories,
                'crudo_hex': a.rawHex,
              })
          .toList(),
      'sueno': nights
          .map((n) => {
                'inicio': n.start.toIso8601String(),
                'fin': n.end.toIso8601String(),
                'etapas': n.segments
                    .map((s) => {
                          'etapa': s.stage,
                          'inicio': s.start.toIso8601String(),
                          'duracion_s': s.durationSeconds,
                        })
                    .toList(),
              })
          .toList(),
    };
    final jsonPath = p.join(out, 'anillo_completo.json');
    await File(jsonPath).writeAsString(const JsonEncoder.withIndent('  ').convert(json));
    paths.add(jsonPath);

    return paths;
  }

  Future<String> _writeCsv(String path, List<String> lines) async {
    await File(path).writeAsString(lines.join('\n'));
    return path;
  }

  static String _day(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}
