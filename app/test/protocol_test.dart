import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_ring/protocol/commands.dart';
import 'package:smart_ring/protocol/decoders.dart';
import 'package:smart_ring/protocol/frame.dart';

/// Pruebas contra capturas REALES del anillo R21M (07:29:00:12:1E:D8),
/// tomadas con `tools/ringlab` el 2026-09-17 y guardadas en
/// `tools/ringlab/capturas/`.
///
/// Las tramas TX son especialmente valiosas: son los bytes exactos que el anillo
/// ACEPTO y respondio, CRC incluido. Si `buildFrame` los reproduce, la capa de
/// trama de Dart es correcta frente al hardware, no solo consigo misma.
void main() {
  group('CRC-16/CCITT-FALSE', () {
    test('vector estandar', () {
      expect(crc16('123456789'.codeUnits), 0x29B1);
    });

    test('vacio', () {
      expect(crc16([]), 0xFFFF);
    });
  });

  group('Tramas reales aceptadas por el anillo', () {
    // (descripcion, trama construida, hex capturado)
    final casos = <(String, Uint8List, String)>[
      ('GetDeviceInfo', getDeviceInfo(), '02 00 08 00 47 43 6F EC'),
      (
        'SetTime 2026-09-17 11:41:37',
        setTime(DateTime(2026, 9, 17, 11, 41, 37)),
        '01 00 0E 00 EA 07 09 11 0B 29 25 00 CB 5F',
      ),
      ('Medir HR', startMeasurement(MeasureType.heart), '03 2F 08 00 01 00 4F 1B'),
      ('Medir presion', startMeasurement(MeasureType.bloodPressure), '03 2F 08 00 01 01 6E 0B'),
      ('Medir SpO2', startMeasurement(MeasureType.spo2), '03 2F 08 00 01 02 0D 3B'),
      ('Detener medicion', stopMeasurement(), '03 2F 08 00 00 00 7E 28'),
      ('GetNowStep', getNowStep(), '02 0C 06 00 6F B6'),
      ('Historial HR', queryHistory(cmdHistoryHeart), '05 06 06 00 83 20'),
      ('Historial sueno', queryHistory(cmdHistorySleep), '05 04 06 00 E3 4E'),
    ];

    for (final (nombre, construida, capturada) in casos) {
      test('$nombre se reproduce byte a byte', () {
        expect(hexOf(construida), capturada);
      });

      test('$nombre vuelve a parsearse con CRC valido', () {
        final f = parseFrame(parseHex(capturada));
        expect(f.code, parseFrame(construida).code);
      });
    }

    test('la longitud declarada incluye cabecera y CRC', () {
      // El anillo corta la conexion si esto esta mal. `02 00 "GC"` mide 8, no 6.
      final f = getDeviceInfo();
      expect(f.length, 8);
      expect(f[2] | (f[3] << 8), f.length);
    });

    test('una trama GENERADA por el anillo pasa nuestra verificación de CRC', () {
      // Respuesta real a GetNowStep, capturada completa con el CRC del propio
      // anillo. Las demás fijaciones son tramas que nosotros construimos y el
      // anillo aceptó; esta prueba lo contrario: que calculamos el mismo CRC
      // que el firmware genera.
      final raw = parseHex(
          '02 0C 14 00 52 00 00 03 00 34 00 00 00 00 00 00 00 00 35 D9');
      final f = parseFrame(raw); // verifyCrc: true por defecto
      expect(f.code, cmdGetNowStep);
      expect(f.payload, hasLength(14));

      // Y reconstruirla desde el payload debe dar exactamente los mismos bytes.
      expect(hexOf(buildFrame(0x02, 0x0C, f.payload)), hexOf(raw));
    });

    test('un CRC alterado se rechaza', () {
      final malo = parseHex('02 00 08 00 47 43 6F ED');
      expect(() => parseFrame(malo), throwsA(isA<BadFrame>()));
    });

    test('una longitud mentirosa se rechaza', () {
      final malo = parseHex('02 00 FF 00 47 43 6F EC');
      expect(() => parseFrame(malo), throwsA(isA<BadFrame>()));
    });
  });

  group('Reensamblado de notificaciones', () {
    test('una trama partida en fragmentos de 3 bytes se reconstruye', () {
      final grande = buildFrame(0x05, 0x13, List.generate(60, (i) => i));
      final r = FrameReassembler();
      final salidas = <Frame>[];
      for (var i = 0; i < grande.length; i += 3) {
        salidas.addAll(r.feed(grande.sublist(i, (i + 3).clamp(0, grande.length))));
      }
      expect(salidas, hasLength(1));
      expect(salidas.first.payload, List.generate(60, (i) => i));
    });

    test('dos tramas en una sola notificacion salen ambas', () {
      final r = FrameReassembler();
      final salidas = r.feed([
        ...buildFrame(0x06, 0x01, [0x4C]),
        ...buildFrame(0x06, 0x02, [0x62]),
      ]);
      expect(salidas.map((f) => f.code), [evtLiveHeart, evtLiveSpo2]);
    });

    test('un bloque partido en el limite de MTU 185 se reconstruye', () {
      // Caso real de iOS y de Windows: el anillo negocia 185 bytes.
      final grande = buildFrame(0x05, 0x13, List.generate(400, (i) => i & 0xFF));
      final r = FrameReassembler();
      final salidas = <Frame>[];
      for (var i = 0; i < grande.length; i += 182) {
        salidas.addAll(r.feed(grande.sublist(i, (i + 182).clamp(0, grande.length))));
      }
      expect(salidas, hasLength(1));
      expect(salidas.first.payload, hasLength(400));
    });

    test('no emite nada mientras la trama esta incompleta', () {
      final grande = buildFrame(0x05, 0x13, List.filled(100, 0xAB));
      final r = FrameReassembler();
      expect(r.feed(grande.sublist(0, 50)), isEmpty);
      expect(r.feed(grande.sublist(50)), hasLength(1));
    });
  });

  group('Advertisement real', () {
    // Capturado 103 veces identico en lecturas-ble/ y confirmado en vivo.
    final md = parseHex('09 00 00 01 02 1B 00 00 00 00 00 00 0F 00 00 00 01 00 64 00 00 '
        '07 29 00 12 1E D8');

    test('extrae MAC y bateria', () {
      final a = decodeManufacturerData(0x7810, md, name: 'R21M 1ED8');
      expect(a.isRing, isTrue);
      expect(a.mac, '07:29:00:12:1E:D8');
      expect(a.batteryPct, 100);
      expect(a.name, 'R21M 1ED8');
    });

    test('no inventa valores si el fabricante no es el nuestro', () {
      // Datos de un dispositivo Apple visto en el mismo escaneo.
      final ajeno = parseHex('10 05 3E 18 9C ED E4');
      final a = decodeManufacturerData(0x004C, ajeno);
      expect(a.isRing, isFalse);
      expect(a.mac, isNull);
      expect(a.batteryPct, isNull);
    });

    test('tampoco si el largo no coincide', () {
      final a = decodeManufacturerData(0x7810, md.sublist(0, 20));
      expect(a.batteryPct, isNull);
    });
  });

  group('Respuestas reales del anillo', () {
    test('GetDeviceInfo: bateria 100%', () {
      final p = parseHex('A3 00 1B 02 02 64 E3 01 00 03 E3 01 90 09 00 00 D0 3E 01 00 00 00 00 00');
      final info = decodeDeviceInfo(p)!;
      expect(info.batteryPct, 100);
      expect(info.batteryStateRaw, 0x02);
    });

    test('el estado de bateria 0x02 no se afirma como cargando', () {
      // VERIFICADO que el byte 4 NO refleja el cargador en este firmware: dos
      // lecturas identicas byte a byte, una fuera del cargador (11:40) y otra
      // con el anillo cargando (14:14). Ante 0x02 devolvemos null en vez de
      // inventar un booleano.
      final p = parseHex('A3 00 1B 02 02 64 E3 01');
      expect(decodeDeviceInfo(p)!.isCharging, isNull);
      expect(decodeDeviceInfo(p)!.batteryStateLabel, isNull,
          reason: 'la UI debe omitirlo, no mostrar ruido');
      expect(decodeDeviceInfo(p)!.batteryState, contains('Sin documentar'),
          reason: 'pero la consola de depuración sí debe ver el crudo');
    });

    test('las dos lecturas reales de 02 00 son idénticas', () {
      // Misma respuesta a las 11:40 (sin cargador) y a las 14:14 (cargando).
      const hex = 'A3 00 1B 02 02 64 E3 01 00 03 E3 01 90 09 00 00 D0 3E 01 00 00 00 00 00';
      final a = decodeDeviceInfo(parseHex(hex))!;
      final b = decodeDeviceInfo(parseHex(hex))!;
      expect(a.batteryPct, 100);
      expect(a.batteryStateRaw, b.batteryStateRaw);
      expect(a.batteryStateRaw, 0x02);
    });

    test('estados de bateria documentados si se traducen', () {
      final fuera = parseHex('A3 00 1B 02 00 64 E3 01');
      final cargando = parseHex('A3 00 1B 02 01 64 E3 01');
      expect(decodeDeviceInfo(fuera)!.isCharging, isFalse);
      expect(decodeDeviceInfo(cargando)!.isCharging, isTrue);
    });

    test('HR en vivo: 4C -> 76 bpm', () {
      expect(decodeLive(evtLiveHeart, parseHex('4C'))!.heartRate, 76);
      expect(decodeLive(evtLiveHeart, parseHex('4B'))!.heartRate, 75);
    });

    test('SpO2 en vivo: 62 -> 98%', () {
      expect(decodeLive(evtLiveSpo2, parseHex('62'))!.spo2, 98);
    });

    test('presion en vivo: 70 49 4E -> 112/73, pulso probable 78', () {
      final p = parseHex('70 49 4E 00 00 00 00 00 00 00 00 00 00 00');
      final r = decodeLive(evtLiveBlood, p)!;
      expect(r.systolic, 112);
      expect(r.diastolic, 73);
      expect(r.pulseFromBp, 78);
    });

    test('evento de fin para los tres tipos medidos', () {
      final hr = decodeMeasureDone(parseHex('00 01'))!;
      final bp = decodeMeasureDone(parseHex('01 01'))!;
      final spo2 = decodeMeasureDone(parseHex('02 01'))!;
      expect(hr.type, MeasureType.heart);
      expect(bp.type, MeasureType.bloodPressure);
      expect(spo2.type, MeasureType.spo2);
      expect([hr, bp, spo2].every((r) => r.succeeded), isTrue);
    });

    test('anillo NO puesto: trama real capturada con el anillo en la mesa', () {
      // Bytes exactos emitidos por el anillo al medir sin llevarlo puesto.
      final f = parseFrame(parseHex('04 0E 08 00 00 02 98 62'));
      final r = decodeMeasureDone(f.payload)!;
      expect(r.type, MeasureType.heart);
      expect(r.succeeded, isFalse);
      expect(r.notWorn, isTrue);
      expect(r.message, contains('no está puesto'));
    });

    test('el anillo emite pulsos plausibles aunque NO esté puesto', () {
      // En esa misma captura llegaron tres tramas 06 01 con 75 bpm ANTES del
      // rechazo. Decodifican bien, pero no deben persistirse: solo el 04 0E
      // con resultado 01 autoriza a guardar. Ver RingController._commit.
      final falsa = parseFrame(parseHex('06 01 07 00 4B 02 D6'));
      expect(decodeLive(falsa.code, falsa.payload)!.heartRate, 75);
    });

    test('GetNowStep vacio: todo en cero', () {
      final a = ActivityCounters(parseHex('00 00 00 00 00 00 00 00 00 00 00 00 00 00'));
      expect(a.isAllZero, isTrue);
      expect(a.steps, 0);
      expect(a.strideMeters, isNull, reason: 'sin pasos no se puede inferir zancada');
    });
  });

  group('Contador de actividad (dos lecturas reales)', () {
    // Capturadas con ~100 pasos caminados entre una y otra. Son las dos que
    // permitieron resolver el formato: ver §8 de docs/PROTOCOLO-R21M.md.
    final tras50 = ActivityCounters(parseHex('52 00 00 03 00 34 00 00 00 00 00 00 00 00'));
    final tras150 = ActivityCounters(parseHex('C3 00 00 08 00 7B 00 00 00 00 00 00 00 00'));

    test('primera lectura', () {
      expect(tras50.steps, 82);
      expect(tras50.calories, 3);
      expect(tras50.distanceMeters, 52);
    });

    test('segunda lectura', () {
      expect(tras150.steps, 195);
      expect(tras150.calories, 8);
      expect(tras150.distanceMeters, 123);
    });

    test('los contadores solo suben entre lecturas', () {
      expect(tras150.steps, greaterThan(tras50.steps));
      expect(tras150.calories, greaterThan(tras50.calories));
      expect(tras150.distanceMeters, greaterThan(tras50.distanceMeters));
    });

    test('la zancada implícita es constante y humana', () {
      // Esta es LA prueba que identificó los campos: si la asignación de
      // offsets fuera otra, la razón distancia/pasos no se mantendría.
      expect(tras50.strideMeters, closeTo(0.634, 0.002));
      expect(tras150.strideMeters, closeTo(0.631, 0.002));
      expect((tras50.strideMeters! - tras150.strideMeters!).abs(), lessThan(0.01));
    });

    test('la distancia es coherente con pasos x zancada', () {
      const zancada = 0.635;
      expect((tras50.steps * zancada).floor(), tras50.distanceMeters);
      expect((tras150.steps * zancada).floor(), tras150.distanceMeters);
    });

    test('un payload corto no produce cifras inventadas', () {
      final corto = ActivityCounters(parseHex('52 00 00'));
      expect(corto.isValid, isFalse);
      expect(corto.steps, 0);
    });

    test('los pasos no se desbordan a los 255', () {
      // El campo es u24: la doc del R11M lo leía como 1 byte, lo que habría
      // hecho que el contador se reiniciara cada 255 pasos.
      final muchos = ActivityCounters(parseHex('A0 86 01 00 00 00 00 00'));
      expect(muchos.steps, 100000);
    });
  });

  group('Heart Rate estandar 2a37', () {
    test('decodifica pero no es fuente fiable', () {
      // Capturado DURANTE una medicion real y exitosa de 76 bpm: el bit de
      // contacto sigue diciendo "no detectado". Por eso la app no debe usarlo.
      final h = decodeStandardHrm(parseHex('04 4C'))!;
      expect(h.bpm, 76);
      expect(h.contactSupported, isTrue);
      expect(h.contactDetected, isFalse);
    });

    test('en reposo reporta 0 bpm', () {
      expect(decodeStandardHrm(parseHex('04 00'))!.bpm, 0);
    });
  });

  group('Sueno (formato aun no confirmado con datos reales)', () {
    test('decodifica una noche sintetica con sus etapas', () {
      final inicio = 800000000;
      final noche = <int>[
        0xAF, 0xFA, // marca
        36, 0, // tamano total: 20 cabecera + 2 entradas de 8
        inicio & 0xFF, (inicio >> 8) & 0xFF, (inicio >> 16) & 0xFF, (inicio >> 24) & 0xFF,
        ...List.filled(12, 0),
        0xF1, inicio & 0xFF, (inicio >> 8) & 0xFF, (inicio >> 16) & 0xFF, (inicio >> 24) & 0xFF,
        0x2C, 0x01, 0x00, // 300 s
        0xF2, inicio & 0xFF, (inicio >> 8) & 0xFF, (inicio >> 16) & 0xFF, (inicio >> 24) & 0xFF,
        0x58, 0x02, 0x00, // 600 s
      ];
      final noches = decodeSleep(Uint8List.fromList(noche));
      expect(noches, hasLength(1));
      expect(noches.first.segments.map((s) => s.stage), [SleepStage.deep, SleepStage.light]);
      expect(noches.first.segments.map((s) => s.durationSeconds), [300, 600]);
      expect(noches.first.start, tsFromDevice(inicio));
    });

    test('un blob truncado no revienta', () {
      expect(decodeSleep(parseHex('AF FA 24 00 00 01')), isEmpty);
    });
  });
}
