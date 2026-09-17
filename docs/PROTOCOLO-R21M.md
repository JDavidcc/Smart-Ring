# Protocolo del anillo R21M

Dispositivo: `R21M 1ED8` — MAC `07:29:00:12:1E:D8`
Familia: SDK Yucheng **YCBT** (app *SmartHealth*).
Referencia de partida: [narey83/vitals-smart-ring-app](https://github.com/narey83/vitals-smart-ring-app) (modelo R11M).

Cada afirmación lleva su estado:

- **VERIFICADO** — observado directamente contra este anillo.
- **HIPÓTESIS** — heredado de la doc del R11M, todavía sin comprobar aquí.
- **REFUTADO** — la doc del R11M no aplica a este anillo.

---

## 1. Advertisement — VERIFICADO

Idéntico en las 103 lecturas del archivo y en el escaneo en vivo.

```
02 01 06                     Flags: LE General Discoverable, sin BR/EDR
05 03 0D18 E7FE              UUIDs 16-bit: 0x180D (Heart Rate), 0xFEE7
0A 09 "R21M 1ED8"            Nombre completo
1E FF 1078 <27 bytes>        Manufacturer data, company ID 0x7810
```

Manufacturer data (27 bytes):

```
09 00 00 01 02 1B 00 00 00 00 00 00 0F 00 00 00 01 00 64 00 00 | 07 29 00 12 1E D8
                                                    ^^                ^^^^^^^^^^^^^^^^^
                                            batería 0x64=100          MAC (orden natural)
```

- **VERIFICADO**: los últimos 6 bytes son el MAC.
- **VERIFICADO**: el byte en offset 18 es la batería en % — vale `0x64` = 100 y coincide con
  el byte 5 de la respuesta a `02 00`, obtenido por un camino totalmente independiente.
- El resto de los bytes sigue sin interpretar.

**Consecuencia útil para la app:** se puede mostrar el nivel de batería sin conectarse, solo
escaneando.

## 2. Mapa GATT — VERIFICADO

Volcado completo en `hallazgos/gatt-R21M-20260917-113905.md`. MTU negociado en Windows: **185**.

| Servicio | Característica | Handle | Propiedades | Uso |
|---|---|---|---|---|
| `be940000-7333-be46-b7ae-689e71722bd5` | `be940001-…` | 0x000B | indicate, write, write-without-response | **Canal de comandos: se escribe aquí y las respuestas vuelven por aquí mismo** |
| | `be940002-…` | 0x000E | write-without-response | sin identificar |
| | `be940003-…` | 0x0010 | indicate | Notificaciones iniciadas por el anillo |
| `6e400001-…` (Nordic UART) | `6e400002` / `6e400003` | 0x0014 / 0x0016 | write / notify | sin identificar |
| `0000fee7` (Tencent) | `fec9` | 0x001A | read | sin identificar |
| | `fea1` | 0x001C | indicate, read | Actividad en vivo |
| | `fea2` | 0x001F | indicate, write, read | sin identificar |
| `0000180d` (Heart Rate) | `2a37` | 0x006D | notify | HR estándar SIG |
| | `2a38` | 0x0070 | read | Body Sensor Location |
| `0000ae00` | `ae01` / `ae02` | 0x0081 / 0x0083 | write / notify | OTA JieLi — **no tocar** |

El mapa coincide con el del R11M en las cuatro características que importan. Los handles de la doc
del R11M están consistentemente una unidad por encima porque allí se anotó el handle de valor y aquí
el de declaración.

**Corrección respecto a la doc del R11M:** `be940001` es `indicate`, no `read`. Las respuestas no se
leen: llegan como indicaciones por el mismo canal donde se escribe.

## 3. Capa de trama — VERIFICADO

```
[grupo:1][comando:1][longitud:2 LE][payload:*][CRC16:2 LE]
```

La longitud declara el tamaño **total** de la trama, cabecera y CRC incluidos.

CRC-16/CCITT-FALSE: poly `0x1021`, init `0xFFFF`, sin reflexión, sin XOR final, anexado en
little-endian. Verificado dos veces: contra el vector estándar (`"123456789"` → `0x29B1`) y contra
las respuestas reales del anillo, que pasan la comprobación de CRC.

Ejemplo real:

```
→ 02 00 08 00 47 43 6F EC          GetDeviceInfo, payload ASCII "GC"
← 02 00 1E 00 A3 00 1B 02 02 64 …  respuesta de 30 bytes, CRC válido
```

## 4. Convención de respuestas — VERIFICADO

| Payload de respuesta | Significado |
|---|---|
| `00` | comando aceptado |
| `00 00` | aceptado, sin registros (en las consultas de historial: parece `[estado][conteo]`) |
| `FE` | **comando rechazado / no soportado** |

`FE` se observó al enviar `02 02` (GetDeviceMac según el catálogo del R11M). O ese código no existe
en este firmware, o requiere un payload que no conocemos.

## 5. Comandos confirmados

| Trama enviada | Respuesta | Estado |
|---|---|---|
| `01 00` + `[año u16 LE][mes][día][h][m][s][00]` | `00` | **VERIFICADO** — `EA 07 09 11 0B 29 25 00` = 2026-09-17 11:41:37 |
| `02 00` + `"GC"` | 24 bytes de payload | **VERIFICADO** |
| `02 0C` (GetNowStep) | 14 bytes | **VERIFICADO** — responde; formato aún sin resolver (ver §7) |
| `03 2F` + `01 <tipo>` | `00`, luego datos en vivo y `04 0E` | **VERIFICADO** para los 3 tipos |
| `03 2F` + `00 00` (detener) | `00` | **VERIFICADO** |
| `05 06` (historial HR) | `00 00` | **VERIFICADO** que es aceptado; sin datos aún |
| `05 04` (historial sueño) | `00 00` | **VERIFICADO** que es aceptado; sin datos aún |
| `02 02` (GetDeviceMac) | `FE` | **REFUTADO** tal como está documentado |

### Respuesta de `02 00` (GetDeviceInfo)

```
A3 00 1B 02 02 64 E3 01 00 03 E3 01 90 09 00 00 D0 3E 01 00 00 00 00 00
            ^^ ^^
            |  └─ byte 5: batería % = 0x64 = 100   VERIFICADO (coincide con el advertisement)
            └──── byte 4: estado de batería = 0x02  SIN DOCUMENTAR
```

La doc del R11M describe el byte 4 como estado del cargador (`00` = fuera, `01` = cargando).
**En este anillo NO lo es — REFUTADO.**

Dos intercambios completos capturados (petición y respuesta visibles en la consola de tramas):

```
11:40, anillo FUERA del cargador:
  A3 00 1B 02 02 64 E3 01 00 03 E3 01 90 09 00 00 D0 3E 01 00 00 00 00 00
14:14, anillo CARGANDO:
  A3 00 1B 02 02 64 E3 01 00 03 E3 01 90 09 00 00 D0 3E 01 00 00 00 00 00
```

Idénticas byte a byte, 3½ horas y cuatro mediciones después. El byte 4 no cambia.

**Cómo se llegó a esto** (importa, porque el primer intento fue inválido): la observación original
se hizo mirando el texto de la pantalla, y entonces `refreshInfo()` se tragaba los errores en
silencio — un fallo de lectura era indistinguible de un valor que no cambia. Además la consola de
depuración perdía el registro al navegar, así que ni siquiera se podía comprobar si hubo lectura.
Ambos defectos se corrigieron y la prueba se repitió con el diálogo crudo a la vista.

Salvedad: la batería estaba al 100 % en ambas lecturas. No se puede descartar que el byte
codifique una *clase* de estado (p. ej. `02` = llena) que solo cambie con la batería baja.

**Consecuencia para la app:** el estado de batería solo se muestra si el valor está documentado
(`00`/`01`). Con `02` se omite en vez de enseñar ruido; el crudo sigue visible en la consola.

Resto del payload sin interpretar. Valores que se repiten: `E3 01` = 483 en dos posiciones
(offsets 6 y 10), `90 09` = 2448, `D0 3E 01 00` = 81616.

## 6. Medición en vivo — VERIFICADO (los tres tipos)

Se dispara con `03 2F` + `01 <tipo>` y se detiene con `03 2F` + `00 00`.
Tipos: `00` = HR, `01` = presión, `02` = SpO2.

Los datos llegan por `be940003`; el evento de fin llega por `be940001`.

| Tipo | Trama enviada | Datos en vivo | Fin | Medido |
|---|---|---|---|---|
| HR | `03 2F 08 00 01 00 4F 1B` | `06 01` payload `4C` | `04 0E` → `00 01` | **76 bpm** |
| Presión | `03 2F 08 00 01 01 6E 0B` | `06 03` payload `70 49 4E 00…` | `04 0E` → `01 01` | **112/73 mmHg** |
| SpO2 | `03 2F 08 00 01 02 0D 3B` | `06 02` payload `62` | `04 0E` → `02 01` | **98 %** |

`04 0E` lleva `[tipo][resultado]`: `01` = medido, `02` = anillo no puesto. Ambos **VERIFICADOS**.

### Anillo no puesto — VERIFICADO, y con una trampa importante

Midiendo con el anillo sobre la mesa:

```
13:48:12  06 01 07 00 4B 02 D6   -> 75 bpm     <- ¡sin llevarlo puesto!
13:48:13  06 01 07 00 4B 02 D6   -> 75 bpm
13:48:14  06 01 07 00 4B 02 D6   -> 75 bpm
13:48:14  04 0E 08 00 00 02 98 62 -> tipo 0, resultado 02 = no puesto
```

**El anillo emite lecturas en vivo perfectamente plausibles aunque no esté puesto**, y solo al
final admite que la medición no era válida. El valor (75 bpm) coincidía además con el último pulso
real medido, así que ni siquiera parece un valor absurdo que se pueda filtrar por rango.

Consecuencia directa para la app: **no se puede persistir nada de `06 xx` al vuelo**. Hay que
retener la lectura y guardarla solo cuando llegue `04 0E` con resultado `01`. Así está implementado
en `RingController._commit`; hacerlo de la forma ingenua metía tres pulsos falsos en el historial.

**Tiempos reales medidos** — importan para la UX de la app:

| Tipo | Desde el comando hasta el primer dato | Duración total hasta `04 0E` |
|---|---|---|
| HR | ~22 s | ~35 s |
| SpO2 | ~48 s | ~62 s |
| Presión | ~18 s | ~25 s |

La app necesita una barra de progreso con margen: hasta ~50 s de silencio antes del primer valor
es comportamiento normal, no un fallo.

### Payload de presión (`06 03`)

```
70 49 4E 00 00 00 00 00 00 00 00 00 00 00
^^ ^^ ^^
|  |  └─ 0x4E=78 / 0x50=80  → HIPÓTESIS FUNDAMENTADA: pulso durante la medición
|  └──── diastólica = 0x49 = 73    VERIFICADO
└─────── sistólica  = 0x70 = 112   VERIFICADO
```

La doc del R11M marca el tercer byte como desconocido. En nuestras capturas vale 78–80 mientras
que el pulso medido por separado minutos antes era 75–76: encaja con ser la frecuencia cardíaca.
Queda por confirmar comparando contra lo que muestre SmartHealth.

## 7. Heart Rate estándar (`2a37`) — VERIFICADO

El anillo emite un valor cada ~1.2 s **de forma continua, esté midiendo o no**:

- En reposo, sin medir: `04 00` → flags `0x04`, 0 bpm.
- Tras una medición: `04 4C` → 76 bpm, y **sigue reemitiendo ese mismo valor indefinidamente**
  aunque la medición ya terminó.
- El bit de contacto con la piel reporta "no detectado" **incluso durante una medición real y
  exitosa**.

Esto **confirma y agrava** la advertencia de la doc del R11M. La app no debe tratar `2a37` como
fuente de muestras ni su bit de contacto como indicador de que el anillo está puesto: la fuente de
verdad son las tramas `06 01` y el evento `04 0E`.

## 8. Contador de actividad (`02 0C` / `fea1`) — EN CURSO

### `fea1` no empuja nada — REFUTADO

La doc del R11M describe `fea1` como "actividad en vivo, actualizaciones cada ~2 s". En este
anillo, suscrito por indicación y con el anillo puesto, **no emitió absolutamente nada** en
ventanas de 12 y 20 segundos. La app debe consultar `02 0C` activamente en vez de esperar
notificaciones por ahí.

### `02 0C` — formato RESUELTO

```
[pasos u24 LE][calorías u16 LE][distancia_m u24 LE][6 bytes en cero]
```

Trama completa capturada con el CRC del propio anillo (sirve de fixture en
`app/test/protocol_test.dart`):

```
02 0C 14 00 | 52 00 00 03 00 34 00 00 00 00 00 00 00 00 | 35 D9
```

#### Cómo se resolvió

Dos lecturas separadas por ~100 pasos caminados:

| Lectura | Payload | offset 0 (u24) | offset 3 (u16) | offset 5 (u24) |
|---|---|---|---|---|
| tras ~50 pasos | `52 00 00 03 00 34 …` | 82 | 3 | 52 |
| tras ~150 pasos | `C3 00 00 08 00 7B …` | 195 | 8 | 123 |

Buscar la cifra caminada dentro del payload **no sirvió**: con una sola lectura, tanto el 52 del
offset 5 como el 82 del offset 0 eran defendibles.

Lo decisivo fue la **razón entre los offsets 0 y 5**:

```
52 / 82  = 0.634
123 / 195 = 0.631
```

Constante. Eso solo ocurre si un campo se deriva del otro, y 0.63 m por paso es una zancada humana
normal. Luego el offset 0 son los pasos y el offset 5 la distancia, calculada como
`floor(pasos × zancada)`. Resolviendo la restricción de redondeo entero con ambas lecturas, la
zancada queda acotada en **[0.634, 0.636) m**.

Eso además descarta el offset 5 como contador: habría marcado 52 tras 50 pasos (casi exacto) pero
solo +71 tras caminar ~100 más. Un contador no pasa de exacto a 29 % corto. El offset 0 sube +113,
coherente con algo de movimiento incidental.

El offset 3 son calorías: ~0.043 kcal/paso, también constante entre lecturas.

#### Corrección a la doc del R11M

Acertó la posición de los pasos (offset 0) pero **invirtió distancia y calorías**, y leía los
campos con anchos equivocados —  los pasos como 1 solo byte, lo que habría hecho que el contador
se reiniciara cada 255.

#### Implicación para la app

**La distancia no se mide, se calcula.** No aporta información independiente de los pasos: si la
zancada real del usuario no es 0.635 m, la cifra está escalada por igual en todos los días. La app
lo advierte en la pantalla de actividad.

## 9. Pendiente de verificar

Requiere que el anillo acumule datos de uso real (llevarlo puesto un día y dormir con él):

- Formato de los registros almacenados `05 15` / `05 17` / `05 18`.
- Bloques de sueño `05 13` y la época de los timestamps (se asume 2000-01-01).

Pequeños, resolubles en cualquier momento:

- Confirmar que el tercer byte de `06 03` es el pulso (§6), contrastando con SmartHealth.
- Los 6 bytes finales de `02 0C`, siempre en cero hasta ahora (§8).
- Qué significa realmente el byte 4 de `02 00` (§5): se sabe que **no** es el cargador; queda
  repetir la lectura con la batería baja por si codifica una clase de estado.
- El resto del payload de `02 00`, invariante entre lecturas: `E3 01` (483) dos veces,
  `90 09` (2448), `D0 3E 01 00` (81616). Parece información estática del dispositivo.

## 10. Notas de implementación para la app

- **Un solo central a la vez.** Mientras SmartHealth esté conectada, el anillo no se anuncia.
- **MTU 185 en Windows**, el mismo orden de magnitud que negocia iOS. Es más que suficiente para
  los registros de ~150 bytes, pero el reensamblado de tramas partidas sigue siendo obligatorio.
- **Sincronizar la hora en cada conexión**: el RTC del anillo no avanza solo y los registros
  heredan la última hora escrita.
- **La presión arterial es estimada, no médica.**
- No implementar `01 0E "RSYS"` (reset de fábrica) ni el grupo `0A` (OTA).
