import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models.dart';
import '../../state/providers.dart';
import '../connect/connect_sheet.dart';
import '../settings/settings_page.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ring = ref.watch(ringControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Anillo R21M'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (ring.isConnected) {
            try {
              await ref.read(ringControllerProvider.notifier).refreshInfo();
            } catch (e) {
              // Un fallo al releer debe verse: si no, el valor viejo en pantalla
              // se confunde con un dato recién leído.
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('No se pudo leer el anillo: $e')),
                );
              }
            }
          }
          ref.invalidate(latestReadingProvider);
          ref.invalidate(todayActivityProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ConnectionCard(state: ring),
            const SizedBox(height: 16),
            Text('Últimas lecturas', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final kind in ReadingKind.values) _LatestCard(kind: kind),
            const SizedBox(height: 8),
            const _TodayActivityCard(),
          ],
        ),
      ),
    );
  }
}

class _ConnectionCard extends ConsumerWidget {
  const _ConnectionCard({required this.state});

  final RingState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final info = state.info;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  state.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                  color: state.isConnected ? theme.colorScheme.primary : theme.disabledColor,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        switch (state.status) {
                          ConnectionStatus.connected => state.deviceName ?? 'Anillo conectado',
                          ConnectionStatus.connecting => 'Conectando...',
                          ConnectionStatus.reconnecting =>
                            'Se perdió la conexión, reintentando (${state.reconnectAttempt})...',
                          ConnectionStatus.error => 'Sin conexión',
                          ConnectionStatus.disconnected => 'Sin conexión',
                        },
                        style: theme.textTheme.titleMedium,
                      ),
                      if (state.isConnected && info != null) ...[
                        Text(
                          // El estado de batería solo se muestra si significa algo:
                          // en este anillo el byte vale 0x02 siempre, cargando o no.
                          [
                            '${info.batteryPct} %',
                            if (info.batteryStateLabel != null) info.batteryStateLabel!,
                            'MTU ${state.mtu}',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                        if (state.infoReadAt != null)
                          Text(
                            'leído ${_ago(state.infoReadAt!).toLowerCase()}',
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.disabledColor),
                          ),
                      ],
                    ],
                  ),
                ),
                if (state.isBusy)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                      if (state.status == ConnectionStatus.reconnecting)
                        TextButton(
                          // El usuario debe poder rendirse antes que el bucle.
                          onPressed: () => ref.read(ringControllerProvider.notifier).disconnect(),
                          child: const Text('Cancelar'),
                        ),
                    ],
                  )
                else if (state.isConnected)
                  TextButton(
                    onPressed: () => ref.read(ringControllerProvider.notifier).disconnect(),
                    child: const Text('Desconectar'),
                  )
                else
                  FilledButton(
                    onPressed: () => showConnectSheet(context),
                    child: const Text('Conectar'),
                  ),
              ],
            ),
            if (state.error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(state.error!, style: theme.textTheme.bodySmall),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LatestCard extends ConsumerWidget {
  const _LatestCard({required this.kind});

  final ReadingKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(latestReadingProvider(kind));
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(switch (kind) {
          ReadingKind.heartRate => Icons.favorite,
          ReadingKind.spo2 => Icons.water_drop_outlined,
          ReadingKind.bloodPressure => Icons.monitor_heart_outlined,
        }),
        title: Text(kind.label),
        subtitle: async.when(
          data: (r) => Text(r == null ? 'Sin datos todavía' : _ago(r.takenAt)),
          loading: () => const Text('...'),
          error: (e, _) => Text('$e', style: TextStyle(color: theme.colorScheme.error)),
        ),
        trailing: async.maybeWhen(
          data: (r) => Text(
            r?.display ?? '--',
            style: theme.textTheme.titleLarge,
          ),
          orElse: () => const Text('--'),
        ),
      ),
    );
  }
}

class _TodayActivityCard extends ConsumerWidget {
  const _TodayActivityCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(todayActivityProvider);
    return Card(
      child: ListTile(
        leading: const Icon(Icons.directions_walk),
        title: const Text('Actividad de hoy'),
        subtitle: async.maybeWhen(
          data: (a) => Text(a == null
              ? 'Sin datos todavía'
              : '${a.distanceMeters} m · ${a.calories} kcal'),
          orElse: () => const Text('...'),
        ),
        trailing: async.maybeWhen(
          data: (a) => Text('${a?.steps ?? 0}', style: Theme.of(context).textTheme.titleLarge),
          orElse: () => const Text('--'),
        ),
      ),
    );
  }
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'Hace un momento';
  if (d.inMinutes < 60) return 'Hace ${d.inMinutes} min';
  if (d.inHours < 24) return 'Hace ${d.inHours} h';
  return 'Hace ${d.inDays} d';
}
