/// UUIDs VERIFICADOS sobre el anillo real (07:29:00:12:1E:D8).
/// Volcado completo en `docs/hallazgos/gatt-R21M-20260917-113905.md`.
class RingUuids {
  /// Servicio propietario que lleva el canal de comandos.
  static const commandService = 'be940000-7333-be46-b7ae-689e71722bd5';

  /// Canal de comandos. OJO: es `indicate` + `write` + `write-without-response`,
  /// NO `read`. Se escribe aquí Y las respuestas vuelven por aquí mismo
  /// (la doc del R11M decía `read`; es una de las correcciones que encontramos).
  static const commandChar = 'be940001-7333-be46-b7ae-689e71722bd5';

  /// Notificaciones iniciadas por el anillo: datos en vivo `06 xx`, historial `05 xx`.
  /// Propiedad: `indicate`.
  static const notifyChar = 'be940003-7333-be46-b7ae-689e71722bd5';

  /// Servicio 0xFEE7 (anunciado en el advertisement).
  static const activityService = '0000fee7-0000-1000-8000-00805f9b34fb';

  /// Actividad en vivo, ~2 s. Propiedad: `indicate`.
  static const activityChar = '0000fea1-0000-1000-8000-00805f9b34fb';

  /// Heart Rate estándar. Propiedad: `notify`.
  /// NO usar como fuente de muestras: reemite el último valor indefinidamente y
  /// su bit de contacto con la piel miente incluso durante una medición correcta.
  static const heartRateService = '0000180d-0000-1000-8000-00805f9b34fb';
  static const heartRateChar = '00002a37-0000-1000-8000-00805f9b34fb';

  /// OTA de JieLi. No tocar.
  static const otaService = '0000ae00-0000-1000-8000-00805f9b34fb';

  /// Prefijo del nombre anunciado por este modelo.
  static const namePrefix = 'R21M';
}
