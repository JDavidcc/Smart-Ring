"""Decodificadores de advertisement y de payloads.

Igual que commands.py, los formatos de payload vienen del R11M y estan SIN VERIFICAR
contra el R21M. Cuando un formato es dudoso, el decodificador devuelve tambien el hex
crudo y las interpretaciones candidatas, para poder decidir mirando datos reales en
lugar de adivinar.
"""

from __future__ import annotations

import datetime as _dt
from dataclasses import dataclass, field
from typing import Any

from . import commands as cmd

# El anillo cuenta segundos desde 2000-01-01 (hipotesis tomada del R11M).
EPOCH_2000 = _dt.datetime(2000, 1, 1, tzinfo=_dt.timezone.utc)

# Firma del advertisement del R21M, tal como aparece en lecturas-ble/.
YUCHENG_COMPANY_ID = 0x7810
YUCHENG_MFR_LEN = 27


def ts_from_device(seconds: int) -> _dt.datetime:
    return EPOCH_2000 + _dt.timedelta(seconds=seconds)


def u16(b: bytes, off: int = 0) -> int:
    return int.from_bytes(b[off : off + 2], "little")


def u24(b: bytes, off: int = 0) -> int:
    return int.from_bytes(b[off : off + 3], "little")


def u32(b: bytes, off: int = 0) -> int:
    return int.from_bytes(b[off : off + 4], "little")


# --- Advertisement ----------------------------------------------------------

AD_TYPES = {
    0x01: "Flags",
    0x02: "UUIDs 16-bit incompletos",
    0x03: "UUIDs 16-bit completos",
    0x06: "UUIDs 128-bit incompletos",
    0x07: "UUIDs 128-bit completos",
    0x08: "Nombre corto",
    0x09: "Nombre completo",
    0x0A: "TX power",
    0x16: "Service data 16-bit",
    0xFF: "Manufacturer specific",
}


@dataclass
class AdStructure:
    type_id: int
    data: bytes

    @property
    def type_name(self) -> str:
        return AD_TYPES.get(self.type_id, f"tipo 0x{self.type_id:02X}")


@dataclass
class Advertisement:
    structures: list[AdStructure] = field(default_factory=list)
    name: str | None = None
    service_uuids16: list[int] = field(default_factory=list)
    company_id: int | None = None
    manufacturer_data: bytes = b""
    mac: str | None = None
    battery_guess: int | None = None


def decode_advertisement(raw: bytes) -> Advertisement:
    """Decodifica el payload completo de un advertisement BLE (formato longitud/tipo/valor)."""
    adv = Advertisement()
    i = 0
    while i < len(raw):
        length = raw[i]
        if length == 0 or i + 1 + length > len(raw):
            break
        type_id = raw[i + 1]
        data = raw[i + 2 : i + 1 + length]
        adv.structures.append(AdStructure(type_id, data))

        if type_id in (0x08, 0x09):
            adv.name = data.decode("utf-8", errors="replace")
        elif type_id in (0x02, 0x03):
            adv.service_uuids16 = [u16(data, o) for o in range(0, len(data) - 1, 2)]
        elif type_id == 0xFF and len(data) >= 2:
            adv.company_id = u16(data)
            adv.manufacturer_data = data[2:]

        i += 1 + length

    # Solo interpretamos el manufacturer data si es el de nuestro fabricante y del
    # tamano observado; si no, las posiciones no significan nada.
    md = adv.manufacturer_data
    if adv.company_id == YUCHENG_COMPANY_ID and len(md) == YUCHENG_MFR_LEN:
        # Los ultimos 6 bytes son el MAC en orden natural (confirmado en las lecturas).
        adv.mac = ":".join(f"{b:02X}" for b in md[-6:])
        # Hipotesis: md[18] == 0x64 == 100 % de bateria. A confirmar contra GetDeviceInfo.
        adv.battery_guess = md[18]
    return adv


# --- Payloads ---------------------------------------------------------------


# Byte 4 de la respuesta 02 00. La doc del R11M solo documenta 00 y 01, pero el R21M
# devuelve 02, asi que no lo traducimos a un booleano de "cargando": se reporta crudo.
BATTERY_STATE = {0x00: "fuera del cargador", 0x01: "cargando"}


def decode_device_info(payload: bytes) -> dict[str, Any]:
    """Respuesta de 02 00. Segun el R11M: byte 4 estado de carga, byte 5 bateria %."""
    out: dict[str, Any] = {"hex": payload.hex(" ").upper(), "len": len(payload)}
    if len(payload) > 5:
        out["bateria_pct"] = payload[5]
        out["estado_bateria_raw"] = payload[4]
        out["estado_bateria"] = BATTERY_STATE.get(payload[4], f"sin documentar (0x{payload[4]:02X})")
    ascii_text = "".join(chr(b) if 32 <= b < 127 else "." for b in payload)
    out["ascii"] = ascii_text
    return out


def decode_activity(payload: bytes) -> dict[str, Any]:
    """Contador de actividad (respuesta de 02 0C). VERIFICADO.

        [pasos u24 LE][calorias u16 LE][distancia_m u24 LE][6 bytes en cero]

    Resuelto con dos lecturas reales separadas por ~100 pasos caminados:

        tras ~50 pasos:   52 00 00 | 03 00 | 34 00 00   -> 82 pasos, 3 kcal, 52 m
        tras ~150 pasos:  C3 00 00 | 08 00 | 7B 00 00   -> 195 pasos, 8 kcal, 123 m

    La prueba no fue que un campo se pareciera a lo caminado, sino que la razon
    distancia/pasos es constante entre lecturas (0.634 y 0.631): la distancia se
    deriva de los pasos con una zancada de ~0.635 m. Un contador independiente no
    mantendria esa proporcion.

    La doc del R11M acerto la posicion de los pasos pero invirtio distancia y
    calorias, y los leia con anchos equivocados.
    """
    out: dict[str, Any] = {"hex": payload.hex(" ").upper(), "len": len(payload)}
    if len(payload) >= 8:
        pasos = u24(payload, 0)
        distancia = u24(payload, 5)
        out["pasos"] = pasos
        out["calorias"] = u16(payload, 3)
        out["distancia_m"] = distancia
        if pasos:
            out["zancada_m"] = round(distancia / pasos, 3)
    return out


def locate_value(payload: bytes, expected: int, tolerance: int = 0) -> list[dict[str, Any]]:
    """Busca `expected` en todas las posiciones y anchuras razonables del payload.

    Con una cifra conocida (p. ej. haber caminado 50 pasos contados) esto resuelve
    de un golpe en que offset y con que ancho vive el campo, en lugar de adivinar
    entre interpretaciones candidatas.
    """
    hits: list[dict[str, Any]] = []
    for width, reader in ((1, lambda b, o: b[o]), (2, u16), (3, u24), (4, u32)):
        for off in range(0, len(payload) - width + 1):
            try:
                value = reader(payload, off)
            except IndexError:
                continue
            if abs(value - expected) <= tolerance:
                hits.append(
                    {
                        "offset": off,
                        "ancho": width,
                        "endian": "little",
                        "valor": value,
                        "bytes": payload[off : off + width].hex(" ").upper(),
                    }
                )
    return hits


def decode_live_heart(payload: bytes) -> dict[str, Any]:
    return {"bpm": payload[0] if payload else None, "hex": payload.hex(" ").upper()}


def decode_live_spo2(payload: bytes) -> dict[str, Any]:
    return {"spo2_pct": payload[0] if payload else None, "hex": payload.hex(" ").upper()}


def decode_live_blood(payload: bytes) -> dict[str, Any]:
    out: dict[str, Any] = {"hex": payload.hex(" ").upper()}
    if len(payload) >= 2:
        out["sistolica"] = payload[0]
        out["diastolica"] = payload[1]
    if len(payload) >= 3:
        # La doc del R11M lo deja como "unknown". En nuestras capturas vale 78-80
        # mientras el pulso medido por separado era 75-76: casi con seguridad es la
        # frecuencia cardiaca tomada durante la medicion. Marcado como probable.
        out["pulso_probable"] = payload[2]
    return out


MEASURE_RESULT = {0x01: "medido", 0x02: "anillo no puesto"}


def decode_measure_done(payload: bytes) -> dict[str, Any]:
    out: dict[str, Any] = {"hex": payload.hex(" ").upper()}
    if len(payload) >= 2:
        out["tipo"] = payload[0]
        out["resultado_raw"] = payload[1]
        out["resultado"] = MEASURE_RESULT.get(payload[1], f"desconocido 0x{payload[1]:02X}")
    return out


def decode_stored_heart(payload: bytes) -> dict[str, Any]:
    out: dict[str, Any] = {"hex": payload.hex(" ").upper()}
    if len(payload) >= 6:
        out["cuando"] = ts_from_device(u32(payload)).isoformat()
        out["bpm"] = payload[5]
    return out


def decode_stored_blood(payload: bytes) -> dict[str, Any]:
    out: dict[str, Any] = {"hex": payload.hex(" ").upper()}
    if len(payload) >= 7:
        out["cuando"] = ts_from_device(u32(payload)).isoformat()
        out["sistolica"] = payload[5]
        out["diastolica"] = payload[6]
    return out


def decode_stored_spo2(payload: bytes) -> dict[str, Any]:
    out: dict[str, Any] = {"hex": payload.hex(" ").upper()}
    if len(payload) >= 9:
        out["cuando"] = ts_from_device(u32(payload)).isoformat()
        out["spo2_pct"] = payload[8]
    return out


SLEEP_STAGES = {0xF1: "profundo", 0xF2: "ligero", 0xF3: "REM", 0xF4: "despierto"}


def decode_sleep(blob: bytes) -> dict[str, Any]:
    """Decodifica un bloque de sueno ya reensamblado (todos los pushes 05 13 concatenados).

    Cabecera de 20 bytes por noche (empieza con AF FA), luego entradas de 8 bytes:
    [tipo:1][inicio uint32 LE][duracion uint24 LE].
    """
    out: dict[str, Any] = {"len": len(blob), "noches": []}
    i = 0
    while i + 20 <= len(blob):
        if blob[i : i + 2] != b"\xaf\xfa":
            i += 1
            continue
        size = u16(blob, i + 2)
        if size < 20 or i + size > len(blob):
            out["truncado_en"] = i
            break
        rec = blob[i : i + size]
        noche: dict[str, Any] = {
            "inicio": ts_from_device(u32(rec, 4)).isoformat(),
            "fin": ts_from_device(u32(rec, 8)).isoformat(),
            "cabecera_hex": rec[:20].hex(" ").upper(),
            "etapas": [],
        }
        for off in range(20, size - 7, 8):
            e = rec[off : off + 8]
            noche["etapas"].append(
                {
                    "tipo": SLEEP_STAGES.get(e[0], f"0x{e[0]:02X}"),
                    "inicio": ts_from_device(u32(e, 1)).isoformat(),
                    "duracion_s": u24(e, 5),
                }
            )
        out["noches"].append(noche)
        i += size
    return out


# --- Despacho ---------------------------------------------------------------

_DECODERS = {
    cmd.EVT_LIVE_HEART: decode_live_heart,
    cmd.EVT_LIVE_SPO2: decode_live_spo2,
    cmd.EVT_LIVE_BLOOD: decode_live_blood,
    cmd.EVT_MEASURE_DONE: decode_measure_done,
    cmd.EVT_STORED_HEART: decode_stored_heart,
    cmd.EVT_STORED_BLOOD: decode_stored_blood,
    cmd.EVT_STORED_SPO2: decode_stored_spo2,
    cmd.GET_DEVICE_INFO: decode_device_info,
    cmd.GET_NOW_STEP: decode_activity,
}


def decode_payload(code: int, payload: bytes) -> dict[str, Any] | None:
    """Decodifica el payload de una trama si conocemos su formato; None si no."""
    fn = _DECODERS.get(code)
    return fn(payload) if fn else None
