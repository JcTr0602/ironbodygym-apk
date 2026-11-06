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
    final id = e['cliente_id'];
    if (id is! num) continue;
    out.add(PerfilComunidadAdmin(
      clienteId: id.toInt(),
      nombre: (e['nombre'] ?? 'Sin nombre').toString(),
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
