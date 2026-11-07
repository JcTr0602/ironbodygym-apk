// lib/comunidad_panel.dart
// 1.27 (Comunidad MVP, Pieza G): interpretación del
// jsonb de admin_comunidad_perfiles. Tolerante como el
// resto de paneles: una fila rara se salta, nunca
// tumba la pantalla.

/// Un perfil de cliente en la Comunidad, tal como lo
/// ve la administración.
class PerfilComunidadAdmin {
  final int clienteId;
  final String nombre;
  final bool visible;
  final bool ocultoAdmin;
  final bool mostrarMarcas;
  final bool mostrarActividad;
  final bool mostrarRutina;
  final bool mostrarConstancia;

  const PerfilComunidadAdmin({
    required this.clienteId,
    required this.nombre,
    required this.visible,
    required this.ocultoAdmin,
    required this.mostrarMarcas,
    required this.mostrarActividad,
    required this.mostrarRutina,
    required this.mostrarConstancia,
  });

  /// Los bloques que el cliente tiene encendidos, en
  /// texto corto para la tarjeta.
  List<String> get bloquesActivos => [
        if (mostrarMarcas) 'Marcas',
        if (mostrarActividad) 'Actividad',
        if (mostrarRutina) 'Rutina',
        if (mostrarConstancia) 'Constancia',
      ];

  PerfilComunidadAdmin conOculto(bool oculto) => PerfilComunidadAdmin(
        clienteId: clienteId,
        nombre: nombre,
        visible: visible,
        ocultoAdmin: oculto,
        mostrarMarcas: mostrarMarcas,
        mostrarActividad: mostrarActividad,
        mostrarRutina: mostrarRutina,
        mostrarConstancia: mostrarConstancia,
      );
}

/// 1.28 (M5-B4): los conteos de cabecera de la lista de
/// Comunidad. «Con vitrina» = el CLIENTE la encendió
/// (su decisión; el dueño nunca la enciende por él);
/// «visibles» = los que hoy salen en el directorio
/// (vitrina encendida y no ocultos por el dueño);
/// «ocultos por ti» = los que el dueño retiró.
({int conVitrina, int visibles, int ocultosPorTi}) conteosComunidad(
    List<PerfilComunidadAdmin> perfiles) {
  var conVitrina = 0;
  var visibles = 0;
  var ocultos = 0;
  for (final p in perfiles) {
    if (p.visible) conVitrina++;
    if (p.visible && !p.ocultoAdmin) visibles++;
    if (p.ocultoAdmin) ocultos++;
  }
  return (
    conVitrina: conVitrina,
    visibles: visibles,
    ocultosPorTi: ocultos,
  );
}

/// Quita acentos y pasa a minúsculas para comparar
/// nombres sin que «José» y «jose» sean dos mundos.
/// Corrección A2-D5 (auditorías 1.28): también pliega
/// los acentos DESCOMPUESTOS (letra + marca combinante
/// U+0301, como llegan de algunos teclados): sin esto,
/// buscar «jose» no encontraba un «José» descompuesto
/// porque la marca sobrevivía a la comparación.
String _sinAcentos(String s) {
  const mapa = {
    'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u',
    'ü': 'u', 'ñ': 'n',
  };
  final b = StringBuffer();
  for (final r in s.toLowerCase().runes) {
    // Marcas combinantes (U+0300–U+036F): se descartan;
    // la letra base queda y pasa por el mapa igual.
    if (r >= 0x0300 && r <= 0x036F) continue;
    final ch = String.fromCharCode(r);
    b.write(mapa[ch] ?? ch);
  }
  return b.toString();
}

/// 1.28 (M5-B4): el buscador de la lista de Comunidad —
/// filtra por nombre, sin acentos ni mayúsculas.
/// Consulta vacía = la lista entera.
List<PerfilComunidadAdmin> filtrarPerfilesComunidad(
    List<PerfilComunidadAdmin> perfiles, String consulta) {
  final q = _sinAcentos(consulta.trim());
  if (q.isEmpty) return perfiles;
  return perfiles
      .where((p) => _sinAcentos(p.nombre).contains(q))
      .toList();
}

/// Interpreta {ok, perfiles:[...]} de
/// admin_comunidad_perfiles. Si ok no es true o la
/// forma no es la esperada, devuelve lista vacía.
List<PerfilComunidadAdmin> parsePerfilesComunidad(
    Map<String, dynamic> json) {
  if (json['ok'] != true) return const [];
  final lista = json['perfiles'];
  if (lista is! List) return const [];
  final out = <PerfilComunidadAdmin>[];
  for (final e in lista) {
    if (e is! Map) continue;
    // 1.28 (M5-A2/C-R3M5-H8): el id también vale como
    // TEXTO parseable: con la exigencia de num, un
    // perfil cuyo id bajara como cadena se saltaba en
    // silencio y quedaba INMODERABLE desde el panel.
    final idCrudo = e['cliente_id'];
    final id = idCrudo is num
        ? idCrudo.toInt()
        : int.tryParse('${idCrudo ?? ''}');
    if (id == null) continue;
    // Un nombre vacío (o de solo espacios) pintaba una
    // tarjeta sin título que no se podía identificar:
    // cae a «Sin nombre» como el resto de la casa.
    final nombreCrudo = '${e['nombre'] ?? ''}'.trim();
    out.add(PerfilComunidadAdmin(
      clienteId: id,
      nombre: nombreCrudo.isEmpty ? 'Sin nombre' : nombreCrudo,
      visible: e['visible'] == true,
      ocultoAdmin: e['oculto_admin'] == true,
      mostrarMarcas: e['mostrar_marcas'] == true,
      mostrarActividad: e['mostrar_actividad'] == true,
      mostrarRutina: e['mostrar_rutina'] == true,
      mostrarConstancia: e['mostrar_constancia'] == true,
    ));
  }
  return out;
}
