/// 1.23 Bloque 6 — W2 (cierre de mes guiado) y W7 (invitado
/// frecuente, ruta 1: registro local de visitas).
///
/// W2:
/// - prefMesAnterior cruza el año correctamente.
/// - La evaluación en vivo: con la BD vacía, el paso de sync
///   se verifica (cola en 0) y los pasos de datos quedan SIN
///   verificar con su motivo (sin personas no hay cierre
///   «verde» regalado).
/// - Las confirmaciones manuales persisten por mes y no
///   contaminan otro mes; marcar cerrado deja constancia.
///
/// W7:
/// - La identidad normalizada prioriza carnet, luego teléfono
///   (sin prefijo 53) y por último el nombre normalizado.
/// - El registro y el conteo viven en la ventana de 30 días;
///   los candidatos respetan el umbral editable.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/cierre_mes.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/visitas_invitados.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  setUp(() async {
    await LocalDb.resetParaTest();
  });

  group('W2 cierre de mes', () {
    test('prefMesAnterior cruza el año', () {
      expect(prefMesAnterior(DateTime(2026, 1, 15)), '2025-12');
      expect(prefMesAnterior(DateTime(2026, 11, 4)), '2026-10');
    });

    test('evaluación en vacío: sync ok, datos sin verificar', () async {
      final e = await evaluarCierreMes('2026-10');
      PasoCierreMes paso(String id) =>
          e.pasos.firstWhere((p) => p.id == id);
      expect(paso('sync').verificado, isTrue,
          reason: 'cola vacía y sin teléfonos atrasados');
      expect(paso('nomina').verificado, isFalse);
      expect(paso('liquidaciones').verificado, isFalse,
          reason: 'sin entrenadores en la foto no se regala');
      expect(paso('liquidaciones').detalle, contains('Sin datos'));
      expect(paso('arqueo').verificado, isFalse);
      expect(paso('entrega').verificado, isFalse);
      expect(paso('respaldo').verificado, isFalse);
      expect(e.listo, isFalse);
      expect(e.cerradoEn, isNull);
    });

    test('confirmaciones manuales persisten por mes', () async {
      await confirmarPasoCierreMes('2026-10', 'nomina');
      await confirmarPasoCierreMes('2026-10', 'respaldo');
      final e = await evaluarCierreMes('2026-10');
      expect(e.pasos.firstWhere((p) => p.id == 'nomina').verificado,
          isTrue);
      expect(e.pasos.firstWhere((p) => p.id == 'respaldo').verificado,
          isTrue);
      // Otro mes no hereda las confirmaciones.
      final otro = await evaluarCierreMes('2026-09');
      expect(otro.pasos.firstWhere((p) => p.id == 'nomina').verificado,
          isFalse);
    });

    test('delta panel: marcarMesCerrado RECHAZA si no está '
        'listo y no escribe constancia', () async {
      await confirmarPasoCierreMes('2026-10', 'nomina');
      await confirmarPasoCierreMes('2026-10', 'respaldo');
      // BD vacía: liquidaciones/arqueo/entrega sin verificar.
      expect(await marcarMesCerrado('2026-10'), isFalse);
      final e = await evaluarCierreMes('2026-10');
      expect(e.cerradoEn, isNull);
    });

    Future<void> sembrarUsuarios({required bool conTelegram}) async {
      await LocalDb.instance.setMeta(
          'usuarios_apk',
          jsonEncode([
            {
              'id': 'duany',
              'username': 'duany',
              'nombre': 'Duany',
              if (conTelegram) 'telegram_id': 111,
            },
            {
              'id': 'gabriel',
              'username': 'gabriel',
              'nombre': 'Gabriel',
              if (conTelegram) 'telegram_id': 222,
            },
          ]));
    }

    Future<void> sembrarLiquidada(String ent) async {
      final d = await LocalDb.instance.db;
      await d.insert('nomina_liquidada', {
        'id': '2026-10|$ent',
        'data': jsonEncode({'mes': '2026-10', 'entrenador': ent}),
        'sync_seq': 1,
      });
    }

    test('delta panel: sin telegramId NO hay verde en arqueo '
        'ni entrega', () async {
      await sembrarUsuarios(conTelegram: false);
      final e = await evaluarCierreMes('2026-10');
      final arqueo = e.pasos.firstWhere((p) => p.id == 'arqueo');
      final entrega = e.pasos.firstWhere((p) => p.id == 'entrega');
      expect(arqueo.verificado, isFalse);
      expect(arqueo.detalle, contains('No se puede verificar'));
      expect(entrega.verificado, isFalse);
      expect(entrega.detalle, contains('No se puede verificar'));
    });

    test('con todo verificado, el cierre SÍ se marca', () async {
      await sembrarUsuarios(conTelegram: true);
      await sembrarLiquidada('duany');
      await sembrarLiquidada('gabriel');
      await confirmarPasoCierreMes('2026-10', 'nomina');
      await confirmarPasoCierreMes('2026-10', 'respaldo');
      final e = await evaluarCierreMes('2026-10');
      expect(e.listo, isTrue,
          reason: 'sync ok, manuales ok, liquidadas ok y '
              'saldos en cero: ${e.pasos.map((p) => '${p.id}=${p.verificado}').join(' ')}');
      expect(await marcarMesCerrado('2026-10'), isTrue);
      final cerrado = await evaluarCierreMes('2026-10');
      expect(cerrado.cerradoEn, isNotNull);
    });

    test('delta panel: teléfono EN TURNO sin ninguna sync '
        'bloquea el Paso 0', () async {
      final h = ahoraHabana();
      String dos(int n) => n.toString().padLeft(2, '0');
      final hoy = '${h.year}-${dos(h.month)}-${dos(h.day)}';
      final d = await LocalDb.instance.db;
      await d.insert('turnos', {
        'turno_id': 't-w2-test',
        'fecha_turno': hoy,
        'turno': 'tarde',
        'hora_apertura': isoHabana(h),
        'telegram_id': 999,
        'estado': 'abierto_local',
      });
      final e = await evaluarCierreMes('2026-10');
      final sync = e.pasos.firstWhere((p) => p.id == 'sync');
      expect(sync.verificado, isFalse,
          reason: 'en turno y sin registro no es «al día»');
      expect(sync.detalle, contains('sin ninguna sincronización'));
    });
  });

  group('W7 identidad y visitas', () {
    test('clave de identidad: carnet > teléfono > nombre', () {
      expect(
          claveIdentidadInvitado(
              carnet: '95010112345',
              telefono: '58191577',
              nombre: 'Juan Pérez'),
          'ci:95010112345');
      expect(
          claveIdentidadInvitado(
              telefono: '+53 5819 1577', nombre: 'Juan Pérez'),
          'tel:58191577');
      expect(claveIdentidadInvitado(nombre: '  Juan   PÉREZ '),
          'nom:juan perez');
      expect(claveIdentidadInvitado(), '');
      expect(claveIdentidadInvitado(telefono: '123'), '',
          reason: 'teléfono inservible y sin nombre: sin clave');
    });

    test('registro, ventana de 30 días y candidatos', () async {
      const clave = 'ci:95010112345';
      // Una visita vieja (fuera de la ventana) no cuenta.
      await LocalDb.instance.registrarVisitaInvitado(
        clave: clave,
        invitadoId: 7,
        nombre: 'Ana Vieja',
        tsIso: ahoraUtcReal()
            .subtract(const Duration(days: 40))
            .toIso8601String(),
      );
      expect(await conteoVisitasInvitado(clave), 0);
      for (var i = 0; i < 3; i++) {
        await registrarVisitaInvitadoAhora(
            clave: clave, invitadoId: 7, nombre: 'Ana');
      }
      expect(await conteoVisitasInvitado(clave), 3);
      // Con el umbral por defecto (8) aún no es candidata.
      expect(await candidatosInvitados(), isEmpty);
      // Al bajar el umbral a 3, aparece con su ficha enlazada.
      await fijarUmbralVisitasInvitado(3);
      final c = await candidatosInvitados();
      expect(c.length, 1);
      expect(c.first['clave'], clave);
      expect(c.first['visitas'], 3);
      expect(c.first['invitado_id'], 7);
      expect(c.first['nombre'], 'Ana');
    });

    test('el umbral se sanea a 2..30', () async {
      await fijarUmbralVisitasInvitado(99);
      expect(await umbralVisitasInvitado(), 30);
      await fijarUmbralVisitasInvitado(1);
      expect(await umbralVisitasInvitado(), 2);
    });

    test('delta panel: la identidad que se fortalece NO parte '
        'el conteo (teléfono → carnet, misma ficha)', () async {
      // 3 visitas registradas solo con teléfono.
      for (var i = 0; i < 3; i++) {
        await registrarVisitaInvitadoAhora(
            clave: 'tel:58191577', invitadoId: 9, nombre: 'Luis');
      }
      // Aparece el carnet: la siguiente visita reasigna las
      // previas de la ficha a la clave fuerte.
      final n = await registrarVisitaInvitadoAhora(
          clave: 'ci:95010112345', invitadoId: 9, nombre: 'Luis');
      expect(n, 4);
      expect(await conteoVisitasInvitado('tel:58191577'), 0);
      expect(await conteoVisitasInvitado('ci:95010112345'), 4);
    });

    test('delta panel: nombre e invitado_id del candidato '
        'salen de DENTRO de la ventana', () async {
      const clave = 'tel:51112233';
      // Fila vieja con ficha y nombre antiguos.
      await LocalDb.instance.registrarVisitaInvitado(
        clave: clave,
        invitadoId: 42,
        nombre: 'Nombre Viejo',
        tsIso: ahoraUtcReal()
            .subtract(const Duration(days: 40))
            .toIso8601String(),
      );
      // Dos recientes sin ficha y con el nombre vigente.
      for (var i = 0; i < 2; i++) {
        await LocalDb.instance.registrarVisitaInvitado(
          clave: clave,
          invitadoId: null,
          nombre: 'Nombre Nuevo',
          tsIso: ahoraUtcReal().toIso8601String(),
        );
      }
      await fijarUmbralVisitasInvitado(2);
      final c = await candidatosInvitados();
      expect(c.length, 1);
      expect(c.first['nombre'], 'Nombre Nuevo');
      expect(c.first['invitado_id'], isNull,
          reason: 'la ficha vieja no se hereda fuera de ventana');
    });
  });
}
