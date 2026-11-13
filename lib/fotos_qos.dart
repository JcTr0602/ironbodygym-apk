/// v1.3.4 Ítem 5 (QoS de red y fotos_cola, veredicto de Argón).
///
/// Heurísticas PURAS (cero dependencias de plataforma, testeables sin
/// red ni BD) para la degradación elegante de la variante 'original':
/// - 'thumb' y 'display' suben siempre que ops_queue esté vacía.
/// - 'original' (pesada) solo se reclama si hay HOLGURA (ops_queue
///   lleva vacía más de 5 minutos) Y VELOCIDAD (el último chunk de
///   'display' subió rápido: < 5 s para 128 KB, ≈25.6 KB/s).
/// 100% agnóstico a VPNs: no usa connectivity_plus (prohibido por
/// Argón: con VPN reporta 'vpn'/'other' inconsistente).
library;

/// Minutos continuos que ops_queue debe llevar vacía para reclamar
/// la variante 'original'.
const int kHolguraOpsMinutos = 5;

/// v1.3.4 (veredicto de Argón, Bug A1.3): minutos de holgura EXTENDIDA
/// para reclamar 'original' cuando NO hay medición de velocidad de
/// 'display' disponible (_ultimoDisplayRapido == false: reinicio
/// reciente, o no quedan 'display' por subir para medir). Sin este
/// fallback el 'original' quedaría diferido para siempre.
const int kHolguraOpsMinutosSinDisplay = 15;

/// Umbral de velocidad: bytes/segundo equivalentes a 128 KB en 5 s.
const double kVelocidadMinBytesPorSeg = 128 * 1024 / 5;

/// v1.4.0 (Argón, revisión fotos): si la variante 'original' ya pesa
/// esto o menos (lo normal tras comprimir a 1600px WebP q80:
/// ~180-350 KB), NO se retiene por holgura/velocidad: sube en el
/// mismo ciclo tras thumb/display. Motivo: la retención hacía que
/// el Foreground Service se apagara antes de reclamarla y el reloj
/// de holgura (en RAM, por isolate) nunca acumulaba los minutos
/// exigidos — la foto quedaba atrapada días en campo.
///
/// v1.13.0 (G5): BYPASS RETIRADO. La constante queda solo como
/// referencia histórica: procesarCola ya no la usa para saltar la
/// puerta QoS (toda 'original' espera a originalPermitidoFallback).
///
/// 1.33 (rapidez de fotos): la constante vuelve a tener uso, pero
/// SOLO como umbral de tamaño de [originalInmediataPermitida], que
/// añade la guarda que el bypass de la v1.4.0 no tenía (sin ops
/// pendientes al reclamar). El bypass histórico sigue retirado.
const int kTamanoMaxOriginalInmediato = 512 * 1024;

/// ¿Puede reclamarse la variante 'original'?
/// [opsVaciaDesde]: instante en que ops_queue se observó vacía por
/// última vez (null = nunca observada vacía, o volvió a tener trabajo
/// y el reloj se reinició).
/// [ultimoDisplayRapido]: si el último chunk de 'display' medido
/// subió rápido según [chunkDisplayRapido].
bool originalPermitido({
  required DateTime? opsVaciaDesde,
  required bool ultimoDisplayRapido,
  required DateTime ahora,
}) {
  if (opsVaciaDesde == null || !ultimoDisplayRapido) return false;
  return ahora.difference(opsVaciaDesde) >
      const Duration(minutes: kHolguraOpsMinutos);
}

/// ¿El chunk de [bytes] transferido entre [inicio] y [fin] subió rápido?
/// Rápido = velocidad efectiva >= 128 KB / 5 s (≈25.6 KB/s).
bool chunkDisplayRapido(int bytes, DateTime inicio, DateTime fin) {
  final ms = fin.difference(inicio).inMilliseconds;
  if (ms <= 0 || bytes <= 0) return false;
  return (bytes * 1000 / ms) >= kVelocidadMinBytesPorSeg;
}

/// v1.3.4 (veredicto de Argón, Bug A1.3): ¿puede reclamarse la variante
/// 'original', con fallback cuando no hay medición de velocidad?
///
/// Primero aplica [originalPermitido] (holgura 5 min + último display
/// rápido). Si no hay medición de velocidad disponible
/// ([ultimoDisplayRapido] == false), el 'original' se permite tras la
/// holgura EXTENDIDA de 15 min de ops_queue vacía. La holgura mayor
/// compensa la falta de medición: 15 min de inactividad real es señal
/// suficiente de que la red está libre para la variante pesada.
/// Nunca true si [opsVaciaDesde] es null.
bool originalPermitidoFallback({
  required DateTime? opsVaciaDesde,
  required bool ultimoDisplayRapido,
  required DateTime ahora,
}) {
  if (originalPermitido(
    opsVaciaDesde: opsVaciaDesde,
    ultimoDisplayRapido: ultimoDisplayRapido,
    ahora: ahora,
  )) {
    return true;
  }
  // Hay medición pero la holgura normal no alcanza: el fallback no
  // puede ser más permisivo que la regla base.
  if (ultimoDisplayRapido) return false;
  if (opsVaciaDesde == null) return false;
  return ahora.difference(opsVaciaDesde) >
      const Duration(minutes: kHolguraOpsMinutosSinDisplay);
}

/// 1.33 (rapidez de fotos): vía INMEDIATA para la variante 'original'
/// pequeña. ¿Puede subirse YA, en este mismo ciclo, sin esperar a la
/// puerta QoS de [originalPermitidoFallback]?
///
/// Permitida si se cumplen LAS DOS:
/// - el archivo pesa más de 0 y como máximo
///   [kTamanoMaxOriginalInmediato] (512 KB): la 'original' típica de
///   cliente tras comprimir pesa ~70-350 KB, comparable a un chunk
///   de 'display' (que sube sin puerta); su demora era la puerta,
///   no el tamaño ni el enlace;
/// - en el momento de reclamar NO hay operaciones pendientes que no
///   sean de foto ([opsPendientesNoFoto] == 0): la foto sube detrás
///   de los datos, nunca contra ellos.
///
/// Por qué esto NO revive el defecto que retiró el bypass en G5: el
/// bypass de la v1.4.0 saltaba la puerta QoS mirando SOLO el tamaño —
/// dejaba subir originales CON ops en cola en red lenta, compitiendo
/// con los cobros. La diferencia es la segunda condición: con CUALQUIER
/// op transaccional pendiente al reclamar, la vía inmediata se cierra
/// y manda la puerta de siempre. Y si una op entra a mitad de la
/// subida, la protege la pausa ya existente (debePausarPorCobro).
///
/// Las originales de más de 512 KB no usan esta vía: siguen con la
/// puerta actual (5 min + display rápido, o 15 min sin medición).
bool originalInmediataPermitida({
  required int tamanoBytes,
  required int opsPendientesNoFoto,
}) {
  return tamanoBytes > 0 &&
      tamanoBytes <= kTamanoMaxOriginalInmediato &&
      opsPendientesNoFoto == 0;
}
