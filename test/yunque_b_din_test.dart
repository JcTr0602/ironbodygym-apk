/// Yunque B · YB-DIN-01 (Gestión 1.31): la inscripción de
/// una Cuenta a la Casa NO se valora como cobro en la cola.
/// Su payload real (el de inscribir.dart) no trae dinero —
/// ni periodo, ni monto, ni método, ni cliente_id: solo
/// `cuenta_casa: 1` — y las dos valoraciones caían en los
/// defaults: pendiente a entregar y «cobrado hoy» fantasma
/// de 2000 CUP hasta que la op sincronizaba.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

/// El payload Casa REAL de lib/ui/inscribir.dart (sin dinero).
Map<String, dynamic> _opCasa() => {
      'tipo': 'inscribir',
      'payload': jsonEncode({
        'nombre': 'Familiar Casa',
        'sexo': 'M',
        'telefono': '58190001',
        'carnet': '90010112345',
        'fecha': '2026-11-09',
        'cuenta_casa': 1,
      }),
    };

/// Una inscripción normal encolada (sin marca Casa y sin
/// monto: cae a la tarifa, como las ops viejas).
Map<String, dynamic> _opNormal() => {
      'tipo': 'inscribir',
      'payload': jsonEncode({
        'nombre': 'Cliente Normal',
        'sexo': 'F',
        'telefono': '58190002',
        'carnet': '95020254321',
        'fecha': '2026-11-09',
      }),
    };

void main() {
  test('YB-DIN-01: la Casa vale 0 en efectivo a entregar y en cobrado',
      () async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    await _abrirDbVacia();
    const pr = <String, double>{
      'mensual': 2000,
      'menores': 1500,
      'transfer': 2500,
      'diario': 200,
      'semanal': 600,
      'quincenal': 1200,
    };

    // La Casa: ni pendiente a entregar ni cobrado.
    expect(montoEfectivoOp(_opCasa(), pr), 0);
    expect(await montoCobradoCupOp(_opCasa()), 0);

    // Control: la inscripción normal sigue valorando la
    // tarifa (el corte es solo de la Casa).
    expect(montoEfectivoOp(_opNormal(), pr), 2000);
    expect(await montoCobradoCupOp(_opNormal()), 2000);
  });
}
