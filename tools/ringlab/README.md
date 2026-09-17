# ringlab — laboratorio de protocolo del anillo R21M

Etapa 1 del proyecto: verificar contra **tu** anillo el protocolo YCBT (SDK Yucheng, familia
SmartHealth) antes de escribir la app Flutter. Todo lo que entra y sale se registra en
`capturas/*.jsonl`; ese corpus será el juego de pruebas del puerto a Dart.

## Preparación

```powershell
cd tools\ringlab
.\.venv\Scripts\python.exe -m ringlab self-test    # prueba la capa de trama, sin anillo
```

**Importante:** el anillo acepta **un solo central a la vez**. Para trabajar desde la PC hay que
cerrar SmartHealth en el teléfono y quitar el anillo de sus dispositivos Bluetooth; mientras esté
conectado allí no se anuncia y la PC no lo verá.

## Subcomandos

| Comando | Para qué |
|---|---|
| `self-test` | Verifica CRC, construcción, parseo y reensamblado de tramas. No necesita anillo. |
| `decode-file <ruta>` | Decodifica advertisements de un archivo de lecturas ya capturado. |
| `scan [--todos]` | Escanea en vivo y decodifica el advertisement. |
| `gatt-dump` | Enumera servicios y características → `docs/hallazgos/`. **Paso de validación crítico.** |
| `info` | `02 00 "GC"`: firmware y batería. Si responde con CRC válido, la capa de trama está confirmada. |
| `settime` | Sincroniza el reloj. El RTC del anillo no avanza solo. |
| `measure hr\|spo2\|bp` | Dispara una medición en vivo y escucha hasta el evento de fin `04 0E`. |
| `steps` | Consulta el contador de actividad y escucha `fea1`. |
| `history hr\|bp\|spo2\|sleep\|sport` | Consulta el historial y recoge todos los *pushes*. |
| `raw <grupo> <cmd> [payload]` | Trama arbitraria, para explorar el catálogo. |
| `monitor` | Conecta y vuelca todo lo que emita el anillo, sin enviar nada. |

Todos aceptan `--address/-a`; sin él, se autodescubre por prefijo de nombre `R21M`.

## Estado de la verificación

| Elemento | Estado |
|---|---|
| Decodificador de advertisement | **verificado** contra `lecturas-ble/` |
| CRC-16/CCITT-FALSE | **verificado** con el vector estándar (`123456789` → `0x29B1`) |
| Construcción/parseo/reensamblado de tramas | **verificado** por `self-test` |
| UUIDs de características | pendiente — requiere `gatt-dump` |
| Comandos y formatos de payload | pendiente — tomados del R11M, sin confirmar |

## Si el mapa GATT no coincide con el del R11M

Plan B: extraer el APK de SmartHealth del teléfono y decompilarlo.

```powershell
adb shell pm list packages | Select-String -Pattern "health|ycbt|smart"
adb shell pm path <paquete>
adb pull <ruta-del-apk> .
# luego abrirlo con jadx y buscar la clase YCBTClient
```
