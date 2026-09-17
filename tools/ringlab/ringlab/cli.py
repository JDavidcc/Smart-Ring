"""CLI del laboratorio. Uso: python -m ringlab <subcomando>"""

from __future__ import annotations

import asyncio
import datetime as _dt
import json
import re
from pathlib import Path
from typing import Any, Optional

import typer
from rich.console import Console
from rich.table import Table

from . import client as ble
from . import commands as cmd
from . import decoders
from .protocol import parse_frame

app = typer.Typer(add_completion=False, help="Laboratorio de protocolo del anillo R21M.")
console = Console()

REPO = Path(__file__).resolve().parents[3]
DOCS = REPO / "docs"


def _stamp() -> str:
    return _dt.datetime.now().strftime("%Y%m%d-%H%M%S")


def _trace(tag: str, *, quiet: bool = False) -> ble.TraceLog:
    path = ble.CAPTURES_DIR / f"{tag}-{_stamp()}.jsonl"
    printer = None if quiet else _print_record
    return ble.TraceLog(path, printer)


def _print_record(rec: dict[str, Any]) -> None:
    d = rec.get("dir")
    if d == "sys":
        console.print(f"[dim]{rec['t']}[/dim] [cyan]· {rec.get('evento')}[/cyan] "
                      f"{ {k: v for k, v in rec.items() if k not in ('t', 'dir', 'evento')} }")
        return
    color = "yellow" if d == "tx" else "green"
    arrow = "→" if d == "tx" else "←"
    head = rec.get("nombre") or rec.get("char", "")
    body = rec.get("payload") or rec.get("hex", "")
    console.print(f"[dim]{rec['t']}[/dim] [{color}]{arrow} {head}[/{color}] {body}")
    dec = rec.get("decodificado")
    if dec:
        console.print(f"    [dim]{json.dumps(dec, ensure_ascii=False, default=str)}[/dim]")
    if rec.get("error"):
        console.print(f"    [red]{rec['error']}[/red]")
    if rec.get("nota"):
        console.print(f"    [dim]{rec['nota']}[/dim]")


async def _resolve_address(address: Optional[str], seconds: float = 8.0) -> str:
    if address:
        return address
    console.print(f"[dim]Buscando dispositivos {ble.DEFAULT_NAME_PREFIX}*...[/dim]")
    found = await ble.scan(seconds)
    if not found:
        raise typer.BadParameter(
            "no se encontro ningun anillo. Verifica que este cerca, cargado, y que no "
            "este conectado al telefono (solo acepta un central a la vez)."
        )
    dev = found[0]
    console.print(f"[green]Usando {dev.adv.name or dev.device.name} @ {dev.device.address}[/green]")
    return dev.device.address


def _run(coro) -> None:
    asyncio.run(coro)


# --- scan -------------------------------------------------------------------


@app.command()
def scan(
    seconds: float = typer.Option(8.0, help="Duracion del escaneo."),
    todos: bool = typer.Option(False, "--todos", help="No filtrar por nombre."),
) -> None:
    """Escanea y decodifica el advertisement."""

    async def go() -> None:
        found = await ble.scan(seconds, None if todos else ble.DEFAULT_NAME_PREFIX)
        if not found:
            console.print("[red]Sin resultados.[/red]")
            raise typer.Exit(1)
        for f in found:
            a = f.adv
            console.print(f"\n[bold green]{a.name or f.device.name or '?'}[/bold green] "
                          f"@ {f.device.address}  {f.rssi} dBm")
            console.print(f"  UUIDs 16-bit : {', '.join(f'0x{u:04X}' for u in a.service_uuids16) or '-'}")
            if a.company_id is not None:
                console.print(f"  Company ID   : 0x{a.company_id:04X}")
                console.print(f"  Mfr data     : {a.manufacturer_data.hex(' ').upper()}")
            console.print(f"  MAC en adv   : {a.mac or '-'}")
            console.print(f"  Bateria?     : {a.battery_guess if a.battery_guess is not None else '-'}"
                          "  [dim](hipotesis)[/dim]")

    _run(go())


@app.command("decode-file")
def decode_file(
    ruta: Path = typer.Argument(..., help="Archivo de lecturas del scanner BLE."),
    limite: int = typer.Option(3, help="Cuantas lineas decodificar."),
) -> None:
    """Decodifica advertisements desde un archivo de lecturas ya capturado."""
    texto = ruta.read_text(encoding="utf-8", errors="replace")
    hechos = 0
    for linea in texto.splitlines():
        m = re.search(r"0x([0-9A-Fa-f]+)\s*$", linea.strip())
        if not m:
            continue
        adv = decoders.decode_advertisement(bytes.fromhex(m.group(1)))
        console.print(f"\n[bold]{linea.split(',')[0]}[/bold]")
        for s in adv.structures:
            console.print(f"  {s.type_name:<28} {s.data.hex(' ').upper()}")
        console.print(f"  [green]nombre[/green]   : {adv.name}")
        console.print(f"  [green]servicios[/green]: "
                      f"{', '.join(f'0x{u:04X}' for u in adv.service_uuids16)}")
        console.print(f"  [green]company[/green]  : "
                      f"0x{adv.company_id:04X}" if adv.company_id is not None else "  company  : -")
        console.print(f"  [green]MAC[/green]      : {adv.mac}")
        console.print(f"  [green]bateria?[/green] : {adv.battery_guess} [dim](hipotesis)[/dim]")
        hechos += 1
        if hechos >= limite:
            break
    if not hechos:
        console.print("[red]No se encontraron payloads hex en el archivo.[/red]")
        raise typer.Exit(1)


# --- gatt -------------------------------------------------------------------


@app.command("gatt-dump")
def gatt_dump(
    address: Optional[str] = typer.Option(None, "--address", "-a"),
    salida: Optional[Path] = typer.Option(None, help="Markdown de salida."),
) -> None:
    """Enumera todos los servicios y caracteristicas. Paso critico de validacion."""

    async def go() -> None:
        addr = await _resolve_address(address)
        destino = salida or (DOCS / "hallazgos" / f"gatt-R21M-{_stamp()}.md")
        lineas = [f"# Mapa GATT del R21M ({addr})", "", f"Generado: {_dt.datetime.now().isoformat()}", ""]
        async with ble.RingClient(addr, trace=_trace("gatt", quiet=True)) as ring:
            console.print(f"[green]Conectado.[/green] MTU = {ring.mtu}")
            lineas.append(f"MTU negociado: **{ring.mtu}**")
            lineas.append("")
            for service in ring.services:
                console.print(f"\n[bold cyan]Servicio {service.uuid}[/bold cyan] {service.description}")
                lineas += [f"## Servicio `{service.uuid}`", f"{service.description}", "",
                           "| Caracteristica | Handle | Propiedades | Descripcion |",
                           "|---|---|---|---|"]
                for ch in service.characteristics:
                    props = ",".join(ch.properties)
                    console.print(f"  [yellow]{ch.uuid}[/yellow] h={ch.handle} [{props}] {ch.description}")
                    lineas.append(f"| `{ch.uuid}` | 0x{ch.handle:04X} | {props} | {ch.description} |")
                lineas.append("")

            esperadas = [ble.CH_COMMAND, ble.CH_NOTIFY, ble.CH_ACTIVITY, ble.CH_HEART_SIG]
            faltan = ring.missing(esperadas)
            tabla = Table(title="Caracteristicas esperadas (doc del R11M)")
            tabla.add_column("Token")
            tabla.add_column("Estado")
            for t in esperadas:
                tabla.add_row(t, "[red]NO ENCONTRADA[/red]" if t in faltan else "[green]presente[/green]")
            console.print(tabla)

            lineas += ["## Contraste con la documentacion del R11M", ""]
            for t in esperadas:
                lineas.append(f"- `{t}`: {'**NO ENCONTRADA**' if t in faltan else 'presente'}")
            if faltan:
                lineas += ["", "> Faltan caracteristicas: el R21M no comparte el mapa del R11M. "
                               "Plan B: decompilar el APK de SmartHealth con jadx y buscar `YCBTClient`."]

        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_text("\n".join(lineas), encoding="utf-8")
        console.print(f"\n[green]Escrito:[/green] {destino}")

    _run(go())


# --- operaciones ------------------------------------------------------------


@app.command()
def info(address: Optional[str] = typer.Option(None, "--address", "-a")) -> None:
    """GetDeviceInfo (02 00 'GC'): valida la capa de trama y el CRC de un golpe."""

    async def go() -> None:
        addr = await _resolve_address(address)
        async with ble.RingClient(addr, trace=_trace("info")) as ring:
            console.print(f"[green]Conectado.[/green] MTU = {ring.mtu}")
            fr = await ring.request(cmd.get_device_info())
            console.print(f"\n[bold]Respuesta {fr}[/bold]")
            console.print(decoders.decode_device_info(fr.payload))

    _run(go())


@app.command()
def settime(address: Optional[str] = typer.Option(None, "--address", "-a")) -> None:
    """Sincroniza el reloj del anillo con la hora local. El RTC no avanza solo."""

    async def go() -> None:
        addr = await _resolve_address(address)
        async with ble.RingClient(addr, trace=_trace("settime")) as ring:
            ahora = _dt.datetime.now()
            await ring.request(cmd.set_time(ahora))
            console.print(f"[green]Hora enviada:[/green] {ahora.isoformat(timespec='seconds')}")

    _run(go())


@app.command()
def measure(
    tipo: str = typer.Argument(..., help="hr | spo2 | bp"),
    address: Optional[str] = typer.Option(None, "--address", "-a"),
    segundos: float = typer.Option(45.0, help="Cuanto escuchar antes de rendirse."),
) -> None:
    """Dispara una medicion en vivo y escucha hasta el evento de fin (04 0E)."""
    mapa = {
        "hr": cmd.MeasureType.HEART,
        "spo2": cmd.MeasureType.SPO2,
        "bp": cmd.MeasureType.BLOOD_PRESSURE,
    }
    if tipo not in mapa:
        raise typer.BadParameter("tipo debe ser hr, spo2 o bp")

    async def go() -> None:
        addr = await _resolve_address(address)
        async with ble.RingClient(addr, trace=_trace(f"measure-{tipo}")) as ring:
            console.print("[bold]Ponte el anillo y no lo muevas.[/bold]")
            await ring.send(cmd.start_measurement(mapa[tipo]))
            try:
                fin = await ring.wait_for(cmd.EVT_MEASURE_DONE, timeout=segundos)
                console.print(f"\n[bold green]Fin:[/bold green] {decoders.decode_measure_done(fin.payload)}")
            except asyncio.TimeoutError:
                console.print("[yellow]No llego el evento de fin; deteniendo medicion.[/yellow]")
            finally:
                await ring.send(cmd.stop_measurement())

    _run(go())


@app.command()
def steps(
    address: Optional[str] = typer.Option(None, "--address", "-a"),
    segundos: float = typer.Option(20.0, help="Ventana de escucha de fea1."),
    esperado: Optional[int] = typer.Option(
        None, help="Cifra de pasos conocida: se busca en todo el payload."
    ),
    tolerancia: int = typer.Option(3, help="Margen al buscar la cifra esperada."),
) -> None:
    """Consulta el contador de actividad y escucha las notificaciones de fea1.

    Con --esperado se localiza esa cifra dentro del payload, que es como se
    resuelve el formato real en vez de adivinarlo.
    """

    async def go() -> None:
        addr = await _resolve_address(address)
        async with ble.RingClient(addr, trace=_trace("steps", quiet=True)) as ring:
            if not ring.has(ble.CH_ACTIVITY):
                console.print(f"[yellow]Sin caracteristica {ble.CH_ACTIVITY}; solo consulta 02 0C.[/yellow]")
            payload = b""
            try:
                fr = await ring.request(cmd.get_now_step(), timeout=8.0)
                payload = fr.payload
                console.print(f"\n[bold]02 0C ->[/bold] {payload.hex(' ').upper()}")
                _dump_offsets(payload)
                console.print("\n[dim]Interpretaciones candidatas:[/dim]")
                console.print(decoders.decode_activity(payload).get("candidatos", {}))
            except asyncio.TimeoutError:
                console.print("[yellow]02 0C sin respuesta.[/yellow]")

            if esperado is not None and payload:
                hits = decoders.locate_value(payload, esperado, tolerancia)
                if hits:
                    tabla = Table(title=f"Donde aparece {esperado} (+/-{tolerancia})")
                    tabla.add_column("Offset")
                    tabla.add_column("Ancho")
                    tabla.add_column("Valor")
                    tabla.add_column("Bytes")
                    for h in hits:
                        tabla.add_row(str(h["offset"]), f"{h['ancho']}B", str(h["valor"]), h["bytes"])
                    console.print(tabla)
                else:
                    console.print(
                        f"[yellow]La cifra {esperado} no aparece en el payload. "
                        "O el contador no se ha actualizado, o el valor esta codificado "
                        "de otra forma (escalado, big-endian, o en otro comando).[/yellow]"
                    )

            console.print(f"\n[dim]Escuchando fea1 durante {segundos}s...[/dim]")
            await asyncio.sleep(segundos)

    _run(go())


def _dump_offsets(payload: bytes) -> None:
    """Tabla byte a byte con las lecturas little-endian en cada offset."""
    tabla = Table(show_header=True)
    tabla.add_column("Off")
    tabla.add_column("Byte")
    tabla.add_column("u8")
    tabla.add_column("u16")
    tabla.add_column("u24")
    tabla.add_column("u32")
    for i, b in enumerate(payload):
        tabla.add_row(
            str(i),
            f"{b:02X}",
            str(b),
            str(decoders.u16(payload, i)) if i + 2 <= len(payload) else "",
            str(decoders.u24(payload, i)) if i + 3 <= len(payload) else "",
            str(decoders.u32(payload, i)) if i + 4 <= len(payload) else "",
        )
    console.print(tabla)


@app.command()
def history(
    tipo: str = typer.Argument(..., help="hr | bp | spo2 | sleep | sport"),
    address: Optional[str] = typer.Option(None, "--address", "-a"),
    segundos: float = typer.Option(30.0, help="Ventana de recoleccion tras la consulta."),
) -> None:
    """Consulta el historial almacenado y recoge todos los pushes."""

    async def go() -> None:
        addr = await _resolve_address(address)
        async with ble.RingClient(addr, trace=_trace(f"history-{tipo}")) as ring:
            console.print(f"MTU = {ring.mtu}"
                          + ("  [yellow](bajo: el historial puede no llegar completo)[/yellow]"
                             if ring.mtu < 100 else ""))
            await ring.send(cmd.query_history(tipo))
            recibidas = await ring.collect(segundos)
            console.print(f"\n[bold]{len(recibidas)} tramas recibidas.[/bold]")
            if tipo == "sleep":
                blob = b"".join(f.payload for _, f in recibidas if f.code == cmd.EVT_STORED_SLEEP)
                if blob:
                    console.print(json.dumps(decoders.decode_sleep(blob), ensure_ascii=False, indent=2))
                else:
                    console.print("[yellow]Sin bloques 05 13.[/yellow]")

    _run(go())


@app.command()
def monitor(
    address: Optional[str] = typer.Option(None, "--address", "-a"),
    segundos: float = typer.Option(120.0),
) -> None:
    """Conecta y vuelca todo lo que el anillo emita, sin enviar nada."""

    async def go() -> None:
        addr = await _resolve_address(address)
        async with ble.RingClient(addr, trace=_trace("monitor")) as ring:
            console.print(f"[green]Escuchando {segundos}s.[/green] MTU = {ring.mtu}")
            await asyncio.sleep(segundos)

    _run(go())


@app.command()
def raw(
    grupo: str = typer.Argument(..., help="Grupo en hex, p.ej. 02"),
    comando: str = typer.Argument(..., help="Comando en hex, p.ej. 00"),
    payload: str = typer.Argument("", help="Payload en hex, p.ej. 4743"),
    address: Optional[str] = typer.Option(None, "--address", "-a"),
    segundos: float = typer.Option(10.0),
) -> None:
    """Envia una trama arbitraria. Para explorar el catalogo de comandos."""

    async def go() -> None:
        addr = await _resolve_address(address)
        trama = cmd.frame(
            (int(grupo, 16) << 8) | int(comando, 16),
            bytes.fromhex(payload.replace(" ", "")),
        )
        async with ble.RingClient(addr, trace=_trace("raw")) as ring:
            console.print(f"[dim]Trama: {trama.hex(' ').upper()}[/dim]")
            await ring.send(trama)
            await ring.collect(segundos)

    _run(go())


@app.command("self-test")
def self_test() -> None:
    """Prueba la capa de trama sin necesidad del anillo."""
    from .protocol import FrameReassembler, build_frame, crc16

    # Vector conocido de CRC-16/CCITT-FALSE.
    assert crc16(b"123456789") == 0x29B1, "CRC-16/CCITT-FALSE incorrecto"

    # 02 00 con payload "GC": longitud total = 4 cabecera + 2 payload + 2 CRC = 8.
    cuerpo = bytes.fromhex("02000800") + b"GC"
    t = build_frame(0x02, 0x00, b"GC")
    assert t == cuerpo + crc16(cuerpo).to_bytes(2, "little"), t.hex(" ").upper()
    fr = parse_frame(t)
    assert (fr.group, fr.command, fr.payload) == (0x02, 0x00, b"GC")

    # Tramas documentadas del R11M: la longitud declarada debe coincidir.
    assert build_frame(0x03, 0x2F, b"\x01\x00")[:4] == bytes.fromhex("032F0800")
    assert build_frame(0x04, 0x0E, b"\x00\x01")[:4] == bytes.fromhex("040E0800")

    # Reensamblado de una trama partida en fragmentos de 3 bytes.
    grande = build_frame(0x05, 0x13, bytes(range(60)))
    r = FrameReassembler()
    salidas = []
    for i in range(0, len(grande), 3):
        salidas += r.feed(grande[i : i + 3])
    assert len(salidas) == 1 and salidas[0].payload == bytes(range(60))

    # Dos tramas en una sola notificacion.
    r2 = FrameReassembler()
    dobles = r2.feed(build_frame(0x06, 0x01, b"\x48") + build_frame(0x06, 0x02, b"\x62"))
    assert [f.code for f in dobles] == [0x0601, 0x0602]

    console.print("[bold green]Capa de trama OK[/bold green] (CRC, build, parse, reensamblado)")


if __name__ == "__main__":
    app()
