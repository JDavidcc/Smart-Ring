import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ble/measurement_session.dart';
import '../../protocol/commands.dart';
import '../../state/providers.dart';

class MeasurePage extends ConsumerStatefulWidget {
  const MeasurePage({super.key});

  @override
  ConsumerState<MeasurePage> createState() => _MeasurePageState();
}

class _MeasurePageState extends ConsumerState<MeasurePage> {
  StreamSubscription<MeasurementProgress>? _sub;
  MeasurementProgress? _progress;
  MeasureType? _running;

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start(MeasureType type) async {
    final conn = ref.read(connectionProvider);
    if (conn == null) return;

    setState(() {
      _running = type;
      _progress = null;
    });

    _sub = runMeasurement(conn, type).listen(
      (p) => setState(() => _progress = p),
      onDone: () {
        setState(() => _running = null);
        ref.invalidate(latestReadingProvider);
        ref.invalidate(readingsProvider);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ring = ref.watch(ringControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Medir')),
      body: !ring.isConnected
          ? const _NotConnected()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_progress != null) _ProgressCard(progress: _progress!),
                const SizedBox(height: 8),
                for (final type in MeasureType.values)
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      leading: Icon(switch (type) {
                        MeasureType.heart => Icons.favorite,
                        MeasureType.spo2 => Icons.water_drop_outlined,
                        MeasureType.bloodPressure => Icons.monitor_heart_outlined,
                      }),
                      title: Text(type.label),
                      subtitle: Text(_hint(type)),
                      trailing: _running == type
                          ? const SizedBox(
                              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : FilledButton.tonal(
                              onPressed: _running == null ? () => _start(type) : null,
                              child: const Text('Medir'),
                            ),
                    ),
                  ),
                const SizedBox(height: 8),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline, size: 20, color: theme.colorScheme.primary),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Text(
                            'Mantén la mano quieta y apoyada, con el anillo bien ajustado y el '
                            'sensor hacia la palma. El anillo tarda entre 20 y 50 segundos en '
                            'dar el primer valor: ese silencio es normal.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.errorContainer.withValues(alpha: 0.25),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.warning_amber_outlined, size: 20),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'La presión arterial que da este anillo es una estimación a partir '
                            'del sensor óptico, no una medición médica. No la uses para tomar '
                            'decisiones de salud ni para ajustar medicación.',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  static String _hint(MeasureType t) => switch (t) {
        MeasureType.heart => 'Unos 35 segundos',
        MeasureType.spo2 => 'Hasta un minuto',
        MeasureType.bloodPressure => 'Unos 25 segundos · estimada',
      };
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.progress});

  final MeasurementProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = progress.latest;

    final value = switch (progress.type) {
      MeasureType.heart => r?.heartRate != null ? '${r!.heartRate} bpm' : null,
      MeasureType.spo2 => r?.spo2 != null ? '${r!.spo2} %' : null,
      MeasureType.bloodPressure =>
        r?.systolic != null ? '${r!.systolic}/${r.diastolic} mmHg' : null,
    };

    return Card(
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Text(progress.type.label, style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            Text(
              value ?? '--',
              style: theme.textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w300),
            ),
            if (progress.type == MeasureType.bloodPressure && r?.pulseFromBp != null)
              Text('pulso ~${r!.pulseFromBp}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 16),
            if (!progress.finished) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                progress.waitingForFirstValue
                    ? 'Midiendo... (${progress.elapsed.inSeconds} s) — el primer valor '
                        'puede tardar hasta 50 s'
                    : 'Midiendo... (${progress.elapsed.inSeconds} s)',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (progress.result != null)
              Text(
                progress.result!.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: progress.result!.succeeded
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
                textAlign: TextAlign.center,
              ),
            if (progress.error != null)
              Text(
                progress.error!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
                textAlign: TextAlign.center,
              ),
          ],
        ),
      ),
    );
  }
}

class _NotConnected extends StatelessWidget {
  const _NotConnected();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bluetooth_disabled, size: 48),
              SizedBox(height: 16),
              Text(
                'Conecta el anillo desde la pantalla de Inicio para poder medir.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
