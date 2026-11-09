/// 1.30 (§14 + §15): tests de la oleada de marcas
/// verificadas y de la retirada de la puerta «Anuncios».
///
/// §14: el modelo y el sello (puros), el servicio contra
/// su costura (las RPC `admin_marcas_cliente` /
/// `admin_verificar_marca`, con la guarda de personal en
/// el servidor) y la pantalla de la ficha: pinta cada
/// marca con su sello, verifica con un toque y pinta el
/// aval que devuelve el servidor (la primera verificación
/// manda), y sin conexión lo dice — error ≠ vacío.
///
/// §15 (decisión de Jc): la puerta «Anuncios» del Panel se
/// retiró — ni la tarjeta, ni la ruta, ni el índice del
/// buscador — y la pantalla del compositor SIGUE en el
/// árbol (solo se retiró la puerta; tabla y RPC intactas).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/marcas_cliente.dart';
import 'package:ironbody_gym/ui/ficha_marcas.dart';

Future<void> _asentar(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _filaServidor({
  required int id,
  String ejercicio = 'Sentadilla',
  double peso = 100,
  bool verificada = false,
  String? por,
  String? rol,
}) =>
    {
      'id': id,
      'ejercicio_id': 7,
      'ejercicio_nombre': ejercicio,
      'peso': peso,
      'fecha': '2026-11-05',
      'verificada': verificada,
      'verificada_por': por,
      'verificada_rol': rol,
      'verificada_en': verificada ? '2026-11-06T15:04:00+00:00' : null,
    };

void main() {
  group('§14 · modelo y sello (puro)', () {
    test('desdeRpc parsea la fila sin verificar (nace sin aval)', () {
      final m = MarcaServidor.desdeRpc(_filaServidor(id: 3));
      expect(m.id, 3);
      expect(m.ejercicioNombre, 'Sentadilla');
      expect(m.peso, 100.0);
      expect(m.fecha, '2026-11-05');
      expect(m.verificada, isFalse);
      expect(m.verificadaPor, isNull);
      expect(m.verificadaEn, isNull);
      expect(textoSelloMarca(m), 'Sin verificar');
    });

    test('el sello nombra al dueño sin mirar nombres', () {
      final m = MarcaServidor.desdeRpc(_filaServidor(
          id: 4, verificada: true, por: 'Jctr0602', rol: 'dueno'));
      expect(m.verificada, isTrue);
      expect(m.verificadaEn, isNotNull);
      expect(textoSelloMarca(m), 'Verificada por el dueño');
    });

    test('el sello nombra al entrenador que avaló', () {
      final m = MarcaServidor.desdeRpc(_filaServidor(
          id: 5, verificada: true, por: 'Gabriel', rol: 'entrenador'));
      expect(textoSelloMarca(m), 'Verificada por Gabriel');
    });

    test('sin nombre guardado, el sello cae a «un entrenador»', () {
      final m = MarcaServidor.desdeRpc(_filaServidor(
          id: 6, verificada: true, por: null, rol: 'entrenador'));
      expect(textoSelloMarca(m), 'Verificada por un entrenador');
    });

    test('el peso se lee como en la casa: entero o con coma', () {
      expect(fmtPesoKg(100), '100 kg');
      expect(fmtPesoKg(102.5), '102,5 kg');
      expect(fmtPesoKg(77.5), '77,5 kg');
    });
  });

  group('§14 · servicio (costura RPC)', () {
    test('consultar pide las marcas del cliente y las parsea', () async {
      String? rpcVisto;
      Map<String, dynamic>? paramsVistos;
      final svc = MarcasClienteService(rpcParaTest: (rpc, params) async {
        rpcVisto = rpc;
        paramsVistos = params;
        return {
          'ok': true,
          'marcas': [
            _filaServidor(id: 1),
            _filaServidor(
                id: 2,
                ejercicio: 'Peso muerto',
                peso: 180,
                verificada: true,
                por: 'Duany',
                rol: 'entrenador'),
          ],
        };
      });
      final marcas = await svc.consultar(11);
      expect(rpcVisto, 'admin_marcas_cliente');
      expect(paramsVistos, {'p_cliente_id': 11});
      expect(marcas.map((m) => m.id), [1, 2]);
      expect(marcas[1].verificada, isTrue);
    });

    test('verificar devuelve el aval resultante y si ya estaba', () async {
      final svc = MarcasClienteService(rpcParaTest: (rpc, params) async {
        expect(rpc, 'admin_verificar_marca');
        expect(params, {'p_marca_id': 9});
        return {
          'ok': true,
          'ya_verificada': true,
          'marca': _filaServidor(
              id: 9, verificada: true, por: 'Gabriel', rol: 'entrenador'),
        };
      });
      final r = await svc.verificar(9);
      expect(r.yaVerificada, isTrue);
      expect(r.marca.verificadaPor, 'Gabriel');
    });

    test('una respuesta malformada es un error, nunca un vacío',
        () async {
      final svcLista = MarcasClienteService(
          rpcParaTest: (rpc, params) async => ['no', 'es', 'un', 'mapa']);
      await expectLater(svcLista.consultar(11), throwsStateError);
      final svcSinClave = MarcasClienteService(
          rpcParaTest: (rpc, params) async => {'ok': true});
      await expectLater(svcSinClave.consultar(11), throwsStateError);
      await expectLater(svcSinClave.verificar(1), throwsStateError);
    });
  });

  group('§14 · pantalla de marcas (widget)', () {
    MarcasClienteService servicioDe(
            {required List<Map<String, dynamic>> marcas,
            Map<String, dynamic>? alVerificar}) =>
        MarcasClienteService(rpcParaTest: (rpc, params) async {
          if (rpc == 'admin_marcas_cliente') {
            return {'ok': true, 'marcas': marcas};
          }
          return {
            'ok': true,
            'ya_verificada': false,
            'marca': alVerificar,
          };
        });

    testWidgets('pinta cada marca con su sello y el botón '
        'solo en la sin verificar', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MarcasClienteScreen(
          clienteId: 11,
          nombreCliente: 'Ana Pérez',
          servicio: servicioDe(marcas: [
            _filaServidor(id: 1),
            _filaServidor(
                id: 2,
                ejercicio: 'Peso muerto',
                peso: 180,
                verificada: true,
                por: 'Jctr0602',
                rol: 'dueno'),
          ]),
        ),
      ));
      await _asentar(tester);
      expect(find.text('Sentadilla'), findsOneWidget);
      expect(find.text('100 kg'), findsOneWidget);
      expect(find.text('Sin verificar'), findsOneWidget);
      expect(find.text('Verificada por el dueño'), findsOneWidget);
      expect(find.text('Verificar'), findsOneWidget);
    });

    testWidgets('verificar pinta el aval que devuelve el servidor',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MarcasClienteScreen(
          clienteId: 11,
          nombreCliente: 'Ana Pérez',
          servicio: servicioDe(
            marcas: [_filaServidor(id: 1)],
            alVerificar: _filaServidor(
                id: 1, verificada: true, por: 'Gabriel', rol: 'entrenador'),
          ),
        ),
      ));
      await _asentar(tester);
      await tester.tap(find.text('Verificar'));
      await _asentar(tester);
      expect(find.text('Verificada por Gabriel'), findsOneWidget);
      expect(find.text('Verificar'), findsNothing);
    });

    testWidgets('si otro verificó primero, se pinta SU aval',
        (tester) async {
      final svc = MarcasClienteService(rpcParaTest: (rpc, params) async {
        if (rpc == 'admin_marcas_cliente') {
          return {
            'ok': true,
            'marcas': [_filaServidor(id: 1)],
          };
        }
        return {
          'ok': true,
          'ya_verificada': true,
          'marca': _filaServidor(
              id: 1, verificada: true, por: 'Duany', rol: 'entrenador'),
        };
      });
      await tester.pumpWidget(MaterialApp(
        home: MarcasClienteScreen(
          clienteId: 11,
          nombreCliente: 'Ana Pérez',
          servicio: svc,
        ),
      ));
      await _asentar(tester);
      await tester.tap(find.text('Verificar'));
      await _asentar(tester);
      expect(find.text('Verificada por Duany'), findsOneWidget);
      expect(find.textContaining('Ya estaba verificada por Duany'),
          findsOneWidget);
    });

    testWidgets('sin conexión lo dice y ofrece reintentar '
        '(no finge que no hay marcas)', (tester) async {
      final svc = MarcasClienteService(
          rpcParaTest: (rpc, params) async =>
              throw Exception('SocketException: sin red'));
      await tester.pumpWidget(MaterialApp(
        home: MarcasClienteScreen(
          clienteId: 11,
          nombreCliente: 'Ana Pérez',
          servicio: svc,
        ),
      ));
      await _asentar(tester);
      expect(find.textContaining('Sin conexión'), findsOneWidget);
      expect(find.text('Reintentar'), findsOneWidget);
      expect(find.text('Sin marcas registradas'), findsNothing);
    });

    testWidgets('sin marcas, el vacío es honesto', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: MarcasClienteScreen(
          clienteId: 11,
          nombreCliente: 'Ana Pérez',
          servicio: servicioDe(marcas: const []),
        ),
      ));
      await _asentar(tester);
      expect(find.text('Sin marcas registradas'), findsOneWidget);
    });
  });

  group('§15 · la puerta «Anuncios» ya no existe (fuente)', () {
    test('admin.dart no lleva ni la tarjeta ni la ruta', () {
      final admin = File('lib/ui/admin.dart').readAsStringSync();
      expect(admin.contains('Anuncio a clientes'), isFalse);
      expect(admin.contains("case 'anuncios':"), isFalse);
      expect(admin.contains('PanelAnunciosScreen'), isFalse);
    });

    test('el buscador del Panel ya no indexa «anuncios»', () {
      final buscador =
          File('lib/ui/panel_buscador.dart').readAsStringSync();
      expect(buscador.contains("id: 'anuncios'"), isFalse);
    });

    test('la pantalla del compositor SIGUE en el árbol '
        '(solo se retiró la puerta)', () {
      final pantalla =
          File('lib/ui/panel_anuncios.dart').readAsStringSync();
      expect(pantalla.contains('class PanelAnunciosScreen'), isTrue);
    });
  });
}
