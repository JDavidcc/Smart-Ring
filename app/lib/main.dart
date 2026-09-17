import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'features/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Sin esto, cualquier DateFormat con locale 'es' lanza excepción en ejecución.
  await initializeDateFormatting('es');
  runApp(const ProviderScope(child: SmartRingApp()));
}

class SmartRingApp extends StatelessWidget {
  const SmartRingApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4F6BED),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Anillo R21M',
      debugShowCheckedModeBanner: false,
      locale: const Locale('es'),
      supportedLocales: const [Locale('es'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 0,
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
      home: const HomeShell(),
    );
  }
}
