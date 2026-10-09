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
