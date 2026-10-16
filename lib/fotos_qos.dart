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
