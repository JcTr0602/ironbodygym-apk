/// 1.36 · Vencimientos — las cuentas (136-237 · 136-238 ·
/// 136-241 · 136-251).
///
/// - 136-237: la pastilla de Vencimientos tiene UNA fórmula
///   en la capa de datos (`conteoPastillaVencimientos`):
///   vencen hoy (todos) + atrasados sin aviso vigente.
/// - 136-241: el pausado no desaparece del padrón entre
///   pestañas en el teléfono del dueño: vive en «Al día»
///   (su vencimiento no corre) y la partición suma el padrón.
/// - 136-238: la Bandeja del día incluye la banda +30d.
/// - 136-251: el sin-fecha tiene texto propio (nunca pagó),
///   no el de vencido ni «está por vencer».
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('136-237 · conteoPastillaVencimientos (puro)', () {
    Map<String, dynamic> c(int id) => {'id': id, 'nombre': 'C$id'};
    bool visible(Map<String, dynamic> x) => x['oculto'] != true;

    test('hoy cuenta entero; atrasados solo sin avisar', () {
      final n = conteoPastillaVencimientos(
        vencenHoyLista: [c(1), c(2)],
        atrasadosLista: [c(3), c(4), c(5)],
        avisadosVigentes: {4},
        visible: visible,
      );
      expect(n, 4, reason: '2 de hoy + 3 atrasados − 1 avisado');
    });

    test('el protegido no cuenta en ninguna de las dos partes', () {
      final n = conteoPastillaVencimientos(
        vencenHoyLista: [
          {'id': 1, 'oculto': true},
        ],
        atrasadosLista: [c(2)],
        avisadosVigentes: const {},
        visible: visible,
      );
      expect(n, 1);
    });

    test('sin trabajo, cero (la pastilla no se pinta)', () {
      expect(
          conteoPastillaVencimientos(
            vencenHoyLista: const [],
            atrasadosLista: const [],
            avisadosVigentes: const {},
            visible: visible,
          ),
          0);
    });
  });

  group('136-251 · plantillas únicas', () {
    test('sin fecha: texto propio de «nunca pagó»', () {
      final msg = mensajeWaSegunEstado({'nombre': 'Ana', 'pagado_hasta': null});
      expect(msg, contains('no consta tu primer pago'));
      expect(msg, isNot(contains('está vencida')));
      expect(msg, isNot(contains('está por vencer')));
    });

    test('vencido, vence hoy y por vencer conservan su plantilla', () {
      final hoy = ahoraHabana();
      expect(
          mensajeWaSegunEstado({
            'nombre': 'Ana',
            'pagado_hasta': _iso(hoy.subtract(const Duration(days: 2))),
          }),
          contains('está vencida'));
      expect(
          mensajeWaSegunEstado({'nombre': 'Ana', 'pagado_hasta': _iso(hoy)}),
          contains('vence hoy'));
      expect(
          mensajeWaSegunEstado({
            'nombre': 'Ana',
            'pagado_hasta': _iso(hoy.add(const Duration(days: 2))),
          }),
          contains('vence el'));
    });
  });

  group('BD · 136-241 partición y 136-238 bandeja', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      // avisosWhatsappHoy consulta AuthService (Supabase):
      // instancia dummy, como el test de la insignia E3.
      try {
        await Supabase.initialize(
            url: 'http://127.0.0.1:9', publishableKey: 'dummy');
      } catch (_) {}
    });

    setUp(() async {
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    Future<void> sembrar() async {
      final hoy = ahoraHabana();
      Future<void> cli(int id, String nombre, DateTime? hasta) =>
          LocalDb.instance.upsertMirror('clientes', id, {
            'id': id,
            'nombre': nombre,
            'estado': 'activo',
            'activo': 1,
            'telefono': '5819000$id',
            if (hasta != null) 'pagado_hasta': _iso(hasta),
          }, 1);
      await cli(1, 'Al Dia Normal', hoy.add(const Duration(days: 20)));
      await cli(2, 'Pausado Vencido', hoy.subtract(const Duration(days: 5)));
      await cli(3, 'Pausado Futuro', hoy.add(const Duration(days: 10)));
      await cli(4, 'Atrasado Normal', hoy.subtract(const Duration(days: 5)));
      await cli(5, 'Atrasado Viejo', hoy.subtract(const Duration(days: 40)));
      await cli(6, 'Sin Fecha', null);
      Future<void> pausa(int fila, int clienteId) =>
          LocalDb.instance.upsertMirror('cliente_congelaciones', fila, {
            'id': 'cg-$fila',
            'cliente_id': clienteId,
            'motivo_categoria': 'viaje',
            'motivo': 'Viaje',
            'estado': 'aprobada',
            'desde': _iso(hoy.subtract(const Duration(days: 2))),
            'hasta': _iso(hoy.add(const Duration(days: 8))),
            'inicio_efectivo': _iso(hoy.subtract(const Duration(days: 2))),
            'hasta_efectivo': _iso(hoy.add(const Duration(days: 8))),
            'dias_a_extender': 10,
          }, 1);
      await pausa(1, 2);
      await pausa(2, 3);
    }

    test('136-241: el pausado vencido vive en «Al día» y la '
        'partición suma el padrón', () async {
      await sembrar();
      final activos = await clientesActivos();
      Set<int> ids(List<Map<String, dynamic>> l) =>
          {for (final c in l) (c['id'] as num).toInt()};
      final hoyL = await vencenHoy(activosPre: activos);
      final pv = await porVencer(dias: 3, activosPre: activos);
      final m30 = await atrasados(masDe30: false, activosPre: activos);
      final p30 = await atrasados(masDe30: true, activosPre: activos);
      final ad = await clientesAlDiaPestana(activosPre: activos);
      expect(ids(m30), {4, 6},
          reason: 'el pausado no es atrasado; el sin-fecha sí');
      expect(ids(p30), {5});
      expect(ids(ad), containsAll({1, 2, 3}),
          reason: 'al día normal + pausado futuro + pausado '
              'vencido rescatado a su pestaña');
      final union = {
        ...ids(hoyL),
        ...ids(pv),
        ...ids(m30),
        ...ids(p30),
        ...ids(ad),
      };
      expect(union, ids(activos),
          reason: 'partición completa: ningún activo se pierde '
              'entre pestañas');
      final suma = hoyL.length +
          pv.length +
          m30.length +
          p30.length +
          ad.length;
      expect(suma, activos.length,
          reason: 'sin duplicados entre pestañas');
    });

    test('136-238: la Bandeja incluye la banda +30d como vencido',
        () async {
      await sembrar();
      final avisos = await avisosWhatsappHoy();
      final vencidos = {
        for (final a in avisos)
          if (a['tipo'] == 'vencido') (a['cliente_id'] as num).toInt(): a,
      };
      expect(vencidos.keys, containsAll({4, 5, 6}),
          reason: 'el de 40 días (id 5) existe en la Bandeja');
      expect(vencidos[5]!['dias_atraso'], 40);
      expect(vencidos[6]!['detalle'], contains('nunca pagó'));
      expect(vencidos[6]!['mensaje'], contains('no consta tu primer pago'));
      expect(vencidos.keys, isNot(contains(2)),
          reason: 'el pausado sigue fuera de la Bandeja');
    });
  });
}
