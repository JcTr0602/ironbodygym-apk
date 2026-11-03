/// 1.23 (B3 Paso 3a, diseño de Argón): la configuración de
/// precios y datos bancarios del Panel del dueño, fuera de
/// admin.dart.
///
/// - Las claves y etiquetas viven aquí como ÚNICA definición
///   (la pantalla de ajustes las recibe de esta lista).
/// - El parseo/validación son funciones PURAS sobre los
///   controladores y el mapa de ajustes vigente: se prueban
///   sin widgets y sin BD.
/// - La aplicación persiste como antes: ops `ajuste` encoladas
///   + espejo local de ajustes, en UNA transacción para los
///   montos (auditoría 1.22 D2-01: nunca un subconjunto de
///   precios sincronizado con el espejo viejo).
library;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../localdb.dart';

/// Claves de ajustes que son MONTOS (con su etiqueta visible).
const clavesMontoConfig = <(String, String)>[
  ('transferencia', 'Mensualidad por transferencia'),
  ('pago_diario', 'Pago diario'),
  // v1.2.1: precio de menores configurable (antes 1500 fijo).
  ('mensualidad_menores', 'Mensualidad menores'),
  // v1.2.1: tasa USD del día para mostrar precios en suplementos.
  ('tasa_usd', 'Tasa USD (CUP por 1 USD)'),
  // v1.7.0 (G2): precio del App Plus (30 días). Default 1000;
  // al guardar se republica a info_publica (lo hace el llamador).
  ('precio_app_plus', 'Precio App Plus (30 días)'),
];

/// Etiqueta visible de una clave de monto (la clave misma si
/// no está en la lista).
String etiquetaMonto(String clave) {
  for (final (c, e) in clavesMontoConfig) {
    if (c == clave) return e;
  }
  return clave;
}

/// Claves de ajustes que son datos BANCARIOS (texto validado).
const clavesBancariasConfig = <String>[
  'tarjeta_bandec',
  'tarjeta_bpa',
  'movil_confirmacion',
  'titular',
];

/// Parsea los controladores de montos: solo entran valores
/// numéricos finitos y > 0 (autoauditoría 1.22 #2, clase N-2:
/// Infinity SÍ es > 0 y se colaba como precio del gym).
Map<String, double> parsearCambiosMontos(
    Map<String, TextEditingController> montos) {
  final cambios = <String, double>{};
  for (final (clave, _) in clavesMontoConfig) {
    final v = double.tryParse(
        (montos[clave]?.text ?? '').replaceAll(',', '.'));
    if (v != null && v.isFinite && v > 0) cambios[clave] = v;
  }
  return cambios;
}

/// Valida los datos bancarios contra los ajustes vigentes
/// (v1.2.4, Hark): solo se envía lo que CAMBIÓ y no está vacío
/// (vaciar un dato lo decide el servidor; la app no lo manda).
/// Las tarjetas se normalizan en grupos de 4; el móvil queda
/// en dígitos; el titular va tal cual (máx. 80 caracteres).
({Map<String, String> cambios, List<String> errores})
    validarCambiosBancarios(
  Map<String, TextEditingController> bancarios,
  Map<String, dynamic> ajustes,
) {
  final cambios = <String, String>{};
  final errores = <String>[];
  for (final clave in clavesBancariasConfig) {
    final v = (bancarios[clave]?.text ?? '').trim();
    if (v.isEmpty) continue;
    // v0.6.0: el titular es un nombre, no un número.
    if (clave == 'titular') {
      if (v.length > 80) {
        errores.add('Titular: máx. 80 caracteres');
        continue;
      }
      if (v != '${ajustes[clave] ?? ''}'.trim()) cambios[clave] = v;
      continue;
    }
    final digitos = v.replaceAll(RegExp(r'[\s-]'), '');
    if (clave.startsWith('tarjeta') &&
        !RegExp(r'^\d{16}$').hasMatch(digitos)) {
      errores.add(
          '${clave == 'tarjeta_bandec' ? 'BANDEC' : 'BPA'}: 16 dígitos');
      continue;
    }
    if (clave == 'movil_confirmacion' &&
        !RegExp(r'^[56]\d{7}$').hasMatch(digitos)) {
      errores.add('Móvil: 8 dígitos, empieza por 5 o 6');
      continue;
    }
    final normal = clave.startsWith('tarjeta') && digitos.length == 16
        ? [for (var i = 0; i < 16; i += 4) digitos.substring(i, i + 4)]
            .join(' ')
        : digitos;
    if (normal != '${ajustes[clave] ?? ''}'.trim()) {
      cambios[clave] = normal;
    }
  }
  return (cambios: cambios, errores: errores);
}

/// Persiste los montos: ops `ajuste` + espejo local en UNA
/// transacción (auditoría 1.22 D2-01). No incluye la
/// republicación del precio App Plus ni el push: los dispara
/// el llamador tras guardar.
Future<void> aplicarCambiosMontos(Map<String, double> cambios) async {
  final aj = await LocalDb.instance.getAjustes();
  for (final e in cambios.entries) {
    aj[e.key] = e.value;
  }
  final conn = await LocalDb.instance.db;
  await conn.transaction((txn) async {
    for (final e in cambios.entries) {
      await LocalDb.instance.queueOp(
        opUuid: const Uuid().v4(),
        tipo: 'ajuste',
        payload: {'clave': e.key, 'valor': e.value},
        txn: txn,
      );
    }
    await LocalDb.instance.setAjustes(aj, executor: txn);
  });
}

/// Persiste los datos bancarios: una op `ajuste` por clave
/// cambiada + espejo local (mismo orden que el guardado
/// histórico de admin.dart).
Future<void> aplicarCambiosBancarios(
    Map<String, String> cambios, Map<String, dynamic> ajustes) async {
  for (final e in cambios.entries) {
    await LocalDb.instance.queueOp(
      opUuid: const Uuid().v4(),
      tipo: 'ajuste',
      payload: {'clave': e.key, 'valor': e.value},
    );
  }
  for (final e in cambios.entries) {
    ajustes[e.key] = e.value;
  }
  await LocalDb.instance.setAjustes(ajustes);
}
