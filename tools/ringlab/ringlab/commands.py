"""Catalogo de comandos y constructores de payload.

OJO: todo lo de aqui procede de la documentacion del R11M (narey83/vitals-smart-ring-app)
y esta SIN VERIFICAR contra el R21M. Cada entrada lleva su estado; el objetivo de la
Etapa 1 es ir confirmando o corrigiendo estos valores y volcarlos a docs/PROTOCOLO-R21M.md.

Ademas las dos fuentes del proyecto de referencia se contradicen en el grupo de las
consultas de historial: PROTOCOL.md las documenta en el grupo 05 y COMMANDS.md lista
GetHistoryHeart como 0x0206. Se incluyen ambas variantes para poder probarlas.
"""

from __future__ import annotations

import datetime as _dt
from enum import IntEnum

from .protocol import build_frame

# --- Comandos app -> anillo -------------------------------------------------

SET_TIME = 0x0100
SETTING_HEART_MONITOR = 0x010C
SETTING_SPO2_MONITOR = 0x0126

GET_DEVICE_INFO = 0x0200
GET_DEVICE_MAC = 0x0202
GET_DEVICE_NAME = 0x0203
GET_NOW_STEP = 0x020C
GET_ALL_REAL_DATA = 0x0220

# Variante "grupo 02" de las consultas de historial (segun COMMANDS.md)
GET_HISTORY_HEART_V2 = 0x0206
GET_HISTORY_BLOOD_V2 = 0x0208

START_MEASUREMENT = 0x032F

# Variante "grupo 05" de las consultas de historial (segun PROTOCOL.md)
HISTORY_SPORT = 0x0502
HISTORY_SLEEP = 0x0504
HISTORY_HEART = 0x0506
HISTORY_BLOOD = 0x0508
HISTORY_SPO2 = 0x0509

# --- Notificaciones anillo -> app -------------------------------------------

EVT_MEASURE_DONE = 0x040E

EVT_STORED_HEART = 0x0515
EVT_STORED_BLOOD = 0x0517
EVT_STORED_SPO2 = 0x0518
EVT_STORED_SLEEP = 0x0513

EVT_LIVE_HEART = 0x0601
EVT_LIVE_SPO2 = 0x0602
EVT_LIVE_BLOOD = 0x0603
EVT_LIVE_PPG = 0x0604
EVT_LIVE_ECG = 0x0605

NAMES: dict[int, str] = {
    SET_TIME: "SettingTime",
    SETTING_HEART_MONITOR: "SettingHeartMonitor",
    SETTING_SPO2_MONITOR: "SettingSpo2Monitor",
    GET_DEVICE_INFO: "GetDeviceInfo",
    GET_DEVICE_MAC: "GetDeviceMac",
    GET_DEVICE_NAME: "GetDeviceName",
    GET_NOW_STEP: "GetNowStep",
    GET_ALL_REAL_DATA: "GetAllRealDataFromDevice",
    GET_HISTORY_HEART_V2: "GetHistoryHeart(v2)",
    GET_HISTORY_BLOOD_V2: "GetHistoryBlood(v2)",
    START_MEASUREMENT: "AppStartMeasurement",
    HISTORY_SPORT: "Health_HistorySport",
    HISTORY_SLEEP: "Health_HistorySleep",
    HISTORY_HEART: "Health_HistoryHeart",
    HISTORY_BLOOD: "Health_HistoryBlood",
    HISTORY_SPO2: "Health_HistorySpo2",
    EVT_MEASURE_DONE: "MeasureComplete",
    EVT_STORED_SLEEP: "StoredSleepChunk",
    EVT_STORED_HEART: "StoredHeartRecord",
    EVT_STORED_BLOOD: "StoredBloodRecord",
    EVT_STORED_SPO2: "StoredSpo2Record",
    EVT_LIVE_HEART: "Real_UploadHeart",
    EVT_LIVE_SPO2: "Real_UploadBloodOxygen",
    EVT_LIVE_BLOOD: "Real_UploadBlood",
    EVT_LIVE_PPG: "Real_UploadPPG",
    EVT_LIVE_ECG: "Real_UploadECG",
}


def name_of(code: int) -> str:
    return NAMES.get(code, f"desconocido_{code:04X}")


class MeasureType(IntEnum):
    HEART = 0x00
    BLOOD_PRESSURE = 0x01
    SPO2 = 0x02


def frame(code: int, payload: bytes = b"") -> bytes:
    return build_frame(code >> 8, code & 0xFF, payload)


# --- Constructores ----------------------------------------------------------


def set_time(when: _dt.datetime) -> bytes:
    """01 00 con [anio uint16 LE][mes][dia][hora][min][seg][00]."""
    payload = (
        when.year.to_bytes(2, "little")
        + bytes([when.month, when.day, when.hour, when.minute, when.second, 0x00])
    )
    return frame(SET_TIME, payload)


def get_device_info() -> bytes:
    """02 00 con payload ASCII 'GC'."""
    return frame(GET_DEVICE_INFO, b"GC")


def get_now_step() -> bytes:
    return frame(GET_NOW_STEP)


def start_measurement(kind: MeasureType) -> bytes:
    return frame(START_MEASUREMENT, bytes([0x01, int(kind)]))


def stop_measurement() -> bytes:
    return frame(START_MEASUREMENT, bytes([0x00, 0x00]))


def set_heart_monitor(enabled: bool, minutes: int) -> bytes:
    return frame(SETTING_HEART_MONITOR, bytes([1 if enabled else 0, minutes & 0xFF]))


def set_spo2_monitor(enabled: bool, minutes: int) -> bytes:
    return frame(SETTING_SPO2_MONITOR, bytes([1 if enabled else 0, minutes & 0xFF]))


HISTORY_QUERIES: dict[str, int] = {
    "hr": HISTORY_HEART,
    "bp": HISTORY_BLOOD,
    "spo2": HISTORY_SPO2,
    "sleep": HISTORY_SLEEP,
    "sport": HISTORY_SPORT,
}


def query_history(kind: str) -> bytes:
    try:
        return frame(HISTORY_QUERIES[kind])
    except KeyError:
        raise ValueError(
            f"historial desconocido {kind!r}; opciones: {', '.join(HISTORY_QUERIES)}"
        ) from None
