// Tests delta 1.24.2 (auditoría de sincronización 2026-11-05,
// 5 módulos): invariantes de FUENTE al estilo de
// delta_1241_test/espejos_paridad_test — estas regresiones
// nacieron de listas que se desincronizaron del contrato y de
// caminos paralelos que se quedaron sin el arreglo del camino
// principal; el escaneo las caza en el acto. Más la función
// pura del backoff de comprobantes (M5-A3).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comprobantes.dart';

void main() {
  final sync = File('lib/sync.dart').readAsStringSync();
  final localdb = File('lib/localdb.dart').readAsStringSync();
  final fotosCola = File('lib/fotos_cola.dart').readAsStringSync();
  final fotosFg = File('lib/fotos_foreground.dart').readAsStringSync();
  final widgets = File('lib/ui/widgets.dart').readAsStringSync();
  final diseno = File('lib/ui/diseno.dart').readAsStringSync();
  final cola = File('lib/ui/cola.dart').readAsStringSync();
  final manifiesto = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();

  group('M2: frecuencia de recordatorios (patrón G-08)', () {
    test('el select del pull pide frecuencia', () {
      expect(sync, contains('fecha_fija,frecuencia,activa'),
          reason: 'sin frecuencia en el select, el recordatorio '
              'recurrente llega degradado a disparo único');
    });
    test('el conversor copia frecuencia al espejo', () {
      expect(sync, contains("'frecuencia': m['frecuencia']"));
    });
    test('v64 resetea el watermark de la tabla', () {
      final i = localdb.indexOf('oldV < 64');
      expect(i, isNonNegative, reason: 'sin bloque v64');
      final bloque = localdb.substring(i, i + 1600);
      expect(bloque, contains("'wm_espejo_recordatorio_config', '0'"),
          reason: 'sin el reset, las filas ya bajadas sin '
              'frecuencia no volverían a bajar');
      expect(bloque, contains('proximo_intento_en'),
          reason: 'v64 también añade el backoff de comprobantes');
    });
  });

  group('M1-F1: la revisión limpia el dinero optimista', () {
    test('las tres entradas a necesita_revision limpian el '
        'optimista completo', () {
      // Rechazada (existente) + revisión del servidor +
      // _bumpConReversion: las tres llaman la limpieza.
      final limpiezas =
          '_limpiarOptimistaDeOp(op);'.allMatches(sync).length;
      expect(limpiezas, greaterThanOrEqualTo(3),
          reason: 'alguna entrada a necesita_revision volvió a '
              'quedarse sin limpiar el dinero optimista');
      final entregas =
          'eliminarEntregaEfectivoPorOp(uuid)'.allMatches(sync).length;
      expect(entregas, greaterThanOrEqualTo(3),
          reason: 'una liquidación en revisión seguiría '
              'descontando el pendiente a entregar');
    });
  });

  group('M5-A1: lease de fotos por prefijo, no por valor', () {
    test('refresco y liberación comparan por workerId', () {
      final porPrefijo = "substr(v, 1, instr(v, '|') - 1) = ?"
          .allMatches(fotosCola)
          .length;
      expect(porPrefijo, greaterThanOrEqualTo(3),
          reason: 'temporizador + refresco del bucle + '
              'liberación: si alguno vuelve al valor exacto, el '
              'lease queda huérfano tras una subida larga');
    });
  });

  group('M5-A2/M3-H01: exención de batería', () {
    test('el manifiesto declara el permiso', () {
      expect(manifiesto,
          contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS'),
          reason: 'sin el permiso, el intent del diálogo de '
              'exención no puede abrir: el botón parece muerto');
    });
    test('el estado es triestado y la petición devuelve '
        'resultado', () {
      expect(fotosFg, contains('enum EstadoExencionBateria'));
      expect(fotosFg, contains('enum ResultadoPedirExencion'));
    });
  });

  group('M3-H02: el cartel rojo despliega el detalle', () {
    test('el banner pinta la acción del error y el reintento', () {
      expect(widgets, contains('Qué hacer:'));
      expect(widgets, contains('Reintentar ahora'));
      expect(widgets, contains('final esError'));
    });
  });

  group('M1-F3/M3-H03: sellos honestos', () {
    test('_download expone fallidas y los sellos la honran', () {
      expect(sync, contains('fallidas: fallidas'));
      expect(sync, contains('resDownload.fallidas == 0'));
      expect(sync, contains('pushFalloTotal'),
          reason: 'last_push_ok/ultimo_sincronizado deben '
              'saltarse ante un fallo total de push');
    });
  });

  group('M3-H05: título honesto del resumen de la Cola', () {
    test('el diálogo usa resumenCorto del resultado', () {
      expect(cola, contains('titulo: res.resumenCorto'));
    });
  });

  group('Interruptores visibles (reporte de campo)', () {
    test('el tema define switchTheme', () {
      expect(diseno, contains('switchTheme: SwitchThemeData('),
          reason: 'sin switchTheme, el OFF de Material 3 no '
              'contrasta sobre las superficies oscuras');
    });
  });

  group('M5-A3: backoff de comprobantes', () {
    test('la progresión es 60·2^n con tope de 1800', () {
      expect(backoffComprobanteSegundos(0), 60);
      expect(backoffComprobanteSegundos(1), 60);
      expect(backoffComprobanteSegundos(2), 120);
      expect(backoffComprobanteSegundos(3), 240);
      expect(backoffComprobanteSegundos(5), 960);
      expect(backoffComprobanteSegundos(6), 1800);
      expect(backoffComprobanteSegundos(20), 1800);
    });
    test('el lote filtra por proximo_intento_en', () {
      final comp = File('lib/comprobantes.dart').readAsStringSync();
      expect(comp,
          contains("estado = 'pendiente' AND proximo_intento_en <= ?"));
    });
  });

  group('Watermark: los tombstones no clavan el mínimo (campo '
      '2026-11-05)', () {
    test('borrados y los borrados de GymPedia/Guía están fuera '
        'de tablasConWatermark', () {
      final i = localdb.indexOf('static const tablasConWatermark');
      final j = localdb.indexOf('];', i);
      // Sin líneas de comentario: la nota que lo explica nombra
      // las tablas entre comillas y no debe contar como entrada.
      final bloque = localdb
          .substring(i, j)
          .split('\n')
          .where((l) => !l.trim().startsWith('//'))
          .join('\n');
      for (final t in ['borrados', 'gympedia_borrados', 'guia_borrados']) {
        expect(bloque.contains("'$t'"), isFalse,
            reason: '$t tiene cursor propio: con su tabla vacía '
                'en el servidor, el mínimo global quedaba en 0 '
                'para siempre y el ciclo nunca era «completo»');
      }
    });
  });

  group('Paquete Buscar (elección de Jc)', () {
    final buscar = File('lib/ui/buscar.dart').readAsStringSync();
    final negocio = File('lib/negocio.dart').readAsStringSync();

    test('cabecera compacta: banner estrecho y avanzada plegada',
        () {
      expect(buscar, contains('SyncBanner(compact: true)'));
      expect(buscar, contains('if (_mostrarAvanzada)'));
    });
    test('orden a elegir, persistido y aplicado tras filtrar', () {
      expect(buscar, contains('_aplicarOrden(r)'));
      expect(buscar, contains("setMeta('buscar_orden', v)"));
      expect(buscar, contains("case 'vencidosPrimero':"));
      expect(buscar, contains("case 'recientes':"));
    });
    test('densidad compacta persistida y pasada a la fila', () {
      expect(buscar, contains("setMeta(\n                        'buscar_compacta'"));
      expect(buscar, contains('compacta: _compacta'));
    });
    test('semáforo en el avatar e icono de notas en la fila', () {
      expect(buscar, contains('colorBorde: colorSemaforo'));
      expect(buscar, contains('Icons.sticky_note_2_outlined'));
      expect(buscar, contains('tieneNotas'));
    });
    test('menú rápido, WhatsApp directo y cadena de avisos', () {
      expect(buscar, contains('_menuRapido(c)'));
      expect(buscar, contains('accionWhatsapp:'));
      expect(buscar, contains('_avisarSeleccionados'));
      expect(buscar, contains('Ya avisé · Siguiente'),
          reason: 'abrir WhatsApp no cuenta como avisado: la '
              'cadena espera la confirmación del usuario');
    });
    test('los textos de aviso viven en negocio como fuente única',
        () {
      expect(negocio, contains('String mensajeWaSegunEstado'));
      expect('mensajeWaVencido('.allMatches(negocio).length,
          greaterThanOrEqualTo(2),
          reason: 'la bandeja debe usar el mismo constructor '
              'que Buscar (si no, los textos divergen)');
      expect(buscar, contains('mensajeWaSegunEstado(c)'));
    });
  });
}
