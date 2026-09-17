import 'dart:typed_data';

/// Capa de trama del protocolo YCBT. Puerto 1:1 de `tools/ringlab/ringlab/protocol.py`.
///
/// Formato:
///
///     [grupo:1][comando:1][longitud:2 LE][payload:*][crc16:2 LE]
///
/// La longitud declara el tamano TOTAL de la trama, cabecera y CRC incluidos.
/// Una longitud incorrecta hace que el anillo corte la conexion.
///
/// Verificado contra el anillo real: ver `docs/PROTOCOLO-R21M.md` seccion 3.

const int headerLen = 4;
const int crcLen = 2;
const int frameOverhead = headerLen + crcLen;

/// CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, sin reflexion, sin XOR final.
int crc16(List<int> buf) {
  var reg = 0xFFFF;
  for (final b in buf) {
    reg ^= (b & 0xFF) << 8;
    for (var i = 0; i < 8; i++) {
      reg = (reg & 0x8000) != 0 ? ((reg << 1) ^ 0x1021) & 0xFFFF : (reg << 1) & 0xFFFF;
    }
  }
  return reg;
}

class Frame {
  const Frame(this.group, this.command, this.payload);

  final int group;
  final int command;
  final Uint8List payload;

  /// Codigo compacto grupo<<8|comando, como en el catalogo del SDK.
  int get code => (group << 8) | command;

  @override
  String toString() => '${_hex2(group)}${_hex2(command)} <${hexOf(payload)}>';
}

class BadFrame implements Exception {
  BadFrame(this.message);
  final String message;
  @override
  String toString() => 'BadFrame: $message';
}

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0').toUpperCase();

String hexOf(List<int> b) => b.map(_hex2).join(' ');

Uint8List parseHex(String s) {
  final clean = s.replaceAll(RegExp(r'[\s:]'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Construye una trama completa lista para escribir en la caracteristica de comandos.
Uint8List buildFrame(int group, int command, [List<int> payload = const []]) {
  final total = frameOverhead + payload.length;
  final body = Uint8List(headerLen + payload.length)
    ..[0] = group
    ..[1] = command
    ..[2] = total & 0xFF
    ..[3] = (total >> 8) & 0xFF
    ..setRange(headerLen, headerLen + payload.length, payload);
  final crc = crc16(body);
  return Uint8List(total)
    ..setRange(0, body.length, body)
    ..[total - 2] = crc & 0xFF
    ..[total - 1] = (crc >> 8) & 0xFF;
}

/// Decodifica una trama completa. Lanza [BadFrame] si esta malformada.
Frame parseFrame(Uint8List raw, {bool verifyCrc = true}) {
  if (raw.length < frameOverhead) {
    throw BadFrame('trama demasiado corta (${raw.length} bytes): ${hexOf(raw)}');
  }
  final declared = raw[2] | (raw[3] << 8);
  if (declared != raw.length) {
    throw BadFrame('longitud declarada $declared != recibida ${raw.length}: ${hexOf(raw)}');
  }
  if (verifyCrc) {
    final expected = crc16(raw.sublist(0, raw.length - crcLen));
    final got = raw[raw.length - 2] | (raw[raw.length - 1] << 8);
    if (expected != got) {
      throw BadFrame('CRC ${_hex4(got)} != esperado ${_hex4(expected)}: ${hexOf(raw)}');
    }
  }
  return Frame(raw[0], raw[1], raw.sublist(headerLen, raw.length - crcLen));
}

String _hex4(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();

/// Reensambla tramas que llegan partidas en varias notificaciones.
///
/// Imprescindible: en iOS no se puede pedir MTU y el anillo negocia ~185 bytes,
/// asi que las respuestas de historial y los bloques de sueno (05 13) se parten.
class FrameReassembler {
  FrameReassembler({this.verifyCrc = true});

  final bool verifyCrc;
  final List<int> _buf = [];

  void reset() => _buf.clear();

  Uint8List get pending => Uint8List.fromList(_buf);

  /// Alimenta un fragmento y devuelve las tramas que hayan quedado completas.
  List<Frame> feed(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <Frame>[];
    while (_buf.length >= headerLen) {
      final declared = _buf[2] | (_buf[3] << 8);
      if (declared < frameOverhead) {
        // Cabecera sin sentido: descartamos un byte e intentamos resincronizar.
        _buf.removeAt(0);
        continue;
      }
      if (_buf.length < declared) break;
      final raw = Uint8List.fromList(_buf.sublist(0, declared));
      _buf.removeRange(0, declared);
      out.add(parseFrame(raw, verifyCrc: verifyCrc));
    }
    return out;
  }
}
