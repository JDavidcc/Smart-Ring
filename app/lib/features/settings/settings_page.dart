import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../protocol/commands.dart';
import '../../state/providers.dart';

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _hrAuto = false;
  int _hrMinutes = 30;
  bool _spo2Auto = false;
  int _spo2Minutes = 60;
  bool _exporting = false;

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final ring = ref.watch(ringControllerProvider);
    final conn = ref.watch(connectionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: ListView(
        children: [
          const _SectionHeader('Anillo'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Estado'),
            subtitle: Text(ring.isConnected
                ? '${ring.deviceName ?? "Conectado"} · batería ${ring.info?.batteryPct ?? "?"} % · MTU ${ring.mtu}'
                : 'Sin conexión'),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Sincronizar la hora'),
            subtitle: const Text(
              'El reloj del anillo no avanza solo: conserva la última hora escrita. '
              'La app lo sincroniza en cada conexión.',
            ),
            trailing: const Icon(Icons.chevron_right),
            enabled: ring.isConnected,
            onTap: !ring.isConnected
                ? null
                : () async {
                    try {
                      await conn!.syncTime();
                      _toast('Hora sincronizada.');
                    } catch (e) {
                      _toast('$e');
                    }
                  },
          ),

          const _SectionHeader('Medición automática'),
          SwitchListTile(
            secondary: const Icon(Icons.favorite_outline),
            title: const Text('Ritmo cardíaco automático'),
            subtitle: Text('Cada $_hrMinutes minutos'),
            value: _hrAuto,
            onChanged: !ring.isConnected
                ? null
                : (v) async {
                    setState(() => _hrAuto = v);
                    try {
                      await conn!.send(setHeartMonitor(enabled: v, minutes: _hrMinutes));
                      _toast(v ? 'Activado.' : 'Desactivado.');
                    } catch (e) {
                      _toast('$e');
                    }
                  },
          ),
          if (_hrAuto)
            _IntervalSlider(
              value: _hrMinutes,
              onChanged: (v) => setState(() => _hrMinutes = v),
              onDone: (v) async {
                try {
                  await conn!.send(setHeartMonitor(enabled: true, minutes: v));
                } catch (_) {}
              },
            ),
          SwitchListTile(
            secondary: const Icon(Icons.water_drop_outlined),
            title: const Text('Oxígeno automático'),
            subtitle: Text('Cada $_spo2Minutes minutos'),
            value: _spo2Auto,
            onChanged: !ring.isConnected
                ? null
                : (v) async {
                    setState(() => _spo2Auto = v);
                    try {
                      await conn!.send(setSpo2Monitor(enabled: v, minutes: _spo2Minutes));
                      _toast(v ? 'Activado.' : 'Desactivado.');
                    } catch (e) {
                      _toast('$e');
                    }
                  },
          ),
          if (_spo2Auto)
            _IntervalSlider(
              value: _spo2Minutes,
              onChanged: (v) => setState(() => _spo2Minutes = v),
              onDone: (v) async {
                try {
                  await conn!.send(setSpo2Monitor(enabled: true, minutes: v));
                } catch (_) {}
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Estos ajustes se envían al anillo pero aún no se han verificado contra '
              'este modelo. Si no surten efecto, revísalo en la consola de tramas.',
              style: theme.textTheme.bodySmall,
            ),
          ),

          const _SectionHeader('Tus datos'),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Exportar a CSV y JSON'),
            subtitle: const Text('Un CSV por métrica más un JSON con todo'),
            trailing: _exporting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _exporting
                ? null
                : () async {
                    setState(() => _exporting = true);
                    try {
                      final exporter = await ref.read(exporterProvider.future);
                      await exporter.exportAndShare();
                    } catch (e) {
                      _toast('No se pudo exportar: $e');
                    } finally {
                      if (mounted) setState(() => _exporting = false);
                    }
                  },
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Todos tus datos se guardan solo en este dispositivo. La app no tiene '
              'servidor, no crea cuentas y no envía nada a internet: únicamente salen '
              'de aquí cuando tú los compartes desde esta pantalla.',
              style: theme.textTheme.bodySmall,
            ),
          ),

          const _SectionHeader('Acerca de'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            child: Text(
              'Anillo R21M (familia SmartHealth, SDK Yucheng YCBT).\n'
              'Protocolo obtenido por ingeniería inversa y verificado contra el propio '
              'anillo; lo que sigue sin confirmar está marcado como tal en la '
              'documentación del proyecto.\n\n'
              'Las lecturas de este anillo son de consumo, no de grado médico. '
              'La presión arterial en particular es una estimación óptica.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _IntervalSlider extends StatelessWidget {
  const _IntervalSlider({required this.value, required this.onChanged, required this.onDone});

  final int value;
  final ValueChanged<int> onChanged;
  final ValueChanged<int> onDone;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Slider(
          value: value.toDouble(),
          min: 5,
          max: 120,
          divisions: 23,
          label: '$value min',
          onChanged: (v) => onChanged(v.round()),
          onChangeEnd: (v) => onDone(v.round()),
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
        child: Text(
          text.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                letterSpacing: 1.2,
              ),
        ),
      );
}
