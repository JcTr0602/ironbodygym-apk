// Tests delta 1.24.1 (auditoría post-implementación de Argón):
// G-04a — la atribución de Actividad normaliza el registrado_por
// que llega como String numérico desde el servidor;
// G-03 — la vigencia del bloqueo manual compara el instante
// crudo en UTC contra ahoraUtcReal() (no el wall-clock Habana).
// Ronda 2 (G-07..G-10): invariantes de FUENTE al estilo de
// espejos_paridad_test — el conversor y el push no tienen un
// arnés unitario directo, y estas regresiones nacieron
// precisamente de listas/rutas que se desincronizaron del
// contrato; el escaneo las caza en el acto.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  group('G-04a: registrado_por como String numérico', () {
    const yo = 'Gabriel';
    const miTelegram = 1403501391;

    Map<String, dynamic> item(String accion, String actor) => {
          'accion': accion,
          'actor': actor,
          'cliente_id': 42,
        };

    test('mensualidad de mi cliente (firma String) cobrada por '
        'otro SÍ se ve', () {
      final cliente = <String, dynamic>{
        'id': 42,
        'registrado_por': '1403501391',
      };
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Jc'),
            cliente: cliente, miActor: yo, miTelegramId: miTelegram),
        isTrue,
      );
    });

    test('mensualidad de cliente de otro (firma String) NO se ve',
        () {
      final cliente = <String, dynamic>{
        'id': 42,
        'registrado_por': '969869611',
      };
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Jc'),
            cliente: cliente, miActor: yo, miTelegramId: miTelegram),
        isFalse,
      );
    });

    test('cliente sin firma sigue sin acreditarse a nadie', () {
      final cliente = <String, dynamic>{'id': 42};
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Jc'),
            cliente: cliente, miActor: yo, miTelegramId: miTelegram),
        isFalse,
      );
    });
  });

  group('G-03: vigencia del bloqueo manual por instante UTC', () {
    Map<String, dynamic> acceso(String? hasta) => {
          'cliente_id': 7,
          'nombre': 'Prueba',
          'telefono': '55555555',
          'activo': true,
          'bloqueado': true,
          'bloqueado_hasta': hasta,
        };

    test('bloqueado_hasta futuro (instante Z) → vigente', () {
      final futuro =
          DateTime.now().toUtc().add(const Duration(hours: 2));
      final a = AccesoCliente.fromJson(
          acceso(futuro.toIso8601String()));
      expect(a.bloqueoManualVigente, isTrue);
    });

    test('bloqueado_hasta pasado (instante Z) → no vigente', () {
      final pasado =
          DateTime.now().toUtc().subtract(const Duration(hours: 2));
      final a = AccesoCliente.fromJson(
          acceso(pasado.toIso8601String()));
      expect(a.bloqueoManualVigente, isFalse);
    });

    test('sin bloqueado_hasta → vigente (bloqueo indefinido)', () {
      final a = AccesoCliente.fromJson(acceso(null));
      expect(a.bloqueoManualVigente, isTrue);
    });
  });

  group('Ronda 2 — invariantes de fuente (G-07..G-10)', () {
    final sync = File('lib/sync.dart').readAsStringSync();
    final localdb = File('lib/localdb.dart').readAsStringSync();
    final editor =
        File('lib/ui/editor_rutinas_gym.dart').readAsStringSync();

    test('G-09: nomina_liquidada y turnos_apertura están en la '
        'rama id TEXT + data jsonb del conversor', () {
      final i = sync.indexOf("tabla == 'gympedia_articulos'");
      expect(i, isNonNegative, reason: 'rama jsonb no encontrada');
      final cierre = sync.indexOf(') {', i);
      final rama = sync.substring(i, cierre);
      for (final t in ['nomina_liquidada', 'turnos_apertura']) {
        expect(rama, contains("tabla == '$t'"),
            reason: '$t fuera de la rama: su id TEXT lanzaría '
                'TypeError en el fallback de id entero y su '
                'espejo quedaría vacío para siempre');
      }
    });

    test('G-08: el select de turnos_cierre pide las 19 y el '
        'conversor copia las 7 nuevas de E-01', () {
      expect(
          sync,
          contains('pendientes_count,pendientes_cup,'
              'pendientes_usd,'),
          reason: 'el select sigue pidiendo solo las 12 viejas');
      for (final c in [
        'turno_id',
        'hora_apertura',
        'hora_cierre',
        'pendientes_count',
        'pendientes_cup',
        'pendientes_usd',
        'revision_count',
      ]) {
        expect(sync, contains("'$c': m['$c']"),
            reason: 'el conversor no copia $c al espejo');
      }
    });

    test('G-08: la migración v63 existe y resetea el watermark '
        'de turnos_cierre otra vez', () {
      expect(LocalDb.versionActual, greaterThanOrEqualTo(63));
      final i = localdb.indexOf('oldV < 63');
      expect(i, isNonNegative, reason: 'sin bloque v63');
      final bloque = localdb.substring(i, i + 1200);
      expect(bloque, contains("'wm_turnos_cierre', '0'"),
          reason: 'v63 no resetea el watermark: el reset de '
              'v62 ya se consumió con el select viejo');
    });

    test('G-07: el editor de Rutinas del gym lee las fichas '
        'PUBLICADAS de la Guía con id canónico', () {
      expect(editor, contains('guiaPublicadas()'),
          reason: 'el catálogo no sale de guia_fichas');
      expect(editor, contains(r"'${equipoId}_$slug'"),
          reason: 'el id guardado no es el canónico que '
              'Clientes cruza al adoptar');
      expect(editor, isNot(contains("allMirror('gympedia_articulos')")),
          reason: 'volvió la fuente equivocada (artículos de '
              'lectura): toda rutina publicada sería inadoptable');
    });

    test('G-10b: todo bumpOp del push pasa por el envoltorio '
        'con reversión (solo el envoltorio llama a bumpOp)', () {
      expect(sync, contains('Future<void> _bumpConReversion'),
          reason: 'el envoltorio desapareció');
      final llamadas = '_db.bumpOp('.allMatches(sync).length;
      expect(llamadas, 1,
          reason: 'hay $llamadas llamadas a _db.bumpOp en '
              'sync.dart: alguna ruta de fallo vuelve a dejar el '
              'vencimiento optimista sin revertir');
      expect(localdb, contains('Future<String?> estadoOp('),
          reason: 'el lector de estado de la op desapareció');
    });

    test('G-10a: el rechazo 4xx de _uploadUnaPorUna limpia el '
        'optimista y revierte el vencimiento', () {
      final i = sync.indexOf("markOp(uuid, 'rechazada'");
      expect(i, isNonNegative, reason: 'rama 4xx no encontrada');
      final rama = sync.substring(i, i + 1600);
      expect(rama, contains('_limpiarOptimistaDeOp(op)'));
      expect(rama, contains('_revertirVencimientoOptimista(op)'));
      expect(rama, contains('eliminarEntregaEfectivoPorOp(uuid)'));
    });
  });
}
