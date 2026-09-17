import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../state/providers.dart';

class ActivityPage extends ConsumerWidget {
  const ActivityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final today = ref.watch(todayActivityProvider);
    final history = ref.watch(activityHistoryProvider);
    final ring = ref.watch(ringControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Actividad'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Leer del anillo',
            onPressed: !ring.isConnected
                ? null
                : () async {
                    try {
                      await ref.read(ringControllerProvider.notifier).refreshActivity();
                      ref.invalidate(todayActivityProvider);
                      ref.invalidate(activityHistoryProvider);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }
                  },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          today.maybeWhen(
            data: (a) => Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Text('Hoy', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 12),
                    Text(
                      '${a?.steps ?? 0}',
                      style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w300),
                    ),
                    Text('pasos', style: theme.textTheme.bodySmall),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _Stat(label: 'Distancia', value: '${a?.distanceMeters ?? 0} m'),
                        _Stat(label: 'Calorías', value: '${a?.calories ?? 0} kcal'),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            orElse: () => const Card(
              child: Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator())),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.25),
            child: const Padding(
              padding: EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.straighten, size: 20),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'La distancia no se mide: el anillo la calcula multiplicando los pasos '
                      'por una zancada fija de unos 0.63 m. Si tu zancada real es distinta, '
                      'la cifra estará escalada por igual en todos los días.',
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Días anteriores', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          history.maybeWhen(
            data: (days) => days.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Sin historial de actividad todavía.'),
                  )
                : Column(
                    children: days
                        .map((a) => ListTile(
                              dense: true,
                              title: Text(DateFormat('EEEE d MMM', 'es').format(a.day)),
                              subtitle: Text('${a.distanceMeters} m · ${a.calories} kcal'),
                              trailing: Text('${a.steps}', style: theme.textTheme.titleMedium),
                            ))
                        .toList(),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Text(value, style: theme.textTheme.titleLarge),
        Text(label, style: theme.textTheme.bodySmall),
      ],
    );
  }
}
