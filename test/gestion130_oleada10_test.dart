/// Gestión 1.30 · Oleada 10 «Ficha completa» (§13).
///
/// Contrato que se fija, pieza a pieza:
/// · FICHA-03: repetir el cobro va DIRECTO a la vista
///   previa. La selección de período/precio es UNA función
///   pura compartida por el Paso 1 interactivo y por el
///   atajo (periodoSelDeCobro): el monto lo recalcula el
///   motor de precios de HOY, nunca se copia del pago
///   viejo. El Preview del repetir ofrece «Cambiar» y
///   devuelve 'cambiar' sin encolar nada.
/// · FICHA-06: la acción extra del recibo se decide con
///   una pura: con teléfono → WhatsApp; sin teléfono pero
///   con cliente → «Agregar teléfono y enviar recibo»
///   (saltable: es un botón más del recibo, el cobro ya
///   se guardó); sin cliente → ninguna.
/// · FICHA-11: la transferencia por conciliar más
///   reciente de un cliente se resuelve con una pura
///   sobre su lista de pagos (pendiente o con problema;
///   la comprobada y la histórica no cuentan).
/// · FICHA-04: la barra compacta ofrece UNA acción del
///   momento por prioridad: conciliar (dueño) > renovar
///   (vencido) > dar acceso > cobrar; la Casa, ninguna.
/// · FICHA-09: el buscador del historial casa por texto
///   sin tildes (título, subtítulo, método, período,
///   estado de conciliación) y por monto (dígitos).
/// · FICHA-08: la sección de actividad con cliente fijo
///   no pinta selector y consulta sola a esa persona.
/// · FICHA-01: la venta de bote nace con el comprador de
///   la ficha ya puesto, y el cableado ficha → Servicios
///   queda fijado en fuente.
/// · FICHA-12: fijado en tarjeta_acciones_test.dart (la
///   tarjeta ya no trae Progreso ni Renovación).
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/actividad_cliente.dart';
import 'package:ironbody_gym/conciliacion.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/tipos_pago.dart';
import 'package:ironbody_gym/ui/actividad_cliente.dart';
import 'package:ironbody_gym/ui/dialogo_pago.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/ficha_secciones.dart';
import 'package:ironbody_gym/ui/preview_cobro.dart';
import 'package:ironbody_gym/ui/venta_suplemento.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ── Arnés común (la pauta de las oleadas 4–9) ────────

String _jwtFalso(String email, int telegramId,
    {bool admin = false}) {
  String b64(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');
  final header = b64({'alg': 'HS256', 'typ': 'JWT'});
  final payload = b64({
    'sub': '00000000-0000-0000-0000-0000000000e8',
    'aud': 'authenticated',
    'exp': 4102444800,
    'iat': 1700000000,
    'email': email,
    'role': 'authenticated',
    'app_metadata': {
      'telegram_id': telegramId,
      'provider': 'email',
      if (admin) 'rol': 'admin',
    },
  });
  return '$header.$payload.firma-de-mentira';
}

Future<void> _sesionDueno(WidgetTester tester) async {
  final sesion = jsonEncode({
    'access_token':
        _jwtFalso('jctr0602@ironbody.local', 735772141, admin: true),
    'token_type': 'bearer',
    'expires_in': 3600,
    'refresh_token': 'refresh-de-mentira',
    'user': {
      'id': '00000000-0000-0000-0000-0000000000e8',
      'aud': 'authenticated',
      'email': 'jctr0602@ironbody.local',
      'app_metadata': {
        'telegram_id': 735772141,
        'provider': 'email',
        'rol': 'admin',
      },
      'user_metadata': <String, dynamic>{},
      'created_at': '2024-01-01T00:00:00.000Z',
    },
  });
  await tester.runAsync(() async {
    await Supabase.instance.client.auth.setInitialSession(sesion);
  });
}

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfiNoIsolate;
  SharedPreferences.setMockInitialValues({});
  await LocalDb.resetParaTest();
}

Future<void> _pumps(WidgetTester tester, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

const _precios = <String, double>{
  'mensual': 2000,
  'transfer': 2500,
  'menores': 1500,
  'semanal': 600,
  'quincenal': 1200,
};

TipoPago _tipo(String id, {double monto = 0, int dias = 0}) =>
    TipoPago(id: id, nombre: id, monto: monto, dias: dias);

PeriodoSel _sel(
  String tipoId, {
  String metodo = 'efectivo',
  int meses = 1,
  String diasTexto = '',
  String montoTexto = '',
  bool esCasa = false,
  bool esMenor = false,
  List<Map<String, dynamic>> especiales = const [],
  double montoTipo = 0,
  int diasTipo = 0,
}) =>
    periodoSelDeCobro(
      tipoSel: _tipo(tipoId, monto: montoTipo, dias: diasTipo),
      metodo: metodo,
      meses: meses,
      diasTexto: diasTexto,
      montoTexto: montoTexto,
      esCasa: esCasa,
      esMenor: esMenor,
      preciosMapa: _precios,
      filasEspecial: especiales,
    );

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    try {
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    } catch (_) {}
  });

  group('FICHA-03 · periodoSelDeCobro (pura)', () {
    test('mensual efectivo: estándar 2000 de hoy', () {
      final r = _sel('mensual');
      expect(r.periodo, 'mensual');
      expect(r.monto, 2000);
      expect(r.escalon, 'estandar');
      expect(r.tipoId, 'mensual');
    });

    test('mensual por transferencia: 2500', () {
      final r = _sel('mensual', metodo: 'transferencia');
      expect(r.monto, 2500);
    });

    test('mensual x3 por transferencia: 7500', () {
      final r = _sel('mensual', metodo: 'transferencia', meses: 3);
      expect(r.monto, 7500);
    });

    test('menores: 1500 y período del motor mensual', () {
      final r = _sel('menores', esMenor: true);
      expect(r.periodo, 'mensual');
      expect(r.monto, 1500);
      expect(r.escalon, 'menores');
    });

    test('especial activa manda sobre el estándar', () {
      final r = _sel('mensual', especiales: [
        {
          'periodo': 'mensual',
          'activa': 1,
          'monto_efectivo': 1000,
          'monto_transferencia': 2000,
        },
      ]);
      expect(r.monto, 1000);
      expect(r.escalon, 'especial');
    });

    test('especial inactiva no aplica', () {
      final r = _sel('mensual', especiales: [
        {
          'periodo': 'mensual',
          'activa': 0,
          'monto_efectivo': 1000,
          'monto_transferencia': 2000,
        },
      ]);
      expect(r.monto, 2000);
      expect(r.escalon, 'estandar');
    });

    test('semanal: 600 con su período', () {
      final r = _sel('semanal');
      expect(r.periodo, 'semanal');
      expect(r.monto, 600);
    });

    test('Casa: 0 con escalón casa', () {
      final r = _sel('mensual', esCasa: true);
      expect(r.monto, 0);
      expect(r.escalon, 'casa');
    });

    test('tipo personalizado de Jc: su monto y sus días', () {
      final r = _sel('oferta50', montoTipo: 1000, diasTipo: 30);
      expect(r.periodo, 'personalizado');
      expect(r.dias, 30);
      expect(r.monto, 1000);
      expect(r.escalon, 'oferta');
      expect(r.tipoId, 'oferta50');
    });

    test('personalizado manual: días y monto escritos', () {
      final r =
          _sel('personalizado', diasTexto: '45', montoTexto: '3000');
      expect(r.periodo, 'personalizado');
      expect(r.dias, 45);
      expect(r.monto, 3000);
      expect(r.tipoId, isNull);
    });
  });

  group('FICHA-03 · especialParaPeriodo (pura)', () {
    test('devuelve la activa del período y solo esa', () {
      final filas = <Map<String, dynamic>>[
        {'periodo': 'semanal', 'activa': 1, 'monto_efectivo': 300},
        {'periodo': 'mensual', 'activa': 0, 'monto_efectivo': 900},
        {'periodo': 'mensual', 'activa': 1, 'monto_efectivo': 1000},
      ];
      expect(especialParaPeriodo(filas, 'mensual')?['monto_efectivo'],
          1000);
      expect(especialParaPeriodo(filas, 'quincenal'), isNull);
    });
  });

  group('FICHA-11 · ultimaTransferenciaPorConciliar (pura)', () {
    Map<String, dynamic> pago(String metodo, [String? conc]) => {
          'metodo': metodo,
          if (conc != null) 'conciliacion': conc,
        };

    test('sin pagos: null', () {
      expect(ultimaTransferenciaPorConciliar(const []), isNull);
    });

    test('la pendiente más reciente gana a la comprobada', () {
      final pendiente = pago('transferencia', 'pendiente');
      final r = ultimaTransferenciaPorConciliar(
          [pago('transferencia', 'comprobada'), pendiente]);
      expect(identical(r, pendiente), isTrue);
    });

    test('con problema también es por conciliar', () {
      final problema = pago('transferencia', 'problema');
      expect(
          identical(
              ultimaTransferenciaPorConciliar([problema]), problema),
          isTrue);
    });

    test('transferencia sin estado crudo es histórica: no sale',
        () {
      expect(
          ultimaTransferenciaPorConciliar([pago('transferencia')]),
          isNull);
    });

    test('el efectivo nunca es por conciliar', () {
      expect(ultimaTransferenciaPorConciliar([pago('efectivo')]),
          isNull);
    });

    test('entre dos por conciliar manda la primera (la reciente)',
        () {
      final reciente = pago('transferencia', 'pendiente');
      final vieja = pago('transferencia', 'problema');
      expect(
          identical(
              ultimaTransferenciaPorConciliar([reciente, vieja]),
              reciente),
          isTrue);
    });
  });

  group('FICHA-04 · accionDelMomentoFicha (pura)', () {
    String accion({
      bool esCasa = false,
      bool vencido = false,
      bool transf = false,
      bool dueno = false,
      bool sinAcceso = false,
    }) =>
        accionDelMomentoFicha(
          esCasa: esCasa,
          vencido: vencido,
          hayTransferenciaPorConciliar: transf,
          esDueno: dueno,
          sinAcceso: sinAcceso,
        );

    test('la Casa no cobra: ninguna, pase lo que pase', () {
      expect(
          accion(esCasa: true, vencido: true, transf: true, dueno: true),
          'ninguna');
    });

    test('dueño con transferencia por conciliar: conciliar, '
        'aunque esté vencido', () {
      expect(accion(transf: true, dueno: true, vencido: true),
          'conciliar');
    });

    test('entrenador con transferencia por conciliar: no '
        'concilia (no es su botón); si está vencido, renovar', () {
      expect(accion(transf: true, vencido: true), 'renovar');
    });

    test('vencido sin acceso: renovar manda sobre acceso', () {
      expect(accion(vencido: true, sinAcceso: true), 'renovar');
    });

    test('al día sin acceso: dar acceso', () {
      expect(accion(sinAcceso: true), 'acceso');
    });

    test('al día con acceso: cobrar, el gesto de siempre', () {
      expect(accion(), 'cobrar');
      expect(accion(dueno: true), 'cobrar');
    });
  });

  group('FICHA-06 · modoAccionExtraReciboCobro (pura)', () {
    test('con teléfono: WhatsApp directo', () {
      expect(
          modoAccionExtraReciboCobro(
              telefonoWa: '58191577', clienteId: 5),
          'whatsapp');
    });

    test('sin teléfono pero con cliente: agregar teléfono', () {
      expect(
          modoAccionExtraReciboCobro(telefonoWa: null, clienteId: 5),
          'agregar_telefono');
      expect(
          modoAccionExtraReciboCobro(telefonoWa: '', clienteId: 5),
          'agregar_telefono');
    });

    test('sin cliente no hay a quién agregarle el teléfono', () {
      expect(
          modoAccionExtraReciboCobro(telefonoWa: null, clienteId: null),
          'ninguna');
      expect(
          modoAccionExtraReciboCobro(telefonoWa: null, clienteId: 0),
          'ninguna');
    });
  });

  group('FICHA-09 · búsqueda del historial (puras)', () {
    final pagoTransf = <String, dynamic>{
      'tipo': 'pago',
      'titulo': 'Pago de mensualidad',
      'subtitulo': 'Transferencia',
      'trailing': '+2 500 CUP',
      'pago': {
        'metodo': 'transferencia',
        'monto': 2500,
        'periodo': 'mensual',
        'conciliacion': 'pendiente',
      },
    };
    final venta = <String, dynamic>{
      'tipo': 'venta',
      'titulo': 'Dosis de proteína',
      'subtitulo': 'Pomo de Gabriel',
      'trailing': '600 CUP',
      'montoVenta': 600,
    };

    test('normalizarBusquedaFicha pliega tildes y ñ', () {
      expect(normalizarBusquedaFicha('Pérez Ñandú'),
          'perez nandu');
    });

    test('consulta vacía coincide con todo', () {
      expect(entradaCoincideBusquedaHistorial(pagoTransf, '  '),
          isTrue);
    });

    test('por estado de conciliación: «por comprobar»', () {
      expect(
          entradaCoincideBusquedaHistorial(pagoTransf, 'por comprobar'),
          isTrue);
      expect(entradaCoincideBusquedaHistorial(venta, 'por comprobar'),
          isFalse);
    });

    test('por método y por monto con dígitos', () {
      expect(
          entradaCoincideBusquedaHistorial(pagoTransf, 'transferencia'),
          isTrue);
      expect(entradaCoincideBusquedaHistorial(pagoTransf, '2500'),
          isTrue);
      expect(entradaCoincideBusquedaHistorial(pagoTransf, '9999'),
          isFalse);
    });

    test('texto y monto a la vez: ambos deben casar', () {
      expect(
          entradaCoincideBusquedaHistorial(
              pagoTransf, 'mensualidad 2500'),
          isTrue);
      expect(
          entradaCoincideBusquedaHistorial(
              pagoTransf, 'mensualidad 9999'),
          isFalse);
    });

    test('sin tildes encuentra el texto con tildes', () {
      expect(entradaCoincideBusquedaHistorial(venta, 'proteina'),
          isTrue);
      expect(entradaCoincideBusquedaHistorial(venta, 'dosis 600'),
          isTrue);
    });
  });

  group('FICHA-03 · el Preview del repetir (widget)', () {
    Widget app({required bool permiteCambiar}) => MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () async {
                    final r = await Navigator.of(ctx).push<String>(
                      MaterialPageRoute(
                        builder: (_) => PreviewCobroScreen(
                          nombreCliente: 'Ana Pérez',
                          montoTexto: '2 500 CUP',
                          metodoTexto: 'Transferencia',
                          periodoTexto: 'Mensual',
                          nuevoVencimientoTexto: '08/12/2026',
                          fechaTexto: '08/11/2026',
                          avisos: const [],
                          permiteCambiar: permiteCambiar,
                        ),
                      ),
                    );
                    ultimoResultadoPreview = r;
                  },
                  child: const Text('abrir'),
                ),
              ),
            ),
          ),
        );

    testWidgets('con permiteCambiar se ve «Cambiar» y al '
        'tocarlo el preview devuelve cambiar', (tester) async {
      ultimoResultadoPreview = null;
      await tester.pumpWidget(app(permiteCambiar: true));
      await tester.tap(find.text('abrir'));
      await _pumps(tester);
      expect(find.text('Cambiar período o método'), findsOneWidget);
      await tester.tap(find.text('Cambiar período o método'));
      await _pumps(tester);
      expect(ultimoResultadoPreview, 'cambiar');
    });

    testWidgets('sin permiteCambiar no hay botón Cambiar',
        (tester) async {
      await tester.pumpWidget(app(permiteCambiar: false));
      await tester.tap(find.text('abrir'));
      await _pumps(tester);
      expect(find.text('Cambiar período o método'), findsNothing);
      expect(find.text('Confirmar cobro'), findsOneWidget);
    });
  });

  group('FICHA-09 · el buscador de la tarjeta (widget)', () {
    testWidgets('escribir filtra las entradas y limpiar '
        'las devuelve', (tester) async {
      final entradas = <Map<String, dynamic>>[
        {
          'tipo': 'pago',
          'titulo': 'Pago de mensualidad',
          'subtitulo': 'Transferencia',
          'trailing': '+2 500 CUP',
          'color': Colors.green,
          'icono': Icons.payments_rounded,
          'pago': {
            'metodo': 'transferencia',
            'monto': 2500,
            'periodo': 'mensual',
            'conciliacion': 'pendiente',
          },
        },
        {
          'tipo': 'venta',
          'titulo': 'Dosis de proteína',
          'subtitulo': 'Pomo de Gabriel',
          'trailing': '600 CUP',
          'color': Colors.orange,
          'icono': Icons.bolt_rounded,
          'montoVenta': 600,
        },
      ];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TarjetaHistorialFicha(
              entradas: entradas,
              filtro: 'todo',
              onFiltro: (_) {},
              serviciosHist: const [],
              clienteId: 11,
              esAdmin: false,
              esOwner: false,
              onReenviarRecibo: (_) {},
              onVerComprobante: (_) {},
              onCorregirPago: (_) {},
              onConciliar: (_) {},
            ),
          ),
        ),
      ));
      await _pumps(tester);
      expect(find.text('Pago de mensualidad'), findsOneWidget);
      expect(find.text('Dosis de proteína'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '2500');
      await _pumps(tester);
      expect(find.text('Pago de mensualidad'), findsOneWidget);
      expect(find.text('Dosis de proteína'), findsNothing);
      expect(find.text('1 resultado para «2500»'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await _pumps(tester);
      expect(find.text('Sin resultados para «zzz»'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '');
      await _pumps(tester);
      expect(find.text('Pago de mensualidad'), findsOneWidget);
      expect(find.text('Dosis de proteína'), findsOneWidget);
    });
  });

  group('FICHA-08 · actividad con cliente fijo (widget)', () {
    testWidgets('sin selector: consulta sola a esa persona '
        'y pinta sus filas', (tester) async {
      int? consultado;
      final svc = ActividadClienteService(rpcParaTest: (p) async {
        consultado = p.clienteId;
        return [
          ActividadCliente(
            fuente: 'auditoria',
            idOrigen: 5,
            actor: null,
            accion: 'auto_activacion',
            detalle: const {},
            creadoEn: DateTime.utc(2026, 11, 7, 15),
          ),
        ];
      });
      await tester.runAsync(() async {
        await _bdVacia();
        final db = await LocalDb.instance.db;
        await db.insert('clientes', {
          'id': 11,
          'data': jsonEncode({'nombre': 'Ana Pérez'}),
          'sync_seq': 1,
        });
      });
      await _sesionDueno(tester);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeccionActividadAppClientes(
              servicio: svc,
              clienteIdFijo: 11,
            ),
          ),
        ),
      ));
      await _pumps(tester, 20);
      expect(find.byType(DropdownButtonFormField<int>), findsNothing,
          reason: 'desde la ficha la persona ya viene elegida');
      expect(consultado, 11);
      expect(find.text('Activación de la app'), findsOneWidget);
    });
  });

  group('FICHA-01 · vender desde la ficha', () {
    testWidgets('la venta de bote nace con el comprador '
        'de la ficha ya puesto', (tester) async {
      // Viewport alto: la lista del formulario es perezosa
      // y el selector del comprador va abajo; así se
      // construye entero sin pelear con los scrollables.
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        await _bdVacia();
      });
      await tester.pumpWidget(const MaterialApp(
        home: VentaSuplementoScreen(
          suplemento: {
            'nombre': 'Proteína X',
            'precio_oficial': 5000,
            'moneda': 'CUP',
            'stock': 4,
          },
          clienteIdInicial: 11,
          clienteNombreInicial: 'Ana Pérez',
        ),
      ));
      await _pumps(tester);
      expect(find.text('Cliente: Ana Pérez — toca para cambiar'),
          findsOneWidget);
    });

    test('el cableado ficha → ventas queda en fuente', () {
      final ficha =
          File('lib/ui/ficha.dart').readAsStringSync();
      expect(ficha.contains("texto: 'Vender'"), isTrue);
      expect(ficha.contains('clientePreseleccionado: c'), isTrue);
      expect(ficha.contains('clienteIdInicial:'), isTrue);
      final servicios =
          File('lib/ui/servicios.dart').readAsStringSync();
      expect(servicios.contains('cliente = widget.clienteInicial'),
          isTrue);
      final ventaSup =
          File('lib/ui/venta_suplemento.dart').readAsStringSync();
      expect(ventaSup.contains('_clienteId = widget.clienteIdInicial'),
          isTrue);
    });

    test('FICHA-06 en fuente: el recibo pide el teléfono '
        'con el diálogo compartido', () {
      final preview =
          File('lib/ui/preview_cobro.dart').readAsStringSync();
      expect(preview.contains('dialogoAgregarTelefono'), isTrue);
      expect(preview.contains('Agregar teléfono y enviar recibo'),
          isTrue);
    });
  });
}

/// Resultado del último Preview abierto en los tests de
/// FICHA-03 (la ruta lo devuelve por Navigator.pop).
String? ultimoResultadoPreview;
