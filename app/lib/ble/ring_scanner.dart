import 'dart:async';

import 'package:universal_ble/universal_ble.dart';

import '../protocol/decoders.dart';
import 'ring_uuids.dart';

/// Un anillo visto en el escaneo, con lo que se puede leer SIN conectarse.
class DiscoveredRing {
  const DiscoveredRing({
    required this.deviceId,
    required this.name,
    required this.rssi,
    required this.advertisement,
  });

  final String deviceId;
  final String name;
  final int rssi;
  final RingAdvertisement advertisement;

  /// Nivel de batería leído del advertisement, sin conectar. VERIFICADO:
  /// coincide con el byte 5 de la respuesta a `02 00`.
  int? get batteryPct => advertisement.batteryPct;

  /// MAC extraído del manufacturer data.
  String? get mac => advertisement.mac;
}

class RingScanner {
  /// Pide los permisos necesarios. En Android 12+ basta con Bluetooth;
  /// por debajo de API 31 hace falta ubicación.
  static Future<bool> ensurePermissions() async {
    if (await UniversalBle.hasPermissions()) return true;
    await UniversalBle.requestPermissions();
    return UniversalBle.hasPermissions();
  }

  static Future<bool> isBluetoothOn() async =>
      await UniversalBle.getBluetoothAvailabilityState() == AvailabilityState.poweredOn;

  /// Escanea buscando anillos R21M y va acumulando los que encuentra.
  ///
  /// IMPORTANTE: el anillo **no se anuncia mientras está conectado a otro
  /// central**. Si la app SmartHealth lo tiene tomado, aquí no aparecerá.
  static Stream<List<DiscoveredRing>> scan() async* {
    final found = <String, DiscoveredRing>{};
    final controller = StreamController<List<DiscoveredRing>>();

    final sub = UniversalBle.scanStream.listen((device) {
      final ring = _asRing(device);
      if (ring == null) return;
      found[ring.deviceId] = ring;
      final list = found.values.toList()..sort((a, b) => b.rssi.compareTo(a.rssi));
      if (!controller.isClosed) controller.add(list);
    });

    await UniversalBle.startScan();
    controller.onCancel = () async {
      await sub.cancel();
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    };

    yield* controller.stream;
  }

  static DiscoveredRing? _asRing(BleDevice device) {
    final name = device.name ?? '';
    final byName = name.toUpperCase().startsWith(RingUuids.namePrefix);

    RingAdvertisement? adv;
    for (final md in device.manufacturerDataList) {
      final decoded = decodeManufacturerData(md.companyId, md.payload, name: name);
      if (decoded.isRing) {
        adv = decoded;
        break;
      }
    }

    if (adv == null) {
      if (!byName) return null;
      // Nombre correcto pero sin manufacturer data reconocible: lo mostramos
      // igual, simplemente sin batería. No inventamos el dato.
      adv = RingAdvertisement(name: name);
    }

    return DiscoveredRing(
      deviceId: device.deviceId,
      name: name.isEmpty ? 'Anillo' : name,
      rssi: device.rssi ?? -127,
      advertisement: adv,
    );
  }

  static Future<void> stop() async {
    try {
      await UniversalBle.stopScan();
    } catch (_) {}
  }
}
