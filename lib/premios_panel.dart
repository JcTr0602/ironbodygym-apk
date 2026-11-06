/// Premios (Pieza G, 1.26): modelos y funciones puras de
/// la bandeja «Premios por aprobar» del Panel. La RPC
/// admin_premios_vales devuelve los vales reclamados por
/// los clientes en su app y los resueltos recientes; aquí
/// solo se interpreta su jsonb, sin Flutter ni red.
library;

/// Un vale reclamado, pendiente de decisión del dueño.
class ValePendiente {
  final int id;
  final int clienteId;
  final String nombre;
  final String telefono;
  final String? pagadoHasta;
  final String logroId;
  final int premioDias;
  final int diasAlReclamar;
  final String creadoEn;

  const ValePendiente({
    required this.id,
    required this.clienteId,
    required this.nombre,
    required this.telefono,
    required this.pagadoHasta,
    required this.logroId,
    required this.premioDias,
    required this.diasAlReclamar,
    required this.creadoEn,
  });
}

/// Un vale ya resuelto (contexto reciente de la bandeja).
class ValeReciente {
  final int id;
  final int clienteId;
  final String nombre;
  final int premioDias;
  final String estado; // 'canjeado' | 'rechazado'
  final String resueltoEn;
  final String resueltoNota;

  const ValeReciente({
    required this.id,
    required this.clienteId,
    required this.nombre,
    required this.premioDias,
    required this.estado,
    required this.resueltoEn,
    required this.resueltoNota,
  });

  bool get canjeado => estado == 'canjeado';
}

/// La bandeja completa que devuelve la RPC.
class BandejaPremios {
  final List<ValePendiente> vales;
  final List<ValeReciente> recientes;

  const BandejaPremios({required this.vales, required this.recientes});

  static const vacia = BandejaPremios(vales: [], recientes: []);
}

int _entero(Object? v) {
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

String _texto(Object? v) => v == null ? '' : '$v';

/// Interpreta el jsonb de admin_premios_vales. Tolerante:
/// cualquier pieza ausente o de otro tipo se degrada a
/// vacío/0 en vez de romper la bandeja.
BandejaPremios parseBandejaPremios(Object? json) {
  if (json is! Map) return BandejaPremios.vacia;
  final vales = <ValePendiente>[];
  final crudosV = json['vales'];
  if (crudosV is List) {
    for (final e in crudosV) {
      if (e is! Map) continue;
      vales.add(ValePendiente(
        id: _entero(e['id']),
        clienteId: _entero(e['cliente_id']),
        nombre: _texto(e['nombre']),
        telefono: _texto(e['telefono']),
        pagadoHasta: e['pagado_hasta']?.toString(),
        logroId: _texto(e['logro_id']),
        premioDias: _entero(e['premio_dias']),
        diasAlReclamar: _entero(e['dias_al_reclamar']),
        creadoEn: _texto(e['creado_en']),
      ));
    }
  }
  final recientes = <ValeReciente>[];
  final crudosR = json['recientes'];
  if (crudosR is List) {
    for (final e in crudosR) {
      if (e is! Map) continue;
      recientes.add(ValeReciente(
        id: _entero(e['id']),
        clienteId: _entero(e['cliente_id']),
        nombre: _texto(e['nombre']),
        premioDias: _entero(e['premio_dias']),
        estado: _texto(e['estado']),
        resueltoEn: _texto(e['resuelto_en']),
        resueltoNota: _texto(e['resuelto_nota']),
      ));
    }
  }
  return BandejaPremios(vales: vales, recientes: recientes);
}

/// Título humano del logro de un vale (el catálogo de
/// Premios vive en la app de Clientes; aquí solo se
/// nombran los que Gestión puede recibir).
String tituloLogroPremio(String logroId) {
  switch (logroId) {
    case 'constancia_real':
      return 'Constancia real';
    default:
      return logroId;
  }
}

/// Los pendientes que la pantalla debe mostrar: fuera
/// los ya resueltos EN ESTE teléfono (la op de canje
/// está encolada y el servidor aún los ve reclamados
/// hasta que la aplica; sin este filtro, el dueño
/// podría aprobar dos veces el mismo vale).
List<ValePendiente> valesVisibles(
    List<ValePendiente> vales, Set<int> resueltosLocales) {
  if (resueltosLocales.isEmpty) return vales;
  return vales.where((v) => !resueltosLocales.contains(v.id)).toList();
}
