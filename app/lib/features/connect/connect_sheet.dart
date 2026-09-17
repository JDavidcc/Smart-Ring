import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/ring_scanner.dart';
import '../../state/providers.dart';

Future<void> showConnectSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => const _ConnectSheet(),
  );
}

class _ConnectSheet extends ConsumerStatefulWidget {
  const _ConnectSheet();

  @override
  ConsumerState<_ConnectSheet> createState() => _ConnectSheetState();
}

class _ConnectSheetState extends ConsumerState<_ConnectSheet> {
  bool _permissionsOk = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok = await RingScanner.ensurePermissions();
    if (!mounted) return;
    setState(() {
      _permissionsOk = ok;
      _checking = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_checking) {
      return const SizedBox(height: 240, child: Center(child: CircularProgressIndicator()));
    }
    if (!_permissionsOk) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bluetooth_disabled, size: 48),
            const SizedBox(height: 16),
            Text('Faltan permisos de Bluetooth', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'La app necesita permiso de Bluetooth para encontrar el anillo. '
              'No usa tu ubicación para nada más.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _check, child: const Text('Reintentar')),
          ],
        ),
      );
    }

    final scan = ref.watch(scanProvider);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Buscando tu anillo', style: theme.textTheme.titleLarge),
                const SizedBox(height: 8),
                Text(
                  'Si no aparece: el anillo solo acepta una conexión a la vez. '
                  'Cierra la app SmartHealth y quítalo de los dispositivos '
                  'Bluetooth del sistema.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
          Expanded(
            child: scan.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('No se pudo escanear:\n$e', textAlign: TextAlign.center),
                ),
              ),
              data: (rings) => rings.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Ningún anillo a la vista todavía...'),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      itemCount: rings.length,
                      itemBuilder: (_, i) => _RingTile(ring: rings[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RingTile extends ConsumerWidget {
  const _RingTile({required this.ring});

  final DiscoveredRing ring;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final battery = ring.batteryPct;
    return ListTile(
      leading: const Icon(Icons.radio_button_checked),
      title: Text(ring.name),
      subtitle: Text([
        if (ring.mac != null) ring.mac!,
        '${ring.rssi} dBm',
        // La batería se lee del advertisement, sin conectar.
        if (battery != null) 'Batería $battery %',
      ].join(' · ')),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        Navigator.of(context).pop();
        await ref.read(ringControllerProvider.notifier).connect(ring.deviceId, ring.name);
      },
    );
  }
}
