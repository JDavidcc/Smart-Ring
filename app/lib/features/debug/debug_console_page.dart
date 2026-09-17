import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../ble/ring_connection.dart';
import '../../protocol/commands.dart';
import '../../state/providers.dart';

/// El equivalente del CLI `ringlab` dentro de la app: ver todas las tramas que
/// entran y salen, y poder mandar comandos arbitrarios.
///
/// Es lo que permitirá resolver en campo lo que aún está pendiente del
/// protocolo (contador de actividad, formatos de historial) sin volver a
/// conectar el anillo a la PC.
class DebugConsolePage extends ConsumerStatefulWidget {
  const DebugConsolePage({super.key});

  @override
  ConsumerState<DebugConsolePage> createState() => _DebugConsolePageState();
}

class _DebugConsolePageState extends ConsumerState<DebugConsolePage> {
  final _entries = <TraceEntry>[];
  final _groupCtrl = TextEditingController(text: '02');
  final _cmdCtrl = TextEditingController(text: '00');
  final _payloadCtrl = TextEditingController(text: '4743');
  final _scroll = ScrollController();

  StreamSubscription<TraceEntry>? _sub;
  bool _hide2a37 = true;

  @override
  void initState() {
    super.initState();
    // Arrancamos con lo ya registrado: el buffer vive en el controlador y
    // sobrevive a salir de esta pantalla.
    _entries.addAll(ref.read(ringControllerProvider.notifier).traceHistory);

    final conn = ref.read(connectionProvider);
    _sub = conn?.trace.listen((e) {
      if (!mounted) return;
      setState(() {
        _entries.add(e);
        if (_entries.length > 2000) _entries.removeRange(0, 500);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _groupCtrl.dispose();
    _cmdCtrl.dispose();
    _payloadCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _sendRaw() async {
    final conn = ref.read(connectionProvider);
    if (conn == null) return;
    try {
      final group = int.parse(_groupCtrl.text.trim(), radix: 16);
      final cmd = int.parse(_cmdCtrl.text.trim(), radix: 16);
      final payloadText = _payloadCtrl.text.replaceAll(RegExp(r'\s'), '');
      final payload = <int>[];
      for (var i = 0; i + 1 < payloadText.length; i += 2) {
        payload.add(int.parse(payloadText.substring(i, i + 2), radix: 16));
      }
      await conn.send(frameOf((group << 8) | cmd, payload));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Trama inválida: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final conn = ref.watch(connectionProvider);
    final visible =
        _hide2a37 ? _entries.where((e) => e.label != '2a37').toList() : _entries;
    final fmt = DateFormat('HH:mm:ss.SSS');
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Consola de tramas'),
        actions: [
          IconButton(
            tooltip: 'Leer info del anillo (02 00)',
            icon: const Icon(Icons.battery_std),
            onPressed: conn == null
                ? null
                : () async {
                    // Atajo deliberado: permite hacer la lectura SIN salir de
                    // esta pantalla, que es donde se ve el diálogo crudo.
                    try {
                      await ref.read(ringControllerProvider.notifier).refreshInfo();
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Falló la lectura: $e')),
                        );
                      }
                    }
                  },
          ),
          IconButton(
            tooltip: _hide2a37 ? 'Mostrar ruido de 2a37' : 'Ocultar ruido de 2a37',
            icon: Icon(_hide2a37 ? Icons.filter_alt : Icons.filter_alt_off),
            onPressed: () => setState(() => _hide2a37 = !_hide2a37),
          ),
          IconButton(
            tooltip: 'Copiar todo',
            icon: const Icon(Icons.copy_all),
            onPressed: () {
              final text = visible
                  .map((e) => '${fmt.format(e.at)} ${e.outgoing ? "→" : "←"} '
                      '${e.label} ${e.hex}${e.note != null ? "  // ${e.note}" : ""}')
                  .join('\n');
              Clipboard.setData(ClipboardData(text: text));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Copiado al portapapeles')));
            },
          ),
          IconButton(
            tooltip: 'Limpiar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(_entries.clear),
          ),
        ],
      ),
      body: conn == null
          ? const Center(child: Text('Sin conexión con el anillo.'))
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scroll,
                    itemCount: visible.length,
                    itemBuilder: (_, i) {
                      final e = visible[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                        child: DefaultTextStyle(
                          style: theme.textTheme.bodySmall!.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(fmt.format(e.at), style: TextStyle(color: theme.disabledColor)),
                                  const SizedBox(width: 8),
                                  Text(
                                    e.outgoing ? '→' : '←',
                                    style: TextStyle(
                                      color: e.outgoing
                                          ? theme.colorScheme.tertiary
                                          : theme.colorScheme.primary,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text('${e.label}  ${e.hex}')),
                                ],
                              ),
                              if (e.note != null)
                                Padding(
                                  padding: const EdgeInsets.only(left: 96),
                                  child: Text(e.note!,
                                      style: TextStyle(color: theme.colorScheme.error)),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 56,
                        child: TextField(
                          controller: _groupCtrl,
                          decoration: const InputDecoration(labelText: 'Grp', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 56,
                        child: TextField(
                          controller: _cmdCtrl,
                          decoration: const InputDecoration(labelText: 'Cmd', isDense: true),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _payloadCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Payload hex',
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(onPressed: _sendRaw, icon: const Icon(Icons.send)),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
