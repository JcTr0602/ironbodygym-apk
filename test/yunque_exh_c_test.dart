/// Yunque Exhaustivo 1.35 — Carril C (búsqueda, rol y cumpleaños).
///
/// C-1 (ALTA): en el Directorio, un entrenador encontraba a un
/// cliente PROTEGIDO buscando por su teléfono (la vía telefónica
/// de buscarClientes casaba la columna FTS `telefonos` sin filtro
/// de protegidos, y la vía por nombre era la puerta trasera en
/// consultas numéricas). C-4 (MEDIA): la búsqueda por carnet
/// prometida no existía; ahora hay vía por carnet EXACTO tras la
/// de teléfono. C-2 (MEDIA): los recientes de la Lupa no aplicaban
/// la puerta de rol y CongeladosScreen no se autoprotegía. C-5
/// (MEDIA): los cumpleaños derivaban solo del carnet e ignoraban
/// la fecha que trae la fila (fecha_nacimiento / fecha_nac).
///
/// Siembra por el camino real del pull (upsertMirror, que
/// mantiene clientes_fts), como yunque_campo_g4_buscador_test.
/// Rol: sin sesión = entrenador (AuthService().isOwner == false,
/// como protegido2_test); la sesión del dueño se fija a mitad de
/// archivo con setInitialSession (patrón de
/// campo15_dueno_no_se_liquida_test) y los tests del dueño van
/// DESPUÉS: el orden de declaración es parte del arnés.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/auth.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/congelados.dart';
import 'package:ironbody_gym/ui/lupa_universal.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

String _sesionDueno() {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e6',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': 'jc@ironbody.local',
    'role': 'authenticated',
    'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
  });
  final jwt = '$header.$payload.firma';
  return jsonEncode({
    'access_token': jwt,
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-x',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e6',
      'aud': 'authenticated',
      'email': 'jc@ironbody.local',
      'app_metadata': {'telegram_id': 735772141, 'provider': 'email'},
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
}

Future<void> _sembrar() async {
  final db = LocalDb.instance;
  await db.upsertMirror('clientes', 1, {
    'id': 1,
    'nombre': 'Ana Protegida',
    'estado': 'activo',
    'carnet': '90010112345',
    'telefono': '55112233',
    'protegido': 1,
    'pagado_hasta': '2027-01-01',
  }, 101);
  await db.upsertMirror('clientes', 2, {
    'id': 2,
    'nombre': 'Luis Normal',
    'estado': 'activo',
    'carnet': '88020254321',
    'telefono': '55443322',
    'protegido': 0,
    'pagado_hasta': '2027-01-01',
  }, 102);
  await db.upsertMirror('clientes', 3, {
    'id': 3,
    'nombre': 'Carlos Congelado',
    'estado': 'congelado',
    'carnet': '85030399999',
    'telefono': '55998877',
    'protegido': 0,
    'pagado_hasta': '2027-01-01',
  }, 103);
}

List<int> _ids(List<Map<String, dynamic>> r) =>
    [for (final c in r) (c['id'] as num).toInt()];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  LocalDb.nombreArchivoDbForzado = 'test_yunque_exh_c.db';

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  setUp(() async {
    final dir = await getDatabasesPath();
    for (final suf in ['', '-wal', '-shm']) {
      try {
        await File(p.join(dir, 'test_yunque_exh_c.db$suf')).delete();
      } catch (_) {}
    }
    await LocalDb.resetParaTest();
    await LocalDb.instance.db;
    await _sembrar();
  });

  group('C-1/C-4 · buscarClientes como ENTRENADOR (sin sesión)', () {
    test('la sesión del arnés no es la del dueño', () {
      expect(AuthService().isOwner, isFalse);
    });

    test('C-1: por el teléfono del protegido NO aparece', () async {
      final r = await buscarClientes('55112233');
      expect(_ids(r), isNot(contains(1)),
          reason: 'la vía telefónica filtra protegidos (C-1)');
    });

    test('C-1 puerta trasera: la consulta numérica tampoco lo '
        'devuelve por la vía de nombre', () async {
      // El teléfono completo solo puede casar por la columna
      // `telefonos` del FTS: si la vía telefónica lo filtra pero
      // la de nombre no, el MATCH sin columna lo resucita.
      final r = await buscarClientes('55112233');
      expect(r, isEmpty,
          reason: 'ninguna vía devuelve al protegido por dígitos');
    });

    test('C-1: por el teléfono del cliente normal SÍ aparece',
        () async {
      final r = await buscarClientes('55443322');
      expect(_ids(r), contains(2));
    });

    test('C-1: por nombre el protegido sigue apareciendo '
        '(diseño del Directorio, sin cambios)', () async {
      final r = await buscarClientes('Ana Protegida');
      expect(_ids(r), contains(1));
    });

    test('C-4: por el carnet exacto del normal SÍ aparece',
        () async {
      final r = await buscarClientes('88020254321');
      expect(_ids(r), contains(2),
          reason: 'la vía por carnet exacto encuentra al cliente');
    });

    test('C-4: por los 6 dígitos de nacimiento NO aparece '
        '(nada de prefijos de carnet)', () async {
      final r = await buscarClientes('880202');
      expect(_ids(r), isNot(contains(2)),
          reason: '880202 es la fecha de nacimiento de medio '
              'padrón: casar por prefijo devolvería a todos');
    });

    test('C-4: por el carnet del protegido NO aparece para el '
        'entrenador', () async {
      final r = await buscarClientes('90010112345');
      expect(_ids(r), isNot(contains(1)),
          reason: 'el carnet es invisible para su rol: misma '
              'puerta que el teléfono');
    });
  });

  group('C-2 · puerta de rol de la Lupa y de Congelados', () {
    test('recientes de funciones: sin dueño, ninguno se ofrece',
        () {
      final r = recientesFuncionesLupa(
          ['congeladas', 'arqueo', 'cliente:2'],
          esDueno: false);
      expect(r, isEmpty,
          reason: 'el reciente guardado por la sesión del dueño '
              'no se ofrece a la del entrenador');
    });

    test('recientes de funciones: con dueño, salen en orden y '
        'sin los de cliente', () {
      final r = recientesFuncionesLupa(
          ['congeladas', 'cliente:2', 'arqueo'],
          esDueno: true);
      expect(r.map((f) => f.id).toList(), ['congeladas', 'arqueo']);
    });

    test('los destinos solo-dueño del resolvedor son los de la '
        'corrección', () {
      expect(destinoLupaEsSoloDueno('congeladas'), isTrue);
      expect(destinoLupaEsSoloDueno('congelaciones'), isTrue);
      expect(destinoLupaEsSoloDueno('usuarios'), isTrue);
      expect(destinoLupaEsSoloDueno('cumpleanos'), isFalse);
    });

    testWidgets('CongeladosScreen como no-dueño: no lista datos',
        (tester) async {
      tester.view.physicalSize = const Size(420, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: CongeladosScreen()));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
          find.text('La lista de membresías congeladas solo la '
              've el dueño.'),
          findsOneWidget);
      expect(find.text('Carlos Congelado'), findsNothing,
          reason: 'ni el nombre ni el pagado_hasta del congelado '
              'se pintan para un no-dueño');
    });
  });

  group('C-5 · fecha de nacimiento de la fila', () {
    test('fechaNacDeFila: precedencia fecha_nacimiento → '
        'fecha_nac → carnet', () {
      expect(
          fechaNacDeFila({
            'fecha_nacimiento': '1990-05-10',
            'fecha_nac': '1991-06-11',
            'carnet': '92070712345',
          }),
          DateTime(1990, 5, 10));
      expect(
          fechaNacDeFila({
            'fecha_nac': '1991-06-11',
            'carnet': '92070712345',
          }),
          DateTime(1991, 6, 11));
      expect(fechaNacDeFila({'carnet': '92070712345'}),
          DateTime(1992, 7, 7));
    });

    test('fechaNacDeFila: fecha imposible no tapa al carnet '
        '(parseo estricto)', () {
      expect(
          fechaNacDeFila({
            'fecha_nacimiento': '1990-02-31',
            'carnet': '92070712345',
          }),
          DateTime(1992, 7, 7),
          reason: 'el 31 de febrero no existe: cae a la '
              'siguiente fuente');
      expect(fechaNacDeFila({'fecha_nacimiento': '10/05/1990'}),
          isNull,
          reason: 'sin formato ISO con año no hay fecha '
              'utilizable para _cumple');
    });

    test('cumpleanosProximos: fila con fecha_nacimiento y carnet '
        'inválido entra, con _cumple correcto', () async {
      final hoy = ahoraHabana();
      final destino = hoy.add(const Duration(days: 3));
      final mm = destino.month.toString().padLeft(2, '0');
      final dd = destino.day.toString().padLeft(2, '0');
      final res = await cumpleanosProximos(activosPre: [
        {
          'id': 9,
          'nombre': 'Fecha Servidor',
          'estado': 'activo',
          'carnet': '999999', // mes 99: carnet sin fecha válida
          'fecha_nacimiento': '1990-$mm-$dd',
        },
      ]);
      expect(_ids(res), contains(9),
          reason: 'antes de C-5 esta fila nunca salía: el '
              'carnet no deriva fecha y la de la fila se '
              'ignoraba');
      final fila = res.firstWhere((c) => c['id'] == 9);
      expect(fila['_dias_para'], 3);
      expect(fila['_cumple'], destino.year - 1990,
          reason: '_cumple sale del año de la fecha de la fila');
    });

    test('cumpleanosProximos: fila con solo carnet se comporta '
        'como antes', () async {
      final hoy = ahoraHabana();
      final destino = hoy.add(const Duration(days: 3));
      final mm = destino.month.toString().padLeft(2, '0');
      final dd = destino.day.toString().padLeft(2, '0');
      final res = await cumpleanosProximos(activosPre: [
        {
          'id': 10,
          'nombre': 'Solo Carnet',
          'estado': 'activo',
          // Nacido en 1990: el carnet lleva '90' + MMDD.
          'carnet': '90$mm${dd}12345',
        },
        {
          'id': 11,
          'nombre': 'Lejano',
          'estado': 'activo',
          // Cumple dentro de ~6 meses: fuera de la ventana.
          'carnet': '90010112345',
          'fecha_nacimiento':
              '1990-${hoy.month == 1 ? '07' : '01'}-15',
        },
      ]);
      expect(_ids(res), contains(10));
      expect(_ids(res), isNot(contains(11)));
      final fila = res.firstWhere((c) => c['id'] == 10);
      expect(fila['_cumple'], destino.year - 1990);
    });
  });

  group('C-1/C-4 · buscarClientes como DUEÑO', () {
    setUpAll(() async {
      await Supabase.instance.client.auth
          .setInitialSession(_sesionDueno());
    });

    test('la sesión del arnés es la del dueño', () {
      expect(AuthService().isOwner, isTrue);
    });

    test('C-1: por el teléfono del protegido SÍ aparece para el '
        'dueño', () async {
      final r = await buscarClientes('55112233');
      expect(_ids(r), contains(1),
          reason: 'esVistaProtegida es false para el dueño: su '
              'búsqueda no cambia');
    });

    test('C-4: por el carnet del protegido SÍ aparece para el '
        'dueño', () async {
      final r = await buscarClientes('90010112345');
      expect(_ids(r), contains(1));
    });
  });
}
