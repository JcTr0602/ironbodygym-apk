/// Tipos de pago (v1.8.0, bug de campo): el blob `tipos_pago` del
/// servidor puede venir SIN el tipo 'menores' y el fallback de
/// claves fijas solo corre con el blob vacío — el menor se quedaba
/// sin opción mensual y el aviso del diálogo de pago caía al
/// primer tipo (600, el semanal) en vez de al precio de menores.
/// getTiposPago(paraMenor: true) ahora sintetiza 'menores' desde
/// la clave fija 'mensualidad_menores' cuando el blob no lo trae.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Abre una BD vacía y siembra los ajustes dados (mismo patrón
/// que borrado_conservando_test).
Future<void> _conAjustes(Map<String, dynamic> ajustes) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.setAjustes(ajustes);
}

/// El blob REAL que trae el servidor hoy: sin tipo 'menores'.
List<Map<String, dynamic>> _blobSinMenores() => [
      {'id': 'mensual', 'nombre': 'Mensualidad', 'monto': 2000, 'dias': 30},
      {'id': 'semanal', 'nombre': 'Semana', 'monto': 600, 'dias': 7},
      {'id': 'quincenal', 'nombre': 'Quincena', 'monto': 1200, 'dias': 15},
      {'id': 'oferta_50', 'nombre': 'Oferta 50%', 'monto': 1000, 'dias': 30},
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('blob sin menores: el menor SÍ tiene mensualidad (1500) y '
      'no ve la mensual normal', () async {
    await _conAjustes({
      'tipos_pago': _blobSinMenores(),
      'mensualidad_menores': 1500,
    });
    final tipos = await getTiposPago(paraMenor: true);
    final ids = [for (final t in tipos) t.id];
    expect(ids, contains('menores'),
        reason: 'sin esto el diálogo no ofrece pagar la mensualidad');
    expect(ids, isNot(contains('mensual')));
    final menores = tipos.firstWhere((t) => t.id == 'menores');
    expect(menores.monto, 1500);
    expect(menores.dias, 30);
    expect(menores.soloMenores, isTrue);
    // El resto del blob se conserva.
    expect(ids, containsAll(['semanal', 'quincenal', 'oferta_50']));
    // Posición natural: primero, donde iba el mensual.
    expect(ids.first, 'menores');
  });

  test('blob sin menores: el monto sintetizado sale de la clave '
      'mensualidad_menores si difiere', () async {
    await _conAjustes({
      'tipos_pago': _blobSinMenores(),
      'mensualidad_menores': 1800,
    });
    final tipos = await getTiposPago(paraMenor: true);
    expect(tipos.firstWhere((t) => t.id == 'menores').monto, 1800);
  });

  test('blob CON menores propio: se respeta tal cual', () async {
    await _conAjustes({
      'tipos_pago': [
        ..._blobSinMenores(),
        {
          'id': 'menores',
          'nombre': 'Mensualidad menores',
          'monto': 1300,
          'dias': 30,
          'solo_menores': true,
        },
      ],
      'mensualidad_menores': 1500,
    });
    final tipos = await getTiposPago(paraMenor: true);
    final menores = tipos.where((t) => t.id == 'menores').toList();
    expect(menores, hasLength(1), reason: 'no debe duplicarse');
    expect(menores.single.monto, 1300,
        reason: 'el monto del servidor manda sobre la clave fija');
  });

  test('adulto con el mismo blob: ve la mensual y NO ve menores',
      () async {
    await _conAjustes({
      'tipos_pago': _blobSinMenores(),
      'mensualidad_menores': 1500,
    });
    final tipos = await getTiposPago(paraMenor: false);
    final ids = [for (final t in tipos) t.id];
    expect(ids, contains('mensual'));
    expect(ids, isNot(contains('menores')));
  });
}
