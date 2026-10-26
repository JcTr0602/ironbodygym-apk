/// Tests de M1 (Fase A 2026-10-25): anular un adelanto cuyo mes
/// ya está liquidado se rechaza ANTES de encolar.
///
/// Usa BD real en memoria de test (sqflite ffi), como
/// migracion_v44_test: se siembran el espejo `adelantos` y el
/// espejo `nomina_liquidada` y se comprueba el rechazo. El caso
/// no liquidado solo se comprueba con argumentos explícitos
/// (sin depender del espejo) para no acoplar el test al push.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/adelantos.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

Future<void> _sembrarAdelanto() async {
  final d = await LocalDb.instance.db;
  await d.insert('adelantos', {
    'id': 7,
    'data': jsonEncode({
      'id': 7,
      'entrenador': 'duany',
      'mes_nomina': '2026-10',
      'monto': 1000,
      'fecha': '2026-10-20',
    }),
    'sync_seq': 1,
  });
}

Future<void> _sembrarLiquidada() async {
  final d = await LocalDb.instance.db;
  await d.insert('nomina_liquidada', {
    'id': '2026-10|duany',
    'data': jsonEncode({'mes': '2026-10', 'entrenador': 'duany'}),
    'sync_seq': 1,
  });
}

void main() {
  test('mes liquidado (vía espejo): anular rechaza sin encolar',
      () async {
    await _abrirDbVacia();
    await _sembrarAdelanto();
    await _sembrarLiquidada();
    expect(
      () => AdelantosService.instance.anular(7),
      throwsStateError,
    );
    final ops = await LocalDb.instance.pendingOps();
    expect(
        ops.where((o) => o['tipo'] == 'anular_adelanto'), isEmpty);
  });

  test('mes liquidado (vía argumentos explícitos): anular rechaza',
      () async {
    await _abrirDbVacia();
    await _sembrarLiquidada();
    expect(
      () => AdelantosService.instance
          .anular(99, entrenadorId: 'duany', mesNomina: '2026-10'),
      throwsStateError,
    );
  });

  test('mes no liquidado: anular encola (no lanza por M1)', () async {
    await _abrirDbVacia();
    await _sembrarAdelanto();
    // Sin fila en nomina_liquidada: el rechazo M1 no aplica.
    // El push posterior va en try/catch dentro del servicio; si
    // el entorno no tiene sesión, la op queda encolada igual.
    await AdelantosService.instance.anular(7);
    final ops = await LocalDb.instance.pendingOps();
    expect(
        ops.where((o) => o['tipo'] == 'anular_adelanto'), hasLength(1));
  });
}
