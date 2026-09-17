# Anillo inteligente R21M — protocolo y app

App propia para un anillo inteligente chino `R21M` (familia *SmartHealth*, SDK Yucheng **YCBT**),
con el protocolo BLE obtenido por ingeniería inversa y **verificado contra el anillo real**.

Dispositivo de referencia: `R21M 1ED8` — MAC `07:29:00:12:1E:D8`.

## Estructura

| Carpeta | Qué es |
|---|---|
| `lecturas-ble/` | El escaneo BLE original del que partió todo |
| `docs/PROTOCOLO-R21M.md` | **El documento central.** Cada dato marcado como VERIFICADO / HIPÓTESIS / REFUTADO |
| `docs/hallazgos/` | Volcados crudos (mapa GATT) |
| `tools/ringlab/` | Laboratorio en Python: CLI para hablar con el anillo desde la PC |
| `app/` | La app Flutter (Android, iOS y Windows) |

## Cómo se construyó

En dos etapas deliberadamente separadas, para no depurar BLE y UI al mismo tiempo:

1. **`tools/ringlab`** — un CLI en Python con `bleak` para hablar con el anillo desde Windows,
   registrando cada trama a `capturas/*.jsonl`. Ahí se confirmó el protocolo y se corrigieron
   cinco errores de la documentación de referencia.
2. **`app/`** — la app Flutter. Su capa `lib/protocol/` es un puerto 1:1 del laboratorio, y se
   prueba contra las tramas reales capturadas en la etapa 1.

Ese vínculo es lo que da confianza: `app/test/protocol_test.dart` verifica que `buildFrame`
reproduce **byte a byte** nueve tramas que el anillo aceptó de verdad, CRC incluido.

## Lo esencial del protocolo

```
Trama:  [grupo:1][comando:1][longitud:2 LE][payload][CRC16:2 LE]
```

La longitud incluye cabecera y CRC. CRC-16/CCITT-FALSE. Canal de comandos `be940001`
(se escribe y las respuestas vuelven por ahí); notificaciones por `be940003`.
Respuestas: `00` = aceptado, `FE` = rechazado.

Detalles completos y estado de verificación de cada punto: `docs/PROTOCOLO-R21M.md`.

## Trampas que cuestan horas

- **El anillo acepta un solo central a la vez.** Mientras la app SmartHealth esté conectada,
  el anillo no se anuncia y no lo verás en ningún escaneo. Hay que cerrarla y olvidar el
  dispositivo en el Bluetooth del teléfono.
- **El reloj del anillo no avanza solo.** Conserva la última hora escrita, así que hay que
  sincronizarlo en cada conexión o el historial sale fechado mal.
- **`2a37` (Heart Rate estándar) no sirve como fuente.** Reemite el último valor
  indefinidamente y su bit de contacto con la piel dice "no detectado" incluso durante una
  medición correcta. La fuente real son las tramas `06 01`.
- **Las mediciones tardan.** Hasta ~50 s de silencio antes del primer valor es normal.
- **La presión arterial es una estimación óptica**, no una medición médica.

## Ejecutar

Laboratorio (PC):

```powershell
cd tools\ringlab
.\.venv\Scripts\python.exe -m ringlab self-test    # sin anillo
.\.venv\Scripts\python.exe -m ringlab scan
```

App:

```powershell
cd app
flutter test                  # 43 pruebas del protocolo, sin anillo
flutter run -d windows        # probar en la PC
flutter run -d <android>      # BLE no funciona en emulador; hace falta un móvil real
```

## Estado

Verificado contra el anillo: advertisement, mapa GATT, capa de trama y CRC, sincronización de
hora, información de dispositivo y batería, y medición en vivo de los tres tipos
(76 bpm · 98 % SpO2 · 112/73 mmHg).

Pendiente: los formatos de historial, sueño y contador de actividad. Los comandos responden
correctamente, pero el anillo estaba vacío al capturar. Se cierran usando el anillo un día
y durmiendo con él, y luego sincronizando.

## Licencia

Este proyecto se publica bajo licencia **MIT**. Ver [LICENSE](LICENSE).

Aviso: las lecturas de este anillo son de consumo, no de grado médico. La presión arterial en
particular es una estimación óptica. El software se ofrece sin garantía de ningún tipo.

### Terceros

- La capa BLE usa [`universal_ble`](https://pub.dev/packages/universal_ble) (BSD-3), libre también
  para uso comercial. Se evitó `flutter_blue_plus` porque exige licencia de pago para uso no
  personal.
- La documentación de partida del protocolo procede de
  [narey83/vitals-smart-ring-app](https://github.com/narey83/vitals-smart-ring-app), también MIT.
  Ninguna parte de su código se reutiliza aquí: la implementación es propia y sus afirmaciones se
  verificaron —y en siete puntos se corrigieron— contra el dispositivo real.
