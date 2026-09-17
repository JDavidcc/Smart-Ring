"""Cliente BLE del anillo sobre bleak, con registro completo de tramas.

Todo lo que entra y sale se escribe a capturas/*.jsonl: ese corpus es lo que luego
alimenta las pruebas del puerto a Dart en la Etapa 2.
"""

from __future__ import annotations

import asyncio
import contextlib
import datetime as _dt
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

from bleak import BleakClient, BleakScanner
from bleak.backends.characteristic import BleakGATTCharacteristic
from bleak.backends.device import BLEDevice
from bleak.backends.scanner import AdvertisementData

from . import commands as cmd
from . import decoders
from .protocol import BadFrame, Frame, FrameReassembler, parse_frame

# Identificadores parciales de las caracteristicas segun la documentacion del R11M.
# Se resuelven por coincidencia de subcadena porque no conocemos el UUID 128-bit completo.
CH_COMMAND = "be940001"  # escritura de comandos (y probablemente respuestas)
CH_NOTIFY = "be940003"  # notificaciones iniciadas por el anillo
CH_ACTIVITY = "fea1"  # actividad en vivo (~2 s)
CH_HEART_SIG = "2a37"  # Heart Rate Measurement estandar

DEFAULT_NAME_PREFIX = "R21M"
CAPTURES_DIR = Path(__file__).resolve().parents[1] / "capturas"


def _now() -> str:
    return _dt.datetime.now().isoformat(timespec="milliseconds")


@dataclass
class Found:
    device: BLEDevice
    rssi: int
    raw_adv: bytes
    adv: decoders.Advertisement


def _rebuild_adv_payload(data: AdvertisementData) -> bytes:
    """Reconstruye el payload crudo del advertisement a partir de lo que expone bleak.

    bleak ya parsea el advertisement y no entrega los bytes originales, asi que los
    re-serializamos en formato longitud/tipo/valor para poder pasarlos por el mismo
    decodificador que usamos con el archivo de lecturas.
    """
    out = bytearray()

    def put(type_id: int, payload: bytes) -> None:
        out.append(len(payload) + 1)
        out.append(type_id)
        out.extend(payload)

    uuids16 = bytearray()
    for u in data.service_uuids:
        s = u.lower()
        if s.endswith("-0000-1000-8000-00805f9b34fb"):
            uuids16.extend(int(s[4:8], 16).to_bytes(2, "little"))
    if uuids16:
        put(0x03, bytes(uuids16))
    if data.local_name:
        put(0x09, data.local_name.encode())
    for company, blob in data.manufacturer_data.items():
        put(0xFF, company.to_bytes(2, "little") + bytes(blob))
    return bytes(out)


async def scan(seconds: float = 8.0, name_prefix: str | None = DEFAULT_NAME_PREFIX) -> list[Found]:
    """Escanea y devuelve los dispositivos que coincidan, con el advertisement decodificado."""
    seen: dict[str, Found] = {}

    def on_found(device: BLEDevice, data: AdvertisementData) -> None:
        name = data.local_name or device.name or ""
        if name_prefix and not name.upper().startswith(name_prefix.upper()):
            return
        raw = _rebuild_adv_payload(data)
        seen[device.address] = Found(device, data.rssi, raw, decoders.decode_advertisement(raw))

    scanner = BleakScanner(detection_callback=on_found)
    await scanner.start()
    try:
        await asyncio.sleep(seconds)
    finally:
        await scanner.stop()
    return list(seen.values())


class TraceLog:
    """Escribe cada trama tx/rx a un jsonl y opcionalmente la muestra por consola."""

    def __init__(self, path: Path | None, on_line: Callable[[dict[str, Any]], None] | None = None):
        self.path = path
        self._fh = None
        self._on_line = on_line
        if path:
            path.parent.mkdir(parents=True, exist_ok=True)
            self._fh = path.open("a", encoding="utf-8")

    def write(self, record: dict[str, Any]) -> None:
        record = {"t": _now(), **record}
        if self._fh:
            try:
                self._fh.write(json.dumps(record, ensure_ascii=False) + "\n")
                self._fh.flush()
            except Exception:  # noqa: BLE001
                pass
        if self._on_line:
            # La presentacion nunca debe tumbar el manejo del protocolo: si la consola
            # esta cerrada (tuberia rota) o el formateo falla, se ignora en silencio.
            try:
                self._on_line(record)
            except Exception:  # noqa: BLE001
                self._on_line = None

    def close(self) -> None:
        if self._fh:
            self._fh.close()
            self._fh = None


class RingClient:
    def __init__(
        self,
        address: str,
        *,
        trace: TraceLog | None = None,
        verify_crc: bool = True,
    ) -> None:
        self.address = address
        self.trace = trace or TraceLog(None)
        self._verify_crc = verify_crc
        self._client = BleakClient(address)
        self._chars: dict[str, BleakGATTCharacteristic] = {}
        self._reassemblers: dict[str, FrameReassembler] = {}
        self._waiters: list[tuple[int | None, asyncio.Future]] = []
        self._frames: asyncio.Queue[tuple[str, Frame]] = asyncio.Queue()

    # --- conexion ---------------------------------------------------------

    async def __aenter__(self) -> "RingClient":
        await self._client.connect()
        self.trace.write({"dir": "sys", "evento": "conectado", "mtu": self.mtu})
        self._resolve_chars()
        await self._subscribe_all()
        return self

    async def __aexit__(self, *exc: Any) -> None:
        with contextlib.suppress(Exception):
            await self._client.disconnect()
        self.trace.write({"dir": "sys", "evento": "desconectado"})
        self.trace.close()

    @property
    def mtu(self) -> int:
        try:
            return self._client.mtu_size
        except Exception:
            return -1

    @property
    def services(self):
        return self._client.services

    def _resolve_chars(self) -> None:
        for service in self._client.services:
            for ch in service.characteristics:
                u = ch.uuid.lower()
                for token in (CH_COMMAND, CH_NOTIFY, CH_ACTIVITY, CH_HEART_SIG):
                    if token in u and token not in self._chars:
                        self._chars[token] = ch

    def has(self, token: str) -> bool:
        return token in self._chars

    def missing(self, tokens: Iterable[str]) -> list[str]:
        return [t for t in tokens if t not in self._chars]

    async def _subscribe_all(self) -> None:
        for token, ch in self._chars.items():
            props = set(ch.properties)
            if not props & {"notify", "indicate"}:
                continue
            try:
                await self._client.start_notify(ch, self._make_handler(token))
                self.trace.write({"dir": "sys", "evento": "suscrito", "char": token, "uuid": ch.uuid})
            except Exception as exc:  # noqa: BLE001 - queremos seguir con las demas
                self.trace.write(
                    {"dir": "sys", "evento": "fallo_suscripcion", "char": token, "error": str(exc)}
                )

    # --- recepcion --------------------------------------------------------

    def _make_handler(self, token: str):
        def handler(_ch: BleakGATTCharacteristic, data: bytearray) -> None:
            self._on_notify(token, bytes(data))

        return handler

    def _on_notify(self, token: str, data: bytes) -> None:
        # fea1 y 2a37 no usan el formato de trama: van crudas.
        if token in (CH_ACTIVITY, CH_HEART_SIG):
            record: dict[str, Any] = {"dir": "rx", "char": token, "hex": data.hex(" ").upper()}
            if token == CH_ACTIVITY:
                record["decodificado"] = decoders.decode_activity(data)
            else:
                record["decodificado"] = _decode_hrm(data)
            self.trace.write(record)
            return

        reasm = self._reassemblers.setdefault(token, FrameReassembler(verify_crc=self._verify_crc))
        try:
            frames = reasm.feed(data)
        except BadFrame as exc:
            self.trace.write(
                {"dir": "rx", "char": token, "hex": data.hex(" ").upper(), "error": str(exc)}
            )
            reasm.reset()
            return

        if not frames:
            self.trace.write(
                {
                    "dir": "rx",
                    "char": token,
                    "hex": data.hex(" ").upper(),
                    "nota": "fragmento, esperando resto",
                }
            )
            return

        for fr in frames:
            # El despacho va PRIMERO: encolar y despertar a quien espera no puede quedar
            # a merced de que la traza o el formateo fallen.
            self._frames.put_nowait((token, fr))
            self._resolve_waiters(fr)
            self.trace.write(
                {
                    "dir": "rx",
                    "char": token,
                    "codigo": f"{fr.code:04X}",
                    "nombre": cmd.name_of(fr.code),
                    "payload": fr.payload.hex(" ").upper(),
                    # Trama completa con CRC: sirve tal cual como fixture en las
                    # pruebas del puerto a Dart.
                    "trama": fr.raw.hex(" ").upper(),
                    "decodificado": decoders.decode_payload(fr.code, fr.payload),
                }
            )

    def _resolve_waiters(self, fr: Frame) -> None:
        still: list[tuple[int | None, asyncio.Future]] = []
        for want, fut in self._waiters:
            if not fut.done() and (want is None or want == fr.code):
                fut.set_result(fr)
            elif not fut.done():
                still.append((want, fut))
        self._waiters = still

    async def next_frame(self, timeout: float = 5.0) -> tuple[str, Frame]:
        return await asyncio.wait_for(self._frames.get(), timeout)

    async def wait_for(self, code: int | None, timeout: float = 10.0) -> Frame:
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._waiters.append((code, fut))
        try:
            return await asyncio.wait_for(fut, timeout)
        finally:
            self._waiters = [(c, f) for c, f in self._waiters if f is not fut]

    # --- envio ------------------------------------------------------------

    async def send(self, raw: bytes) -> None:
        ch = self._chars.get(CH_COMMAND)
        if ch is None:
            raise RuntimeError(
                f"no se encontro la caracteristica de comandos ({CH_COMMAND}); "
                "corre `gatt-dump` para ver los UUID reales del R21M"
            )
        fr = parse_frame(raw, verify_crc=False)
        self.trace.write(
            {
                "dir": "tx",
                "char": CH_COMMAND,
                "codigo": f"{fr.code:04X}",
                "nombre": cmd.name_of(fr.code),
                "hex": raw.hex(" ").upper(),
            }
        )
        # be940001 admite ambos modos; preferimos write-con-respuesta porque el anillo
        # corta la conexion ante tramas mal formadas y asi al menos sabemos que llego.
        await self._client.write_gatt_char(ch, raw, response="write" in ch.properties)

    async def request(self, raw: bytes, *, timeout: float = 10.0) -> Frame:
        """Envia una trama y espera la respuesta con el mismo grupo/comando."""
        fr = parse_frame(raw, verify_crc=False)
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._waiters.append((fr.code, fut))
        try:
            await self.send(raw)
            return await asyncio.wait_for(fut, timeout)
        finally:
            self._waiters = [(c, f) for c, f in self._waiters if f is not fut]

    async def collect(self, seconds: float) -> list[tuple[str, Frame]]:
        """Recoge todas las tramas que lleguen durante una ventana de tiempo."""
        out: list[tuple[str, Frame]] = []
        deadline = asyncio.get_running_loop().time() + seconds
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                return out
            try:
                out.append(await asyncio.wait_for(self._frames.get(), remaining))
            except asyncio.TimeoutError:
                return out


def _decode_hrm(data: bytes) -> dict[str, Any]:
    """Heart Rate Measurement estandar (0x2A37).

    Nota del R11M: esta caracteristica reemite valores viejos cada ~90 s y su bit de
    contacto con la piel no es fiable. La fuente de verdad son las tramas 06 01.
    """
    if not data:
        return {}
    flags = data[0]
    wide = bool(flags & 0x01)
    bpm = int.from_bytes(data[1:3], "little") if wide else data[1] if len(data) > 1 else None
    return {
        "bpm": bpm,
        "flags": f"0x{flags:02X}",
        "contacto_soportado": bool(flags & 0x04),
        "contacto_detectado": bool(flags & 0x02),
    }
