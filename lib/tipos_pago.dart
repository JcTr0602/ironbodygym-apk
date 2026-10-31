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
        monto: (j['monto'] as num?)?.toDouble() ?? 0,
        dias: (j['dias'] as num?)?.toInt() ?? 30,
        activo: j['activo'] != false,
        soloMenores: j['solo_menores'] == true,
      );
}

/// Tipo inicial del diálogo de pago (decisión de Jc 2026-10-25,
/// Caso 14 MIN menor/oferta).
///
/// NO es una aplicación automática del descuento: solo el valor
/// preseleccionado del desplegable, que el entrenador puede cambiar
/// antes de confirmar en la vista previa.
///
/// - Adulto: 'mensual' como siempre (o el primer tipo si no existe).
/// - Menor: la opción mensual de 30 días más barata entre 'menores'
///   y las ofertas de 30 días, comparando con [monto] (en el diálogo
///   es el precio de etiqueta, que ya incluye la especial vigente).
///   Excepción 1.19 (Argón A1): si el menor es Casa o tiene
///   especial mensual vigente ([esCasa]/[tieneEspecialMensual]),
///   NO se compara contra ofertas: la preselección es 'menores'.
///   El motor aplica Casa (0) o la especial, y una oferta
///   preseleccionada la saltaría en la práctica. El entrenador
///   sigue pudiendo elegir la oferta a mano en el desplegable.
///   Solo se comparan tipos de 30 días: una oferta semanal o de otro
///   período no es comparable con una mensualidad. En empate gana
///   'menores' sin importar el orden de la lista (1.15 M1d-01: el
///   orden del blob no está garantizado y el primer candidato
///   podía ser 'mensual' u otra oferta).
/// - Sin candidato mensual: 'menores' si existe, si no el primero.
///
/// [tiposDisp] no debe estar vacía (el diálogo ya lo garantiza);
/// si llega vacía, se lanza ArgumentError en vez del StateError
/// críptico de `.first`.
TipoPago tipoInicialPago(
  List<TipoPago> tiposDisp, {
  required bool menor,
  required double Function(TipoPago tipo) monto,
  bool esCasa = false,
  bool tieneEspecialMensual = false,
}) {
  if (tiposDisp.isEmpty) {
    throw ArgumentError('tipoInicialPago: lista de tipos vacía');
  }
  if (!menor) {
    return tiposDisp.firstWhere((t) => t.id == 'mensual',
        orElse: () => tiposDisp.first);
  }
  // 1.19 (Argón A1): Casa y especial mensual no compiten con ofertas.
  if (esCasa || tieneEspecialMensual) {
    return tiposDisp.firstWhere((t) => t.id == 'menores',
        orElse: () => tiposDisp.first);
  }
  final candidatos =
      tiposDisp.where((t) => t.dias == 30).toList();
  if (candidatos.isEmpty) {
    return tiposDisp.firstWhere((t) => t.id == 'menores',
        orElse: () => tiposDisp.first);
  }
  var mejor = candidatos.first;
  var mejorMonto = monto(mejor);
  for (final t in candidatos.skip(1)) {
    final m = monto(t);
    if (m < mejorMonto ||
        (m == mejorMonto && t.id == 'menores' && mejor.id != 'menores')) {
      mejor = t;
      mejorMonto = m;
    }
  }
  return mejor;
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
        (aj[k] as num?)?.toDouble() ?? def;
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
  if (paraMenor && !tipos.any((t) => t.id == 'menores')) {
    final montoMenor =
        (aj['mensualidad_menores'] as num?)?.toDouble() ?? 1500;
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
/// Lee del tipo 'menores' o de la clave fija; fallback 1500.
Future<double> precioMenor() async {
  final tipos = await getTiposPago(soloActivos: false);
  for (final t in tipos) {
    if (t.id == 'menores') return t.monto;
  }
  final aj = await LocalDb.instance.getAjustes();
  return (aj['mensualidad_menores'] as num?)?.toDouble() ?? 1500;
}
