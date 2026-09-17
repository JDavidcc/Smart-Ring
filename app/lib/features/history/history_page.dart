import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../state/providers.dart';

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  ReadingKind _kind = ReadingKind.heartRate;
  bool _syncing = false;

  Future<void> _sync() async {
    final ring = ref.read(ringControllerProvider);
    if (!ring.isConnected) {
      _toast('Conecta el anillo primero.');
      return;
    }
    setState(() => _syncing = true);
    try {
      final n = await ref.read(ringControllerProvider.notifier).syncHistory();
      ref.invalidate(readingsProvider);
      ref.invalidate(latestReadingProvider);
      ref.invalidate(sleepNightsProvider);
      _toast(n == 0
          ? 'El anillo no tiene historial guardado todavía.'
          : 'Se descargaron $n registros.');
    } catch (e) {
      _toast('Falló la sincronización: $e');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(readingsProvider(_kind));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Historial'),
        actions: [
          IconButton(
            icon: _syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            tooltip: 'Sincronizar con el anillo',
            onPressed: _syncing ? null : _sync,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: SegmentedButton<ReadingKind>(
              segments: ReadingKind.values
                  .map((k) => ButtonSegment(value: k, label: Text(_short(k))))
                  .toList(),
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
          ),
          Expanded(
            child: async.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
              data: (readings) => readings.isEmpty
                  ? _Empty(onSync: _sync)
                  : Column(
                      children: [
                        SizedBox(height: 240, child: _Chart(readings: readings, kind: _kind)),
                        const Divider(height: 1),
                        Expanded(child: _ReadingList(readings: readings)),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }

  static String _short(ReadingKind k) => switch (k) {
        ReadingKind.heartRate => 'Pulso',
        ReadingKind.spo2 => 'Oxígeno',
        ReadingKind.bloodPressure => 'Presión',
      };
}

class _Chart extends StatelessWidget {
  const _Chart({required this.readings, required this.kind});

  final List<Reading> readings;
  final ReadingKind kind;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Vienen ordenadas de más nueva a más vieja; para la gráfica las queremos al revés.
    final pts = readings.reversed
        .where((r) => r.primaryValue != null)
        .map((r) => FlSpot(r.takenAt.millisecondsSinceEpoch.toDouble(), r.primaryValue!))
        .toList();
    if (pts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
      child: LineChart(
        LineChartData(
          gridData: FlGridData(show: true, drawVerticalLine: false),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: true, reservedSize: 40),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 28,
                interval: (pts.last.x - pts.first.x).abs() / 3 + 1,
                getTitlesWidget: (v, meta) => Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    DateFormat('dd/MM').format(DateTime.fromMillisecondsSinceEpoch(v.toInt())),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ),
            ),
          ),
          lineBarsData: [
            LineChartBarData(
              spots: pts,
              isCurved: true,
              curveSmoothness: 0.2,
              barWidth: 2,
              color: theme.colorScheme.primary,
              dotData: FlDotData(show: pts.length < 30),
              belowBarData: BarAreaData(
                show: true,
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReadingList extends StatelessWidget {
  const _ReadingList({required this.readings});

  final List<Reading> readings;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd/MM/yyyy HH:mm');
    return ListView.builder(
      itemCount: readings.length,
      itemBuilder: (_, i) {
        final r = readings[i];
        return ListTile(
          dense: true,
          title: Text(r.display),
          subtitle: Text(fmt.format(r.takenAt)),
          trailing: Chip(
            label: Text(r.source == ReadingSource.live ? 'en vivo' : 'historial'),
            visualDensity: VisualDensity.compact,
          ),
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onSync});

  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.show_chart, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Todavía no hay datos.\n\nMide algo desde la pestaña "Medir", o '
                'sincroniza para traer lo que el anillo tenga guardado.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onSync, child: const Text('Sincronizar')),
            ],
          ),
        ),
      );
}
