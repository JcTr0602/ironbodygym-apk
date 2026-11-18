/// Tipos de pago dinámicos (v1.0.16).
///
/// El servidor los envía en el blob `ajustes` (clave 'tipos_pago').
/// Si no vienen (servidor viejo o sin sincronizar), se construyen desde
/// las claves fijas como fallback.
library;

import 'localdb.dart';

class TipoPago {
  final String id;
  final String nombre;
  final double monto;
  final int dias;
  final bool activo;
  final bool soloMenores;
  const TipoPago({
    required this.id,
    required this.nombre,
    required this.monto,
    required this.dias,
    this.activo = true,
    this.soloMenores = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'nombre': nombre,
        'monto': monto,
        'dias': dias,
        'activo': activo,
        if (soloMenores) 'solo_menores': true,
      };

  static TipoPago desdeJson(Map<String, dynamic> j) => TipoPago(
        id: '${j['id'] ?? ''}',
        nombre: '${j['nombre'] ?? ''}',
        // Corrección A2-D2: lector tolerante — el blob puede
        // traer el importe como texto (editado desde el bot
        // o por SQL) y el cast duro `as num?` lanzaba
        // TypeError en vez de degradar a 0.
        monto: montoAjusteTolerante(j['monto']) ?? 0,
        dias: montoAjusteTolerante(j['dias'])?.toInt() ?? 30,
        activo: j['activo'] != false,
        soloMenores: j['solo_menores'] == true,
      );
}

/// Tipo inicial del diálogo de pago.
///
/// NO es una aplicación automática del descuento: solo el valor
/// preseleccionado del desplegable, que el entrenador puede cambiar
/// antes de confirmar en la vista previa.
///
/// - Adulto: 'mensual' como siempre (o el primer tipo si no existe).
/// - Menor: SIEMPRE 'menores' (su tarifa, 1500 por defecto).
///   Decisión de Jc 2026-11-04 (1.24 Bloque 1, B H-1), que DEROGA
///   su regla del 2026-10-25 («la opción de 30 días más barata»):
///   aquella preselección caía en ofertas puntuales (el caso de
///   Keren: oferta_50 cobrada a una menor dos días seguidos) y la
///   tarifa del menor dejaba de ser el punto de partida. La oferta
///   sigue existiendo y el entrenador puede elegirla a mano; lo
///   que cambia es solo dónde abre el desplegable. Con 'menores'
///   preseleccionado, el motor sigue aplicando Casa (0) o la
///   tarifa especial vigente por encima, como manda la precedencia
///   (1.19, Argón A1).
/// - Menor sin tipo 'menores' en la lista: el primer tipo.
///
/// [tiposDisp] no debe estar vacía (el diálogo ya lo garantiza);
/// si llega vacía, se lanza ArgumentError en vez del StateError
/// críptico de `.first`.
TipoPago tipoInicialPago(
  List<TipoPago> tiposDisp, {
  required bool menor,
}) {
  if (tiposDisp.isEmpty) {
    throw ArgumentError('tipoInicialPago: lista de tipos vacía');
  }
  if (!menor) {
    return tiposDisp.firstWhere((t) => t.id == 'mensual',
        orElse: () => tiposDisp.first);
  }
  return tiposDisp.firstWhere((t) => t.id == 'menores',
      orElse: () => tiposDisp.first);
}

/// (M2-A A6) FUENTE ÚNICA del precio de menores, pura sobre
/// los ajustes crudos: el monto del tipo 'menores' del blob
/// `tipos_pago` manda (es el que el dueño edita en el editor
/// de tipos y el que cobra el diálogo de cobro); la clave fija
/// 'mensualidad_menores' es el respaldo histórico; 1500 es el
/// suelo. TODOS los lectores (getTiposPago, precioMenor,
/// preciosVigentes) resuelven por aquí: antes Inscribir
/// cobraba la clave fija y Renovar el tipo del blob — dos
/// fuentes editables por separado que divergían en silencio.
double precioMenoresDesdeAjustes(Map<String, dynamic> aj) {
  final crudo = aj['tipos_pago'];
  if (crudo is List) {
    for (final t in crudo) {
      if (t is Map && '${t['id']}' == 'menores') {
        // Corrección A2-D2: con el importe como texto
        // («1600», escribible desde el bot/SQL) el cast
        // duro lanzaba TypeError y tumbaba preciosVigentes
        // y el diálogo de cobro del menor; el lector
        // tolerante degrada al respaldo, como la función
        // promete.
        final m = montoAjusteTolerante(t['monto']);
        if (m != null && m > 0) return m;
      }
    }
  }
  final fijo = montoAjusteTolerante(aj['mensualidad_menores']);
  if (fijo != null && fijo > 0) return fijo;
  return 1500;
}

/// Lector tolerante de un importe de ajustes: num finito o
/// texto parseable («1600»); cualquier otra cosa es null.
/// Misma semántica que `NominaCalc.montoTolerante` (clase N-2:
/// Infinity/NaN no son importes), pero sin importar
/// nomina_calc (que importa negocio → tipos_pago: ciclo).
/// El blob de ajustes también se edita desde el bot y por
/// SQL: un importe puede llegar como texto y un cast duro
/// `as num?` lanzaría TypeError en vez de degradar
/// (correcciones A2-D2 / A5-D2).
double? montoAjusteTolerante(dynamic v) {
  if (v is num) {
    final d = v.toDouble();
    return d.isFinite ? d : null;
  }
  if (v is String) {
    final d = double.tryParse(v.trim());
    return (d != null && d.isFinite) ? d : null;
  }
  return null;
}

/// Lector tolerante de un FLAG de ajustes (Yunque 3, K6-3):
/// vale si es 1, true o '1' — la misma tolerancia de
/// `esCasaTolerante`. El gemelo de [montoAjusteTolerante]
/// para los interruptores del blob (p. ej. promo_suplementos):
/// el cast duro `(v as num?)` reventaba si el flag llegaba
/// como bool desde el bot/SQL y tumbaba la carga entera de
/// la pantalla (en Venta de Suplemento se llevaba también la
/// tasa USD que se asignaba después, en el mismo cierre).
bool flagAjusteTolerante(dynamic v) => v == 1 || v == true || v == '1';

/// (Corrección A5-D2) ESCRITURA de la fuente única del precio
/// de menores: devuelve el blob `tipos_pago` COMPLETO (sin
/// filtros de activos/menores) con el monto del tipo
/// 'menores' fijado en [monto]. Es el reverso de
/// [precioMenoresDesdeAjustes]: el editor de Configuración
/// persiste por aquí (op `guardar_tipos_pago`), no por la
/// clave fija legacy — antes el campo «Mensualidad menores»
/// editaba la clave y el cobro seguía leyendo el blob, así
/// que el cambio del dueño no cambiaba lo cobrado.
///
/// - Blob con 'menores': solo cambia su monto; el resto de
///   tipos queda intacto.
/// - Blob sin 'menores': se inserta tras 'mensual' (la misma
///   posición en la que getTiposPago lo sintetiza).
/// - Sin blob: se materializa la lista por defecto que
///   getTiposPago construye desde las claves fijas, para que
///   al nacer el blob no se pierdan mensual/semanal/quincenal.
List<Map<String, dynamic>> blobTiposConPrecioMenores(
    Map<String, dynamic> aj, double monto) {
  final crudo = aj['tipos_pago'];
  final lista = <Map<String, dynamic>>[
    if (crudo is List)
      for (final t in crudo)
        if (t is Map) Map<String, dynamic>.from(t),
  ];
  if (lista.isEmpty) {
    double valor(String k, double def) =>
        montoAjusteTolerante(aj[k]) ?? def;
    lista.addAll([
      {
        'id': 'mensual',
        'nombre': 'Mensualidad',
        'monto': valor('mensualidad', 2000),
        'dias': 30,
        'activo': true,
      },
      {
        'id': 'menores',
        'nombre': 'Mensualidad menores',
        'monto': monto,
        'dias': 30,
        'activo': true,
        'solo_menores': true,
      },
      {
        'id': 'semanal',
        'nombre': 'Semana',
        'monto': valor('pago_semanal', 600),
        'dias': 7,
        'activo': true,
      },
      {
        'id': 'quincenal',
        'nombre': 'Quincena',
        'monto': valor('pago_quincenal', 1200),
        'dias': 15,
        'activo': true,
      },
    ]);
    return lista;
  }
  final i = lista.indexWhere((t) => '${t['id']}' == 'menores');
  if (i >= 0) {
    lista[i]['monto'] = monto;
  } else {
    final iMensual = lista.indexWhere((t) => '${t['id']}' == 'mensual');
    lista.insert(iMensual >= 0 ? iMensual + 1 : 0, {
      'id': 'menores',
      'nombre': 'Mensualidad menores',
      'monto': monto,
      'dias': 30,
      'activo': true,
      'solo_menores': true,
    });
  }
  return lista;
}

/// (Corrección PROPIA-F5-01) Correspondencia tipo del blob →
/// clave plana de precio: la inversa de `kTipoBlobPorClavePrecio`
/// (bloque2_resto.dart) y el espejo del `_CLAVE_A_TIPO` del
/// servidor (ironbody/db/core.py), cuyo `set_tipos_pago` hace
/// write-through del blob a estas claves al aplicar la op
/// `guardar_tipos_pago`. Las demás claves de precio
/// (transferencia, pago_diario) no tienen tipo en el blob: su
/// única fuente es la clave plana y no se tocan aquí.
const kClavePlanaPorTipoPrecio = <String, String>{
  'mensual': 'mensualidad',
  'menores': 'mensualidad_menores',
  'semanal': 'pago_semanal',
  'quincenal': 'pago_quincenal',
};

/// (Corrección PROPIA-F5-01) PURO: los ajustes tras guardar
/// [tipos] como blob `tipos_pago`: el blob queda fijado Y las
/// claves planas de los tipos fijos presentes en la lista se
/// mueven CON él, en el mismo acto — el write-through local
/// que el servidor sí hace y el editor de tipos de Admin no
/// hacía. Sin él conviven dos lectores del mismo precio en el
/// mismo teléfono: el diálogo de cobro lee el blob (precio
/// nuevo) y `preciosVigentes()` —renovación rápida de ficha,
/// cuentas por cobrar, atrasados— lee las claves planas
/// (precio viejo), mientras el servidor ya asienta con el
/// nuevo al aplicar la op (que viaja primero en la cola
/// FIFO): recibo con un precio y asiento con otro.
/// - Tipo sin correspondencia (personalizados): no toca
///   ninguna clave; tipo fijo AUSENTE de la lista: su clave
///   queda como está — igual que `set_tipos_pago`, que solo
///   escribe las claves de los tipos que la lista trae.
/// - Es el reverso de [blobTiposTrasCambiosPrecios]: aquella
///   mueve el blob cuando cambia la clave; esta mueve las
///   claves cuando cambia el blob.
Map<String, dynamic> ajustesTrasGuardarTipos(
    Map<String, dynamic> aj, List<Map<String, dynamic>> tipos) {
  final nuevos = {...aj, 'tipos_pago': tipos};
  for (final t in tipos) {
    final clave = kClavePlanaPorTipoPrecio['${t['id']}'];
    if (clave == null) continue;
    final monto = montoAjusteTolerante(t['monto']);
    if (monto != null) nuevos[clave] = monto;
  }
  return nuevos;
}

/// Lee los tipos de pago de los ajustes sincronizados.
/// Con `soloActivos=true` filtra los desactivados.
/// Con `paraMenor=true`: el tipo 'mensual' se reemplaza por 'menores'
/// (precio reducido automático). Con false se excluyen los solo_menores.
Future<List<TipoPago>> getTiposPago(
    {bool soloActivos = true, bool paraMenor = false}) async {
  final aj = await LocalDb.instance.getAjustes();
  final crudo = aj['tipos_pago'];
  List<TipoPago> tipos;
  if (crudo is List && crudo.isNotEmpty) {
    tipos = [
      for (final t in crudo)
        if (t is Map<String, dynamic>) TipoPago.desdeJson(t)
        else if (t is Map)
          TipoPago.desdeJson(Map<String, dynamic>.from(t)),
    ];
  } else {
    // Fallback: construir desde las claves fijas
    double valor(String k, double def) =>
        montoAjusteTolerante(aj[k]) ?? def;
    tipos = [
      TipoPago(
          id: 'mensual',
          nombre: 'Mensualidad',
          monto: valor('mensualidad', 2000),
          dias: 30),
      TipoPago(
          id: 'menores',
          nombre: 'Mensualidad menores',
          monto: valor('mensualidad_menores', 1500),
          dias: 30,
          soloMenores: true),
      TipoPago(
          id: 'semanal',
          nombre: 'Semana',
          monto: valor('pago_semanal', 600),
          dias: 7),
      TipoPago(
          id: 'quincenal',
          nombre: 'Quincena',
          monto: valor('pago_quincenal', 1200),
          dias: 15),
    ];
  }
  // v1.8.0 (bug de campo): el blob del servidor puede venir SIN el
  // tipo 'menores' (trae mensual/semanal/quincenal/ofertas) y el
  // fallback de arriba solo corre con el blob vacío: el menor se
  // quedaba sin opción mensual y el aviso del diálogo caía al
  // primer tipo (600, el semanal) en vez de a los 1500 de menores.
  // Si se pide para menor y la lista no trae 'menores', se
  // sintetiza desde la clave fija 'mensualidad_menores' — el mismo
  // patrón de respaldo que usa precioMenor() — colocado junto al
  // mensual. Si el blob SÍ trae 'menores', se respeta tal cual.
  // (1.36 H-A2 136-632) la síntesis también corre cuando el
  // 'menores' presente NO es activo/visible: el filtro final lo
  // descartaría y el cobro del menor caería al primer tipo de la
  // lista (p. ej. el semanal de 600) en vez de a su tarifa. Se
  // considera «visible» un menores activo, con nombre y monto.
  final hayMenoresVisible = tipos.any((t) =>
      t.id == 'menores' && t.activo && t.nombre.isNotEmpty && t.monto > 0);
  if (paraMenor && !hayMenoresVisible) {
    // El menores no visible sale: el sintético ocupa su lugar.
    tipos.removeWhere((t) => t.id == 'menores');
    // (M2-A A6) el monto sintetizado sale de la fuente única.
    final montoMenor = precioMenoresDesdeAjustes(aj);
    if (montoMenor > 0) {
      final sintetico = TipoPago(
          id: 'menores',
          nombre: 'Mensualidad menores',
          monto: montoMenor,
          dias: 30,
          soloMenores: true);
      final iMensual = tipos.indexWhere((t) => t.id == 'mensual');
      if (iMensual >= 0) {
        tipos.insert(iMensual, sintetico);
      } else {
        tipos.insert(0, sintetico);
      }
    }
  }
  return [
    for (final t in tipos)
      if (t.id.isNotEmpty &&
          t.nombre.isNotEmpty &&
          t.monto > 0 &&
          (!soloActivos || t.activo) &&
          // menores: sin 'mensual' normal (ya tienen 'menores');
          // adultos: sin tipos solo_menores
          (paraMenor ? t.id != 'mensual' : !t.soloMenores))
        t,
  ];
}

/// Precio de la mensualidad para menores (configurable, v1.0.16).
/// (M2-A A6) Antes llamaba a getTiposPago SIN paraMenor: el
/// filtro final descarta los tipos soloMenores, así que la rama
/// del tipo 'menores' era INALCANZABLE y siempre cobraba la
/// clave fija, aunque el dueño hubiera editado el tipo en el
/// blob (la fuente que sí usa el diálogo de cobro). Ahora lee
/// el tipo con paraMenor: true y cae a la fuente única.
Future<double> precioMenor() async {
  final tipos = await getTiposPago(soloActivos: false, paraMenor: true);
  for (final t in tipos) {
    if (t.id == 'menores') return t.monto;
  }
  final aj = await LocalDb.instance.getAjustes();
  return precioMenoresDesdeAjustes(aj);
}
