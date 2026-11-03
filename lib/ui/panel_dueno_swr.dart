/// 1.23 (B3, diseño de Argón): estado SWR (stale-while-revalidate)
/// de una bandeja del Panel del dueño que vive en el servidor
/// (solicitudes de invitados, reportes App Plus).
///
/// La regla que corrige: PROHIBIDO el `catch (_) { lista = []; }`
/// que disfrazaba un fallo de red como bandeja vacía — el dueño
/// veía «todo en orden» sin estarlo. Aquí un fallo CONSERVA el
/// último payload bueno con su sello de hora habanero, y el
/// panel lo pinta con la nota «Sin red · datos de HH:mm»; sin
/// caché, el fallo se declara como error con reintento, nunca
/// como vacío honesto.
library;

class BandejaSwr<T> {
  /// Último payload bueno conocido (vacío hasta el primer éxito).
  List<T> datos = <T>[];

  /// Hora de La Habana del último éxito; null si nunca cargó.
  DateTime? sello;

  /// La última consulta falló (los datos, si hay, son caché).
  bool error = false;

  /// Primera carga en curso: aún no hay éxito ni fallo.
  bool get cargando => sello == null && !error;

  /// Hay un payload bueno que mostrar aunque la red falle.
  bool get conCache => sello != null;

  /// Falló y NUNCA cargó: la bandeja se declara «sin cargar»
  /// con reintento. Ojo (panel B3): la caché se mide por el
  /// SELLO, no por los datos — un éxito con lista vacía ES
  /// caché válida (vacío honesto), no ausencia de caché.
  bool get sinCargar => error && !conCache;

  /// Falló con un vacío confirmado antes: el último estado
  /// conocido es «sin pendientes», pero no se pudo revalidar.
  bool get vacioSinRevalidar => error && conCache && datos.isEmpty;

  void exito(List<T> lista, DateTime ahora) {
    datos = lista;
    sello = ahora;
    error = false;
  }

  /// Un fallo nunca borra lo bueno: solo marca el error.
  void fallo() {
    error = true;
  }

  /// Nota junto a los datos cuando son caché por fallo de red:
  /// «Sin red · datos de 9:41 AM». '' si no aplica.
  String get notaSinRed {
    if (!error || sello == null) return '';
    final s = sello!;
    final h = s.hour % 12 == 0 ? 12 : s.hour % 12;
    final mm = s.minute.toString().padLeft(2, '0');
    return 'Sin red · datos de $h:$mm ${s.hour < 12 ? 'AM' : 'PM'}';
  }
}
