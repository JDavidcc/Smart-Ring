import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/models.dart';
import '../../state/providers.dart';

/// Colores por etapa. Se mantienen consistentes entre el hipnograma y la leyenda.
const _stageColors = {
  'deep': Color(0xFF3B4CCA),
  'light': Color(0xFF6C8BEF),
  'rem': Color(0xFF9B6CEF),
  'awake': Color(0xFFE0A33E),
};

const _stageLabels = {
  'deep': 'Profundo',
  'light': 'Ligero',
  'rem': 'REM',
  'awake': 'Despierto',
};

class SleepPage extends ConsumerWidget {
  const SleepPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sleepNightsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Sueño')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (nights) => nights.isEmpty
            ? const _Empty()
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: nights.length,
                itemBuilder: (_, i) => _NightCard(night: nights[i]),
              ),
      ),
    );
  }
}

class _NightCard extends StatelessWidget {
  const _NightCard({required this.night});

  final StoredSleepNight night;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fmt = DateFormat('HH:mm');
    final dayFmt = DateFormat('EEEE d MMM', 'es');

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(dayFmt.format(night.start), style: theme.textTheme.titleMedium),
            Text(
              '${fmt.format(night.start)} – ${fmt.format(night.end)} · '
              '${_dur(night.asleep)} dormido de ${_dur(night.totalInBed)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            _Hypnogram(night: night),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: _stageColors.keys.map((stage) {
                final d = night.durationOf(stage);
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _stageColors[stage],
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('${_stageLabels[stage]} ${_dur(d)}', style: theme.textTheme.bodySmall),
                  ],
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  static String _dur(Duration d) {
    if (d.inMinutes < 60) return '${d.inMinutes} min';
    return '${d.inHours} h ${d.inMinutes % 60} min';
  }
}

/// Barra proporcional con las etapas de la noche, en orden cronológico.
class _Hypnogram extends StatelessWidget {
  const _Hypnogram({required this.night});

  final StoredSleepNight night;

  @override
  Widget build(BuildContext context) {
    final total = night.segments.fold<int>(0, (s, e) => s + e.durationSeconds);
    if (total == 0) return const SizedBox.shrink();

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 28,
        child: Row(
          children: night.segments
              .map((s) => Expanded(
                    flex: s.durationSeconds.clamp(1, total),
                    child: Container(
                      color: _stageColors[s.stage] ?? Colors.grey,
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.bedtime_outlined, size: 48),
              SizedBox(height: 16),
              Text(
                'Sin datos de sueño.\n\nDuerme con el anillo puesto y luego '
                'sincroniza el historial desde la pestaña "Historial".',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
}
