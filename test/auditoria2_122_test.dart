/// Autoauditoría 1.22 #2 (2026-11-03) — Gestión en general:
/// sync (fotos/turnos), offline-first (RPC de lectura sin
/// timeout) y dinero (clase N-2 fuera de nómina).
///
///  S1  fotos_cola: la resolución de ids distingue «la lectura
///      FALLÓ» (ok:false → diferir SIN quemar intentos) de «el
///      servidor respondió y aún no hay id» (ok:true → quema
///      según el contrato #8-1). Antes el ok se descartaba y un
///      fallo de red sostenido mandaba la foto a 'error' con el
///      motivo falso «ID de entidad nunca resuelto».
///  S2  fotos_cola.contarPendientesReclamables: el corte por
///      proximo_intento_en se compara contra el INSTANTE REAL,
///      no contra la hora de pared Habana reinterpretada en la
///      zona del teléfono (doctrina AA2 H-1).
///  S3  turno_service: sin op_uuid resuelto NO se marca el flag
///      irreversible turno_id_reconciliado (guarda de fuente: la
///      función exige sesión Supabase y no tiene seam de test).
///  O1  PlusReportesService: las lecturas cortan a los 12 s
///      (fakeAsync con RPC inyectada que nunca responde).
///  O2  Guarda de fuente: cada RPC/SELECT de LECTURA corregida
///      en pantallas y servicios lleva .timeout( (las pantallas
///      no tienen seam de inyección; la guarda impide que el
///      sitio vuelva a quedar sin tope en un refactor).
library;

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/fotos_cola.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/plus_reportes.dart';
import 'package:ironbody_gym/tiempo.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

File? _buscarArchivo(String relativo) {
  var dir = Directory.current;
  while (true) {
    final f = File(p.join(dir.path, relativo));
    if (f.existsSync()) return f;
    final padre = dir.parent;
    if (padre.path == dir.path) return null;
    dir = padre;
  }
}

String _fuente(String relativo) {
  final f = _buscarArchivo(relativo);
  expect(f, isNotNull, reason: 'no se encontró $relativo');
  return f!.readAsStringSync();
}

/// La llamada que empieza en [marca] debe llevar `.timeout(`
/// dentro de los siguientes [ventana] caracteres.
void _exigeTimeout(String fuente, String marca, {int ventana = 420}) {
  final i = fuente.indexOf(marca);
  expect(i, greaterThanOrEqualTo(0), reason: 'marca no hallada: $marca');
  final tramo = fuente.substring(i, (i + ventana).clamp(0, fuente.length));
  expect(tramo, contains('.timeout('),
      reason: 'la lectura «$marca» debe llevar timeout');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('S1 · fotos_cola: lectura de ids sin evidencia no quema', () {
    test('ok:false con ambos ids sin resolver = sin evidencia', () {
      expect(
          lecturaIdsSinEvidencia(
              clienteOk: false,
              suplementoOk: true,
              clienteId: null,
              suplementoId: null),
          isTrue);
      expect(
          lecturaIdsSinEvidencia(
              clienteOk: true,
              suplementoOk: false,
              clienteId: null,
              suplementoId: null),
          isTrue);
    });

    test('ok:true sostenido (aún sin id) NO es falta de evidencia: '
        'manda el contrato #8-1 y sí quema', () {
      expect(
          lecturaIdsSinEvidencia(
              clienteOk: true,
              suplementoOk: true,
              clienteId: null,
              suplementoId: null),
          isFalse);
    });

    test('con un id resuelto la foto procede aunque la otra '
        'lectura haya fallado', () {
      expect(
          lecturaIdsSinEvidencia(
              clienteOk: true,
              suplementoOk: false,
              clienteId: 7,
              suplementoId: null),
          isFalse);
      expect(
          lecturaIdsSinEvidencia(
              clienteOk: false,
              suplementoOk: true,
              clienteId: null,
              suplementoId: 3),
          isFalse);
    });
  });

  group('S2 · contarPendientesReclamables por instante real', () {
    test('una foto con backoff a +30 min no cuenta; una vencida sí',
        () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      SharedPreferences.setMockInitialValues({});
      final dir = await getDatabasesPath();
      final dbPath = p.join(dir, 'ironbody.db');
      await LocalDb.resetParaTest();
      for (final sufijo in ['', '-wal', '-shm']) {
        try {
          await File('$dbPath$sufijo').delete();
        } catch (_) {}
      }
      await LocalDb.resetParaTest();
      final db = await LocalDb.instance.db;
      final ahora = ahoraHabana();
      Future<void> sembrar(String uuid, DateTime proximo) async {
        await db.insert('fotos_cola', {
          'op_uuid': uuid,
          'tipo': 'display',
          'ruta_local': '/tmp/$uuid.webp',
          'estado': 'pendiente',
          'intentos': 0,
          'proximo_intento_en': isoHabana(proximo),
          'creado_en': isoHabana(ahora),
          'actualizado_en': isoHabana(ahora),
        });
      }

      await sembrar('op-futura', ahora.add(const Duration(minutes: 30)));
      await sembrar('op-vencida', ahora.subtract(const Duration(minutes: 1)));
      final n = await FotosColaService.instance.contarPendientesReclamables();
      expect(n, 1,
          reason: 'solo la vencida por instante real es reclamable; '
              'con el epoch de pared Habana en otra zona, la futura '
              'se contaba o la vencida se perdía por horas');
      await db.close();
    });
  });

  group('S3 · turno_service: sin op_uuid no se marca reconciliado', () {
    test('la rama opUuid == null no escribe el flag', () {
      final fuente = _fuente('lib/turno_service.dart');
      final i = fuente.indexOf('if (opUuid == null)');
      expect(i, greaterThanOrEqualTo(0));
      final tramo =
          fuente.substring(i, (i + 700).clamp(0, fuente.length));
      expect(tramo, isNot(contains("turno_id_reconciliado': 1")),
          reason: 'marcar el flag irreversible sin evidencia del '
              'servidor dejaba el turno con el id local para '
              'siempre si el canónico era otro');
      expect(tramo, contains('continue'));
    });
  });

  group('O1 · PlusReportesService: lecturas con timeout de 12 s', () {
    PlusReportesService svcColgado() => PlusReportesService(
        rpc: (nombre, params) => Completer<dynamic>().future);

    test('pendientes() corta por timeout', () {
      fakeAsync((async) {
        Object? error;
        var termino = false;
        svcColgado().pendientes().then((_) {
          termino = true;
        }, onError: (Object e) {
          error = e;
          termino = true;
        });
        async.elapse(const Duration(seconds: 11));
        expect(termino, isFalse, reason: 'dentro del timeout aún espera');
        async.elapse(const Duration(seconds: 2));
        expect(termino, isTrue, reason: 'el timeout resolvió la espera');
        expect(error, isA<TimeoutException>());
      });
    });

    test('confirmados() corta por timeout en la primera página '
        '(no pagina sobre una RPC colgada)', () {
      fakeAsync((async) {
        Object? error;
        var termino = false;
        svcColgado().confirmados().then((_) {
          termino = true;
        }, onError: (Object e) {
          error = e;
          termino = true;
        });
        async.elapse(const Duration(seconds: 13));
        expect(termino, isTrue);
        expect(error, isA<TimeoutException>());
      });
    });
  });

  group('D1 · guarda de fuente: clase N-2 fuera de nómina', () {
    // Cada validación de monto de dinero corregida exige finitud:
    // double.tryParse acepta 'NaN'/'Infinity' y toda comparación
    // (<= 0, < 0, > esperado) es falsa con NaN, así que el monto
    // llegaba a payloads, config o liquidaciones. Los sitios son
    // widgets sin seam de inyección: la guarda fija el patrón.
    test('liquidaciones y entregas', () {
      expect(_fuente('lib/ui/arqueo.dart'),
          contains('!entregado.isFinite'));
      final prc = _fuente('lib/ui/panel_resto_caja.dart');
      expect(prc, contains('!monto.isFinite'),
          reason: 'entrega parcial C1');
      expect(prc, contains('!v.isFinite'), reason: 'precios del gym');
    });

    test('configuración y gastos del dueño', () {
      final adm = _fuente('lib/ui/admin.dart');
      expect('!monto.isFinite'.allMatches(adm).length,
          greaterThanOrEqualTo(2),
          reason: 'tipos de pago (×2) y gasto');
      expect(adm, contains('v.isFinite && v > 0'),
          reason: 'montos de configuración: Infinity es > 0');
      expect(_fuente('lib/ui/centro_compras.dart'),
          contains('!monto.isFinite'));
    });

    test('ventas y catálogo de suplementos', () {
      final vs = _fuente('lib/ui/venta_suplemento.dart');
      expect('!precio.isFinite'.allMatches(vs).length, 2,
          reason: 'las dos rutas de venta validan el precio');
      final iTasa = vs.indexOf('get _tasaUsd');
      expect(
          vs.substring(iTasa, (iTasa + 400).clamp(0, vs.length)),
          contains('isFinite'),
          reason: 'la tasa se normaliza a null si no es finita');
      final ds = _fuente('lib/ui/detalle_suplemento.dart');
      final iPv = ds.indexOf('get _precioVenta');
      expect(ds.substring(iPv, (iPv + 400).clamp(0, ds.length)),
          contains('isFinite'));
      final sup = _fuente('lib/ui/suplementos.dart');
      expect(sup, contains('!precio.isFinite'));
      expect(sup, contains('costoCrudo'),
          reason: 'el costo no finito se trata como «sin costo»');
    });

    test('inscripción, servicios y tarifas especiales', () {
      expect(_fuente('lib/ui/inscribir.dart'), contains('v.isFinite'));
      final sa = _fuente('lib/ui/servicios_admin.dart');
      expect(sa, contains('valorCrudo'));
      expect(sa, contains('comisionCruda'));
      expect(sa, contains('costoCrudo'));
      final te = _fuente('lib/ui/tarifas_especiales.dart');
      final iPm = te.indexOf('double? _parseMonto');
      expect(te.substring(iPm, (iPm + 500).clamp(0, te.length)),
          contains('isFinite'),
          reason: '_parseMonto es el punto único de las tarifas');
    });
  });

  group('O2 · guarda de fuente: lecturas RPC con timeout', () {
    test('servicios y login/perfil', () {
      _exigeTimeout(
          _fuente('lib/permisos_entrenador.dart'), "'obtener_mis_permisos'");
      // La marca es la LECTURA (select): el upsert de la misma
      // tabla es una escritura y va sin timeout a propósito.
      _exigeTimeout(_fuente('lib/perfil.dart'), ".select('movil, carnet')",
          ventana: 500);
    });

    test('pantallas con datos locales bloqueadas por la RPC', () {
      _exigeTimeout(_fuente('lib/ui/estado_cuenta.dart'),
          "'cliente_plus_residual_staff'",
          ventana: 500);
      _exigeTimeout(_fuente('lib/ui/pestana_progreso.dart'),
          "'listar_mediciones_cliente'",
          ventana: 500);
    });

    test('pantallas de solo servidor: error con salida, no spinner', () {
      _exigeTimeout(
          _fuente('lib/ui/ficha_acceso.dart'), "'detalle_acceso_cliente'",
          ventana: 500);
      _exigeTimeout(_fuente('lib/ui/estadisticas_adopcion.dart'),
          "'estadisticas_adopcion'");
      _exigeTimeout(_fuente('lib/ui/vista_previa_cliente.dart'),
          "'preview_datos_cliente'",
          ventana: 500);
      _exigeTimeout(_fuente('lib/ui/editor_plan_nutricional.dart'),
          "'obtener_plan_cliente'",
          ventana: 500);
      _exigeTimeout(
          _fuente('lib/ui/foto_personal_ficha.dart'), "'admin_foto_personal_de'",
          ventana: 500);
    });

    test('control de acceso, horarios, campaña y panel de permisos', () {
      final ca = _fuente('lib/ui/control_acceso.dart');
      _exigeTimeout(ca, "'clientes_sin_acceso'");
      _exigeTimeout(ca, "'listar_auditoria_accesos'", ventana: 500);
      final hg = _fuente('lib/ui/horario_gym.dart');
      // Las DOS lecturas de obtener_horarios (función canónica y
      // _cargar de la pantalla) llevan timeout.
      var desde = 0;
      var halladas = 0;
      while (true) {
        final i = hg.indexOf("'obtener_horarios'", desde);
        if (i < 0) break;
        halladas++;
        final tramo =
            hg.substring(i, (i + 200).clamp(0, hg.length));
        expect(tramo, contains('.timeout('),
            reason: 'obtener_horarios #${halladas} sin timeout');
        desde = i + 1;
      }
      expect(halladas, 2);
      _exigeTimeout(
          _fuente('lib/ui/campana_wa.dart'), "'clientes_sin_acceso'");
      final pp = _fuente('lib/ui/panel_permisos.dart');
      _exigeTimeout(pp, ".from('entrenadores_autorizados')",
          ventana: 500);
      // La relectura de verificación también es lectura.
      final j = pp.indexOf(".select('activo, permisos')");
      expect(j, greaterThanOrEqualTo(0));
      expect(pp.substring(j, (j + 500).clamp(0, pp.length)),
          contains('.timeout('));
    });
  });
}
