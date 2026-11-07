/// 1.28 (M5, ítem fijo — Pieza G): modelos y funciones
/// puras del compositor de Anuncios del Panel. Los
/// anuncios viven en el servidor (tabla cliente_anuncios
/// de Supabase, Pieza S de la 0.18) y se administran por
/// las RPC admin_anuncio_* (guarda es_dueno() en el
/// servidor); aquí solo se interpreta su jsonb, sin
/// Flutter ni red, como el resto de paneles de la casa.
library;

/// Un anuncio tal como lo devuelve admin_anuncios_listar.
/// [desde]/[hasta] son los ISO crudos del servidor
/// (instantes UTC); null = sin límite por ese lado.
class AnuncioAdmin {
  final int id;
  final String? titulo;
  final String cuerpoMd;
  final String audiencia; // todos|clientes|invitados|especificos
  final List<int> clienteIds;
  final bool descartable;
  final String? desde;
  final String? hasta;
  final bool activo;
  final String creadoEn;
  final String actualizadoEn;

  const AnuncioAdmin({
    required this.id,
    required this.titulo,
    required this.cuerpoMd,
    required this.audiencia,
    required this.clienteIds,
    required this.descartable,
    required this.desde,
    required this.hasta,
    required this.activo,
    required this.creadoEn,
    required this.actualizadoEn,
  });

  /// Estado de publicación en el instante [ahoraUtc]:
  /// 'retirado' (activo=false: el dueño lo apagó),
  /// 'expirado' (la ventana ya cerró), 'programado'
  /// (la ventana aún no abre) o 'visible' (los clientes
  /// a los que les toca lo están viendo ahora).
  String estadoEn(DateTime ahoraUtc) {
    if (!activo) return 'retirado';
    final h = hasta == null ? null : DateTime.tryParse(hasta!);
    if (h != null && !ahoraUtc.isBefore(h)) return 'expirado';
    final d = desde == null ? null : DateTime.tryParse(desde!);
    if (d != null && ahoraUtc.isBefore(d)) return 'programado';
    return 'visible';
  }

  /// La audiencia en texto corto para la tarjeta.
  String get audienciaTexto => switch (audiencia) {
        'clientes' => 'Solo clientes',
        'invitados' => 'Solo invitados',
        'especificos' => 'Solo ${clienteIds.length} clientes',
        _ => 'Todos (clientes e invitados)',
      };

  AnuncioAdmin conActivo(bool v) => AnuncioAdmin(
        id: id,
        titulo: titulo,
        cuerpoMd: cuerpoMd,
        audiencia: audiencia,
        clienteIds: clienteIds,
        descartable: descartable,
        desde: desde,
        hasta: hasta,
        activo: v,
        creadoEn: creadoEn,
        actualizadoEn: actualizadoEn,
      );
}

/// Lo que el formulario del compositor entrega al
/// guardar. [desdeHabana]/[hastaHabana] son wall-clock
/// de La Habana (lo que el dueño eligió en los
/// selectores); quien llama a la RPC los convierte a
/// instante con isoHabana. [id] null = anuncio nuevo.
class DatosAnuncio {
  final int? id;
  final String? titulo;
  final String cuerpoMd;
  final String audiencia;
  final List<int> clienteIds;
  final bool descartable;
  final DateTime? desdeHabana;
  final DateTime? hastaHabana;
  final bool activo;

  const DatosAnuncio({
    required this.id,
    required this.titulo,
    required this.cuerpoMd,
    required this.audiencia,
    required this.clienteIds,
    required this.descartable,
    required this.desdeHabana,
    required this.hastaHabana,
    required this.activo,
  });
}

int _enteroPos(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _texto(Object? v) => v == null ? '' : '$v';

/// Corrección A2-D3 (auditorías 1.28): la ventana del
/// anuncio entra SANEADA al modelo. Un desde/hasta vacío
/// o no-ISO (un anuncio viejo, editado por SQL o con el
/// reloj cambiado) dejaba al panel con un DateTime.parse
/// duro que lanzaba en el PRIMER frame: la pantalla de
/// anuncios quedaba inabrible y el anuncio ni siquiera
/// se podía borrar desde la app. Ventana ilegible =
/// sin ventana (null); al editar y guardar, el dueño la
/// repone con los selectores.
String? _isoVentana(Object? v) {
  final s = v?.toString().trim() ?? '';
  if (s.isEmpty) return null;
  return DateTime.tryParse(s) == null ? null : s;
}

/// Interpreta el jsonb de admin_anuncios_listar
/// ({ok, anuncios:[...]}). Tolerante como el resto de
/// paneles: una fila rara se salta; una fila sin id
/// positivo no puede editarse ni borrarse, fuera.
List<AnuncioAdmin> parseAnunciosAdmin(Object? json) {
  if (json is! Map) return const [];
  final crudos = json['anuncios'];
  if (crudos is! List) return const [];
  final out = <AnuncioAdmin>[];
  for (final e in crudos) {
    if (e is! Map) continue;
    final id = _enteroPos(e['id']);
    if (id <= 0) continue;
    final ids = <int>[];
    final crudosIds = e['cliente_ids'];
    if (crudosIds is List) {
      for (final x in crudosIds) {
        final n = _enteroPos(x);
        if (n > 0 && !ids.contains(n)) ids.add(n);
      }
    }
    final tituloCrudo = e['titulo']?.toString().trim();
    out.add(AnuncioAdmin(
      id: id,
      titulo: (tituloCrudo == null || tituloCrudo.isEmpty)
          ? null
          : tituloCrudo,
      cuerpoMd: _texto(e['cuerpo_md']),
      audiencia: _texto(e['audiencia']).isEmpty
          ? 'todos'
          : _texto(e['audiencia']),
      clienteIds: ids,
      descartable: e['descartable'] != false,
      desde: _isoVentana(e['desde']),
      hasta: _isoVentana(e['hasta']),
      activo: e['activo'] != false,
      creadoEn: _texto(e['creado_en']),
      actualizadoEn: _texto(e['actualizado_en']),
    ));
  }
  return out;
}

/// Mensaje honesto para el código de error de las RPC
/// admin_anuncio_* (la guarda es_dueno() y las
/// validaciones viven en el servidor; la app traduce,
/// no sustituye). Un código desconocido se muestra tal
/// cual: mejor un código visible que un «error» mudo.
String mensajeErrorAnuncio(String? codigo) {
  switch (codigo) {
    case 'SOLO_DUENO':
      return 'Solo el dueño puede gestionar los anuncios.';
    case 'AUDIENCIA_INVALIDA':
      return 'La audiencia elegida no es válida.';
    case 'CUERPO_INVALIDO':
      return 'El texto del anuncio debe tener entre 1 y '
          '4000 caracteres.';
    case 'SIN_DESTINATARIOS':
      return 'Elige al menos un cliente para este anuncio.';
    case 'VENTANA_INVALIDA':
      return 'La fecha «hasta» debe ser posterior a «desde».';
    case 'NO_EXISTE':
      return 'Ese anuncio ya no existe en el servidor.';
    case 'SIN_CONFIRMAR':
      // Corrección A4-D4: la respuesta se perdió y ni
      // recargando se pudo comprobar si el guardado
      // aterrizó: no se afirma ni que se guardó ni que
      // no — se pide mirar la lista antes de repetirlo
      // (repetirlo a ciegas era el duplicado).
      return 'La respuesta del servidor se perdió y no '
          'se pudo comprobar si se guardó. Revisa la '
          'lista: si el anuncio ya está, no lo crees '
          'otra vez.';
    case null:
    case '':
      return 'El servidor no aplicó el cambio.';
    default:
      return 'El servidor respondió: $codigo';
  }
}
