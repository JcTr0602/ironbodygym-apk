/// 1.32 · Pieza 7 (familia TELÉFONO EFECTIVO, parche atómico):
/// todos los caminos de WhatsApp resuelven el número con la
/// regla única FB-01 (`telefonoEfectivoWa`: movil primero,
/// validado). Aquí se fija el sitio ejecutable de la familia
/// (avisosWhatsappHoy/telDe, H-CAMPO-1) con el fixture del
/// Y-CAMPO G1 — el migrado 703: carnet en `telefono`, número
/// en `movil` — que antes salía como «Sin teléfono», y la
/// delegación de telefonoPreferido (S-2). Los demás sitios
/// (cumpleanos D-1, venta D-4, plantillas D-5, historial D-6)
/// consumen la misma función fijada.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/actividad.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  for (final sufijo in ['', '-wal', '-shm']) {
    try {
      await File('$dbPath$sufijo').delete();
    } catch (_) {}
  }
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('Familia teléfono efectivo', () {
    test('H-CAMPO-1: el migrado solo-movil SÍ tiene teléfono '
        'en la bandeja (el efectivo, no el carnet)', () async {
      await _abrirDbVacia();
      final hoy = hoyHabanaIso();
      // 702: control con teléfono clásico, vence hoy.
      await LocalDb.instance.upsertMirror('clientes', 702, {
        'id': 702,
        'nombre': 'Con Telefono',
        'telefono': '58191577',
        'estado': 'activo',
        'pagado_hasta': hoy,
      }, 2);
      // 703: migrado — el celular vive en `movil`; `telefono`
      // trae el carnet (escenario FB-01 de la 1.29). Vence hoy.
      await LocalDb.instance.upsertMirror('clientes', 703, {
        'id': 703,
        'nombre': 'Migrado Movil',
        'telefono': '20510010345',
        'movil': '58191579',
        'estado': 'activo',
        'pagado_hasta': hoy,
      }, 3);
      // 704: telefono viejo válido pero el bueno en movil:
      // manda el movil.
      await LocalDb.instance.upsertMirror('clientes', 704, {
        'id': 704,
        'nombre': 'Numero Viejo',
        'telefono': '52111111',
        'movil': '58191580',
        'estado': 'activo',
        'pagado_hasta': hoy,
      }, 4);

      final avisos = await avisosWhatsappHoy();
      Map<String, dynamic> de(int id) => avisos.firstWhere(
          (a) => a['cliente_id'] == id && a['tipo'] == 'vence_hoy',
          orElse: () => <String, dynamic>{});

      expect(de(702)['telefono'], '5358191577');
      expect(de(703)['telefono'], '5358191579',
          reason: 'el aviso del migrado lleva su movil con el '
              '53, no el carnet: la bandeja lo clasifica '
              'enviable, no «Sin teléfono»');
      expect(de(704)['telefono'], '5358191580',
          reason: 'movil manda sobre el telefono viejo');
      // La clasificación de la bandeja (normalizar el campo)
      // deja a los tres enviables.
      for (final id in [702, 703, 704]) {
        expect(
            normalizarTelefonoWaMe('${de(id)['telefono'] ?? ''}'),
            isNotEmpty);
      }
    });

    test('S-2: telefonoPreferido valida — la basura en movil '
        'no tapa el telefono bueno', () {
      expect(
          telefonoPreferido(
              {'movil': 'no-es-numero', 'telefono': '58123456'}),
          '5358123456');
      expect(
          telefonoPreferido(
              {'movil': '50998877', 'telefono': '58123456'}),
          '5350998877');
      expect(telefonoPreferido({'telefono': '20510010345'}), '',
          reason: 'el carnet solo no es un teléfono enviable');
    });
  });
}
