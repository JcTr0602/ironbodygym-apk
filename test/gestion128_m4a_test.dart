/// Gestión 1.28 — Oleada M4-A (Bloque A del estudio M4:
/// Clientes, ficha y acceso) + ÍTEM FIJO «ficha perezosa».
///
/// - Ítem fijo: CacheSeccionesFicha conserva la IDENTIDAD
///   del widget por (clave, versión) — un setState de
///   pantalla no reconstruye las secciones intactas — y la
///   ficha monta ListView.builder: las secciones fuera de
///   pantalla NO se construyen hasta hacer scroll.
/// - A1: las visitas de invitados con id UUID (texto) se
///   registran, se cuentan y se reasignan de clave (antes
///   el conteo moría contra un int.tryParse).
/// - A2/A3/A9: fmtFecha y diasRestantes no se rompen con
///   datos sucios; nombreVisibleCliente rescata el nombre
///   de la fila rescatada por id.
/// - A4: auditoría de turnos — el turno real de domingo
///   (sin ventana) cuenta; el cierre que corresponde a la
///   apertura manda; duración con suelo 0; dinero con
///   montos y flags como texto.
/// - A6: AccesoCliente.intentarDesdeJson tolera el id
///   como texto y descarta la fila inservible sin tumbar
///   la carga entera.
/// - A10: la Cuenta a la Casa no vence en la vista previa.
/// - A11: InvitadoResumen/MedidaInvitado toleran filas con
///   números como texto; partirLote no ofrece cortesía a
///   quien ya tiene Plus activo.
/// - A12: validarMedicion conoce cadera_cm.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/auditoria_persona.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/mediciones_cliente.dart';
import 'package:ironbody_gym/negocio.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/ficha.dart';
import 'package:ironbody_gym/ui/invitados.dart' as ui_inv;
import 'package:ironbody_gym/ui/vista_previa_cliente.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<void> _bdVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  try {
    await File(p.join(dir, 'ironbody.db')).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  await LocalDb.instance.db;
}

void main() {
  group('Ítem fijo — CacheSeccionesFicha', () {
    test('misma clave y versión: gana la instancia cacheada',
        () {
      final cache = CacheSeccionesFicha();
      final a = SizedBox(key: const ValueKey('a'));
      final b = SizedBox(key: const ValueKey('b'));
      expect(identical(cache.obtener('pagos', 3, a), a), isTrue);
      expect(identical(cache.obtener('pagos', 3, b), a), isTrue,
          reason: 'con la versión intacta el framework recibe '
              'la instancia cacheada y ni visita la sección');
    });

    test('versión nueva adopta el candidato solo en esa '
        'clave', () {
      final cache = CacheSeccionesFicha();
      final p1 = SizedBox(key: const ValueKey('p1'));
      final p2 = SizedBox(key: const ValueKey('p2'));
      final n1 = SizedBox(key: const ValueKey('n1'));
      final n2 = SizedBox(key: const ValueKey('n2'));
      cache.obtener('pagos', 1, p1);
      cache.obtener('notas', 1, n1);
      expect(identical(cache.obtener('pagos', 2, p2), p2), isTrue);
      expect(identical(cache.obtener('notas', 1, n2), n1), isTrue,
          reason: 'la otra sección conserva su instancia');
    });

    test('limpiar vacía la caché entera', () {
      final cache = CacheSeccionesFicha();
      final a = SizedBox(key: const ValueKey('a'));
      final b = SizedBox(key: const ValueKey('b'));
      cache.obtener('fotos', 1, a);
      cache.limpiar();
      expect(identical(cache.obtener('fotos', 1, b), b), isTrue);
    });
  });

  group('A1 — visitas de invitados con id UUID', () {
    setUp(() async => _bdVacia());

    test('registrar y contar con id de texto (UUID)', () async {
      const uuid = '7f3a1c2e-1111-4222-8333-444455556666';
      await LocalDb.instance.registrarVisitaInvitado(
        clave: 'tel:58112233',
        invitadoId: uuid,
        nombre: 'Invitado Uuid',
        tsIso: '2026-11-07T09:00:00.000-04:00',
      );
      expect(
          await LocalDb.instance
              .conteoVisitasPorInvitado(uuid, '2026-01-01'),
          1);
      final visitas = await LocalDb.instance
          .visitasDeInvitado('tel:58112233', '2026-01-01');
      expect(visitas, hasLength(1));
    });

    test('reasignarClaveVisitas mueve las visitas del UUID',
        () async {
      const uuid = 'aaaaaaaa-0000-4000-8000-000000000001';
      await LocalDb.instance.registrarVisitaInvitado(
        clave: 'tel:52998877',
        invitadoId: uuid,
        nombre: 'Invitado Uuid',
        tsIso: '2026-11-07T09:00:00.000-04:00',
      );
      await LocalDb.instance.reasignarClaveVisitas(uuid, 'ci:010203');
      expect(
          await LocalDb.instance
              .visitasDeInvitado('tel:52998877', '2026-01-01'),
          isEmpty);
      expect(
          await LocalDb.instance
              .visitasDeInvitado('ci:010203', '2026-01-01'),
          hasLength(1));
    });
  });

  group('A2/A3/A9 — fechas y nombres con datos sucios', () {
    test('fechaIsoEstricta acepta solo fechas reales', () {
      expect(fechaIsoEstricta('2026-11-07'), isNotNull);
      expect(fechaIsoEstricta('2026-02-30'), isNull,
          reason: 'el 30 de febrero no existe');
      expect(fechaIsoEstricta('07/11/2026'), isNull);
      expect(fechaIsoEstricta(''), isNull);
      expect(fechaIsoEstricta(null), isNull);
      expect(fechaIsoEstricta('2026-13-01'), isNull,
          reason: 'el mes 13 no se normaliza a enero');
    });

    test('fmtFecha no revienta ni inventa con basura', () {
      expect(fmtFecha('2026-11-07'), '07/11/2026');
      expect(fmtFecha('2026-02-30'), '—');
      expect(fmtFecha('basura'), '—');
      expect(fmtFecha(null), '—');
    });

    test('diasRestantes con fecha imposible devuelve null', () {
      expect(diasRestantes('2026-02-30'), isNull);
      expect(diasRestantes('no-es-fecha'), isNull);
      expect(diasRestantes(null), isNull);
    });

    test('sumarDiasCalendario cruza meses conservando la '
        'hora de pared', () {
      final r = sumarDiasCalendario(DateTime(2026, 1, 31, 10, 30), 1);
      expect((r.year, r.month, r.day, r.hour, r.minute),
          (2026, 2, 1, 10, 30));
      final r2 = sumarDiasCalendario(DateTime(2026, 3, 8, 23, 15), -1);
      expect((r2.year, r2.month, r2.day, r2.hour), (2026, 3, 7, 23));
    });

    test('nombreVisibleCliente nunca pinta «null»', () {
      expect(nombreVisibleCliente({'nombre': '  Ana  '}), 'Ana');
      expect(nombreVisibleCliente({'nombre': 'null'}), 'Sin nombre');
      expect(nombreVisibleCliente({'nombre': ''}), 'Sin nombre');
      expect(nombreVisibleCliente({}), 'Sin nombre');
    });
  });

  group('A4 — auditoría de turnos y dinero tolerante', () {
    const persona = PersonaApk(
      id: 'uuid-entrenador',
      telegramId: 111,
      nombre: 'Entrenador Uno',
    );

    test('el turno real de domingo (sin ventana) cuenta como '
        'trabajado y usa SU cierre', () {
      final out = auditarTurnosPersona(
        persona: persona,
        desde: DateTime(2026, 11, 1),
        hasta: DateTime(2026, 11, 1),
        patron: const {},
        excepciones: const {},
        aperturas: [
          {
            'turno_id': 't-10',
            'fecha_turno': '2026-11-01',
            'turno': 'Mañana',
            'hora_apertura': '2026-11-01T08:05:00',
            'entrenador_id': 'uuid-entrenador',
          },
        ],
        cierres: [
          {
            'fecha': '2026-11-01',
            'turno': 'Mañana',
            'cerrado_en': '2026-11-01T09:00:00',
            'turno_id': 't-99',
            'entrenador_id': 'uuid-entrenador',
          },
          {
            'fecha': '2026-11-01',
            'turno': 'Mañana',
            'cerrado_en': '2026-11-01T12:30:00',
            'turno_id': 't-10',
            'entrenador_id': 'uuid-entrenador',
          },
        ],
        usuarios: const [persona],
      );
      expect(out, hasLength(1));
      final t = out.single;
      expect(t.aperturaEn, isNotNull);
      expect(t.cubrioFueraDePlan, isTrue);
      expect(t.tardanzaMin, isNull,
          reason: 'sin ventana no hay tardanza que medir');
      expect(t.duracionMin, 265,
          reason: 'el cierre con turno_id t-10 (12:30), no el '
              'primero de la lista (09:00, de otro turno)');
    });

    test('duración con suelo en cero (cierre antes que '
        'apertura por relojes cruzados)', () {
      final out = auditarTurnosPersona(
        persona: persona,
        desde: DateTime(2026, 11, 2),
        hasta: DateTime(2026, 11, 2),
        patron: const {},
        excepciones: const {},
        aperturas: [
          {
            'turno_id': 't-11',
            'fecha_turno': '2026-11-02',
            'turno': 'Mañana',
            'hora_apertura': '2026-11-02T07:00:00',
            'entrenador_id': 'uuid-entrenador',
          },
        ],
        cierres: [
          {
            'fecha': '2026-11-02',
            'turno': 'Mañana',
            'cerrado_en': '2026-11-02T06:30:00',
            'turno_id': 't-11',
            'entrenador_id': 'uuid-entrenador',
          },
        ],
        usuarios: const [persona],
      );
      expect(out.single.duracionMin, 0);
    });

    test('dinero: monto y entregado como texto cuentan', () {
      final d = auditarDineroPersona(
        persona: persona,
        desdeIso: '2026-11-01',
        hastaIso: '2026-11-30',
        pagos: [
          {
            'fecha': '2026-11-05',
            'monto': '2000',
            'metodo': 'efectivo',
            'entregado': '1',
            'entrenador_id': 'uuid-entrenador',
          },
          {
            'fecha': '2026-11-06',
            'monto': 2000,
            'metodo': 'efectivo',
            'entregado': 0,
            'entrenador_id': 'uuid-entrenador',
          },
        ],
        pagosDiarios: const [],
        ventasSuplementos: const [],
        ventasServicios: const [],
        cierres: const [],
      );
      expect(d.pagosMes, 2);
      expect(d.mensualEfectivo, 4000);
      expect(d.entregadoConfirmado, 2000,
          reason: "el flag '1' como texto también confirma");
      expect(d.pendienteGenerado, 2000);
    });
  });

  group('A6 — AccesoCliente tolerante', () {
    test('el id como texto se lee bien', () {
      final a = AccesoCliente.intentarDesdeJson({
        'cliente_id': '45',
        'nombre': 'Ana',
        'activo': true,
      });
      expect(a, isNotNull);
      expect(a!.clienteId, 45);
      expect(a.activo, isTrue);
    });

    test('fila inservible se descarta sin tumbar la carga', () {
      expect(
          AccesoCliente.intentarDesdeJson({'cliente_id': 'abc'}),
          isNull);
      expect(AccesoCliente.intentarDesdeJson({'nombre': 'sin id'}),
          isNull);
      expect(AccesoCliente.intentarDesdeJson({'cliente_id': -3}),
          isNull);
      expect(AccesoCliente.intentarDesdeJson({'cliente_id': 0}),
          isNull);
    });
  });

  group('A10 — vista previa de la Casa', () {
    test('la Cuenta a la Casa no vence ni queda «sin fecha»',
        () {
      final s = semaforoVistaPrevia(null, '2026-11-07', esCasa: true);
      expect(s.titulo, 'CUENTA A LA CASA');
      final s2 =
          semaforoVistaPrevia('2020-01-01', '2026-11-07', esCasa: true);
      expect(s2.titulo, 'CUENTA A LA CASA');
    });
  });

  group('A11 — invitados tolerantes y partirLote', () {
    test('InvitadoResumen con números como texto no revienta',
        () {
      final r = InvitadoResumen.fromJson({
        'id': 'uuid-1',
        'nombre': 'Invitado',
        'telefono': '58112233',
        'dias_restantes': '5',
        'plus_dias_restantes': '9',
      });
      expect(r.diasRestantes, 5);
      expect(r.plusDiasRestantes, 9);
    });

    test('MedidaInvitado con valores como texto no revienta',
        () {
      final m = MedidaInvitado.fromJson({
        'id': 'm1',
        'fecha': '2026-11-01',
        'peso_kg': '80.5',
      });
      expect(m.pesoKg, 80.5);
    });

    test('partirLote: cortesía no pisa un Plus activo', () {
      const conPlus = InvitadoResumen(
        id: 'a',
        nombre: 'Con Plus',
        telefono: '',
        estado: 'activo',
        plusActivo: true,
      );
      const sinPlus = InvitadoResumen(
        id: 'b',
        nombre: 'Sin Plus',
        telefono: '',
        estado: 'activo',
      );
      final parte =
          ui_inv.partirLote([conPlus, sinPlus], 'plus_cortesia');
      expect(parte.aplicables.map((i) => i.id), ['b']);
      expect(parte.excluidos, hasLength(1));
      expect(parte.excluidos.single.$1.id, 'a');
      expect(parte.excluidos.single.$2, 'ya tiene Plus activo');
    });
  });

  group('A12 — mediciones', () {
    test('validarMedicion conoce cadera_cm y su rango', () {
      expect(validarMedicion({'cadera_cm': 95}), isNull);
      expect(validarMedicion({'cadera_cm': 400}), isNotNull);
      expect(validarMedicion({'peso_kg': 80}), isNull);
    });
  });

  group('Ítem fijo — ficha perezosa (widget)', () {
    setUpAll(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      await Supabase.initialize(
          url: 'http://127.0.0.1:9', anonKey: 'dummy');
    });

    setUp(() async {
      // Zona real (fuera del cuerpo de testWidgets): la BD
      // se prepara sin la zona de tiempo falso.
      final dir = await getDatabasesPath();
      try {
        await File(p.join(dir, 'ironbody.db')).delete();
      } catch (_) {}
      await LocalDb.resetParaTest();
      await LocalDb.instance.db;
    });

    testWidgets(
        'las secciones fuera de pantalla no se construyen '
        'hasta hacer scroll', (tester) async {
      await tester.runAsync(() async {
        await LocalDb.instance.upsertMirror('clientes', 77, {
          'id': 77,
          'nombre': 'Cliente Perezoso',
          'telefono': '58112233',
          'sexo': 'M',
          // Yunque 3.34 (K4-6): fuera 'fecha_nacimiento' —
          // la fila no la trae; el nacimiento se deriva del
          // carnet (lib/negocio.dart:4058). Inerte aquí:
          // las aserciones son de construcción perezosa.
          'pagado_hasta': '2027-01-01',
          'estado': 'activo',
        }, 1);
      });
      tester.view.physicalSize = const Size(500, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
          const MaterialApp(home: FichaScreen(clienteId: 77)));
      await tester.pump(const Duration(milliseconds: 100));
      // El _cargar local es una cadena de ~12 lecturas de BD
      // lanzadas desde la zona de tiempo falso: cada futuro
      // solo completa cuando el bucle real corre (runAsync)
      // y cada continuación necesita su propia ventana. Se
      // drena alternando runAsync y pump hasta que la ficha
      // pinta el cliente (medido: los futuros de sqflite_ffi
      // no completan solo con pumps).
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
        });
        await tester.pump(const Duration(milliseconds: 60));
        if (find.text('Cliente Perezoso').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('Cliente Perezoso'), findsWidgets);
      expect(find.text('Historial'), findsNothing,
          reason: 'la sección de pagos está fuera de pantalla: '
              'con ListView.builder aún no se construye');
      // Al hacer scroll, las secciones se construyen bajo
      // demanda. Campo 2 · B-1 (2026-11-14): la jerarquía
      // nueva de la pestaña pone Membresía/Historial arriba e
      // «Información personal» abajo, y las secciones fuera
      // de la ventana de caché se descartan al seguir
      // bajando: scrollUntilVisible perdía la sección entre
      // pasos (construida y descartada) y moría en «No
      // element». Se arrastra a mano de 250 en 250 hasta que
      // la sección EXISTE en el árbol — que es lo que este
      // test afirma: construcción perezosa, no visibilidad.
      Future<void> arrastrarHasta(String texto, double paso) async {
        for (var i = 0; i < 40; i++) {
          if (find.text(texto).evaluate().isNotEmpty) return;
          await tester.drag(
              find.byType(Scrollable).first, Offset(0, paso));
          await tester.pump(const Duration(milliseconds: 60));
        }
      }

      await arrastrarHasta('Información personal', -250);
      await tester.pump();
      expect(find.text('Información personal'), findsOneWidget);
      // «Historial» quedó ARRIBA en la jerarquía nueva: al
      // bajar hasta «Información personal» salió de la
      // ventana y se descartó; se reconstruye al subir.
      await arrastrarHasta('Historial', 250);
      await tester.pump();
      expect(find.text('Historial'), findsOneWidget);
      // Drenaje final: (1) la sección «Acceso App» se
      // construyó al pasar el scroll y su carga deja una RPC
      // contra el Supabase dummy con temporizador de timeout
      // — se le dan ventanas de bucle real para que falle y
      // se cierre; (2) las FadeEntrada de las secciones
      // recién montadas dejan Future.delayed escalonados
      // (35 ms por índice). Sin este drenaje, el invariante
      // de fin de test cobra los temporizadores pendientes.
      for (var i = 0; i < 4; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(
              const Duration(milliseconds: 250));
        });
        await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(const Duration(seconds: 12));
    });
  });
}
