/// 1.23 (B3 Paso 3, delta del panel): leerBonosMesConMigracion
/// es el camino ÚNICO de lectura de bonos del mes (pantalla de
/// Nómina y Panel del dueño). Antes el panel leía con
/// leerBonos a secas y, con un bono legado aún en prefs, su
/// neto salía SIN ese bono mientras la pantalla de Nómina —
/// que sí migraba al abrir — lo incorporaba: dos cifras
/// distintas para el mismo mes.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/nomina_foto.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

String get _pref {
  final a = ahoraHabana();
  return '${a.year}-${a.month.toString().padLeft(2, '0')}';
}

String get _claveLista {
  final a = ahoraHabana();
  return 'nomina_bonos_${a.year}_${a.month}';
}

String get _claveSimple {
  final a = ahoraHabana();
  return 'nomina_bono_${a.year}_${a.month}';
}

Future<void> _abrirDbVacia(Map<String, Object> prefs) async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues(prefs);
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  test('lista legada en prefs: el camino compartido la migra, '
      'la devuelve y limpia las prefs', () async {
    final legados = [
      {'entrenador': 'gabriel', 'monto': 500.0, 'nota': 'extra'},
      {'entrenador': 'duany', 'monto': 0.0, 'nota': 'cero'},
    ];
    await _abrirDbVacia({_claveLista: jsonEncode(legados)});
    final bonos = await leerBonosMesConMigracion(_pref);
    // El bono de monto 0 se ignora al migrar (regla 1.14).
    expect(bonos.length, 1);
    expect(bonos.single['entrenador'], 'gabriel');
    expect(bonos.single['monto'], 500);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(_claveLista), isNull);
    expect((await LocalDb.instance.pendingOps()).length, 1);
    // Segunda lectura (el otro consumidor): no re-migra ni
    // duplica; devuelve lo mismo.
    final bonos2 = await leerBonosMesConMigracion(_pref);
    expect(bonos2.length, 1);
    expect((await LocalDb.instance.pendingOps()).length, 1);
  });

  test('bono simple legado (double) se convierte en «ambos»',
      () async {
    await _abrirDbVacia({_claveSimple: 300.0});
    final bonos = await leerBonosMesConMigracion(_pref);
    expect(bonos.length, 1);
    expect(bonos.single['entrenador'], 'ambos');
    expect(bonos.single['monto'], 300);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(_claveSimple), isNull);
  });

  test('sin legado: devuelve vacío y no encola nada', () async {
    await _abrirDbVacia({});
    final bonos = await leerBonosMesConMigracion(_pref);
    expect(bonos, isEmpty);
    expect((await LocalDb.instance.pendingOps()).length, 0);
  });
}
