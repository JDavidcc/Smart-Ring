import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'activity/activity_page.dart';
import 'dashboard/dashboard_page.dart';
import 'debug/debug_console_page.dart';
import 'history/history_page.dart';
import 'measure/measure_page.dart';
import 'sleep/sleep_page.dart';

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    // Intento silencioso de reconectar con el último anillo usado.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(ringControllerProvider.notifier).reconnectLast();
    });
  }

  static const _pages = <Widget>[
    DashboardPage(),
    MeasurePage(),
    HistoryPage(),
    SleepPage(),
    ActivityPage(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _pages),
      floatingActionButton: _index == 0
          ? FloatingActionButton.small(
              tooltip: 'Consola de tramas',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const DebugConsolePage()),
              ),
              child: const Icon(Icons.terminal),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Inicio'),
          NavigationDestination(icon: Icon(Icons.favorite_outline), selectedIcon: Icon(Icons.favorite), label: 'Medir'),
          NavigationDestination(icon: Icon(Icons.show_chart), label: 'Historial'),
          NavigationDestination(icon: Icon(Icons.bedtime_outlined), selectedIcon: Icon(Icons.bedtime), label: 'Sueño'),
          NavigationDestination(icon: Icon(Icons.directions_walk), label: 'Actividad'),
        ],
      ),
    );
  }
}
