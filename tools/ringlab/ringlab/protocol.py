"""Capa de trama del protocolo YCBT (SDK Yucheng, anillos de la familia SmartHealth).

Sin dependencias de BLE a proposito: esto se porta 1:1 a Dart en la Etapa 2 y
debe poder probarse contra las tramas capturadas en `capturas/`.

Formato de trama:

    [grupo:1][cmd:1][longitud:2 LE][payload:*][crc16:2 LE]

La longitud declara el tamano TOTAL de la trama, cabecera y CRC incluidos.
Una longitud incorrecta hace que el anillo corte la conexion.
"""

from __future__ import annotations

from dataclasses import dataclass

HEADER_LEN = 4
CRC_LEN = 2
OVERHEAD = HEADER_LEN + CRC_LEN


def crc16(buf: bytes) -> int:
    """CRC-16/CCITT-FALSE: poly 0x1021, init 0xFFFF, sin reflexion, sin XOR final."""
    reg = 0xFFFF
    for b in buf:
        reg ^= b << 8
        for _ in range(8):
            reg = ((reg << 1) ^ 0x1021) & 0xFFFF if reg & 0x8000 else (reg << 1) & 0xFFFF
    return reg


@dataclass(frozen=True)
class Frame:
    group: int
    command: int
    payload: bytes
    # Bytes originales completos (cabecera + payload + CRC). Se conservan para
    # poder usarlos como fixtures byte a byte en las pruebas del puerto a Dart.
    raw: bytes = b""

    @property
    def code(self) -> int:
        """Codigo compacto grupo<<8|cmd, como se usa en el catalogo del SDK."""
        return (self.group << 8) | self.command

    def __str__(self) -> str:
        return f"{self.group:02X}{self.command:02X} <{self.payload.hex(' ').upper() or '-'}>"


def build_frame(group: int, command: int, payload: bytes = b"") -> bytes:
    """Construye una trama completa lista para escribir en la caracteristica de comandos."""
    total = OVERHEAD + len(payload)
    body = bytes([group, command]) + total.to_bytes(2, "little") + payload
    return body + crc16(body).to_bytes(2, "little")


class BadFrame(ValueError):
    pass


def parse_frame(raw: bytes, *, verify_crc: bool = True) -> Frame:
    """Decodifica una trama completa. Lanza BadFrame si esta malformada."""
    if len(raw) < OVERHEAD:
        raise BadFrame(f"trama demasiado corta ({len(raw)} bytes): {raw.hex(' ').upper()}")
    declared = int.from_bytes(raw[2:4], "little")
    if declared != len(raw):
        raise BadFrame(
            f"longitud declarada {declared} != recibida {len(raw)}: {raw.hex(' ').upper()}"
        )
    if verify_crc:
        expected = crc16(raw[:-CRC_LEN])
        got = int.from_bytes(raw[-CRC_LEN:], "little")
        if expected != got:
            raise BadFrame(f"CRC {got:04X} != esperado {expected:04X}: {raw.hex(' ').upper()}")
    return Frame(raw[0], raw[1], raw[HEADER_LEN:-CRC_LEN], raw)


class FrameReassembler:
    """Reensambla tramas que llegan partidas en varias notificaciones.

    Con MTU bajo (y en iOS, donde no se puede pedir MTU) las respuestas de
    historial y sobre todo los bloques de sueno (05 13) se parten. Se acumula
    hasta completar la longitud declarada en la cabecera.
    """

    def __init__(self, *, verify_crc: bool = True) -> None:
        self._buf = bytearray()
        self._verify_crc = verify_crc

    def reset(self) -> None:
        self._buf.clear()

    @property
    def pending(self) -> bytes:
        return bytes(self._buf)

    def feed(self, chunk: bytes) -> list[Frame]:
        """Alimenta un fragmento y devuelve las tramas que hayan quedado completas."""
        self._buf.extend(chunk)
        out: list[Frame] = []
        while len(self._buf) >= HEADER_LEN:
            declared = int.from_bytes(self._buf[2:4], "little")
            if declared < OVERHEAD:
                # Cabecera sin sentido: descartamos un byte y reintentamos resincronizar.
                del self._buf[0]
                continue
            if len(self._buf) < declared:
                break
            raw = bytes(self._buf[:declared])
            del self._buf[:declared]
            out.append(parse_frame(raw, verify_crc=self._verify_crc))
        return out
