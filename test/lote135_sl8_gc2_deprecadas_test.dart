/// SL-8 · GC-2: la sync se dice UNA sola vez (regla de Jc):
/// el icono de cabecera es la única voz. SyncBanner y
/// SyncPill quedan marcadas @Deprecated como retiradas en
/// lib/ui/widgets.dart — sin eliminarlas ni retirar usos
/// (eso va en los lotes dueños de cada pantalla).
///
/// El test vigila dos cosas:
/// 1. Ambas piezas llevan la marca con el texto de la regla.
/// 2. No existen usos vivos (constructor) FUERA de la lista
///    blanca construida con los usos vivos en ead3d63: la
///    comprobación es «todo uso está en la lista blanca»,
///    así que las retiradas posteriores (que la lista se
///    quede grande) no rompen el test, pero un uso NUEVO en
///    un archivo nuevo sí.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Lista blanca EXACTA de archivos con usos vivos de
/// `SyncBanner(` / `SyncPill(` en la base ead3d63
/// (lib/ui/widgets.dart es la definición y queda fuera).
const kUsosSyncBannerPillListaBlanca = <String>{
  // lib/ — pantallas con SyncBanner vivo
  'lib/ui/admin.dart',
  'lib/ui/ajustes.dart',
  'lib/ui/arqueo.dart',
  'lib/ui/auditoria.dart',
  'lib/ui/avisos.dart',
  'lib/ui/avisos_entrenador.dart',
  'lib/ui/ayuda.dart',
  'lib/ui/bandeja_whatsapp.dart',
  'lib/ui/buscar.dart',
  'lib/ui/categorias_suplemento.dart',
  'lib/ui/congelados.dart',
  'lib/ui/control_acceso.dart',
  'lib/ui/cuentas_cobrar.dart',
  'lib/ui/cuentas_por_cobrar.dart',
  'lib/ui/cumpleanos.dart',
  'lib/ui/dashboard.dart',
  'lib/ui/detalle_entrenador.dart',
  'lib/ui/detalle_pendiente.dart',
  'lib/ui/detalle_suplemento.dart',
  'lib/ui/estadisticas_adopcion.dart',
  'lib/ui/ficha.dart',
  'lib/ui/historial_entrenador.dart',
  'lib/ui/historial_ventas.dart',
  'lib/ui/incidencias_sync.dart',
  'lib/ui/inscribir.dart',
  'lib/ui/invitados.dart',
  'lib/ui/liquidaciones_historial.dart',
  'lib/ui/listas.dart',
  'lib/ui/mi_nomina.dart',
  'lib/ui/mi_turno.dart',
  'lib/ui/pagaron_mes.dart',
  'lib/ui/pago.dart',
  'lib/ui/pago_diario.dart',
  'lib/ui/panel_premios.dart',
  'lib/ui/panel_premios_clientes.dart',
  'lib/ui/papelera.dart',
  'lib/ui/pendiente.dart',
  'lib/ui/por_cobrar.dart',
  'lib/ui/ranking_servicios.dart',
  'lib/ui/reportes_plus.dart',
  'lib/ui/riesgo.dart',
  'lib/ui/servicios_estadisticas.dart',
  'lib/ui/solicitudes_adelanto.dart',
  'lib/ui/suplementos.dart',
  'lib/ui/venta_suplemento.dart',
  'lib/ui/venta_suplemento_inscripcion.dart',
  // test/ — usos vivos en la suite de la base
  'test/bloque5_t8_b11_test.dart',
  'test/delta_1242_test.dart',
  'test/gestion128_m1bc_test.dart',
  'test/gestion129_oleada5_test.dart',
  'test/gestion130_oleada_d6_test.dart',
  'test/yunque3_banner_test.dart',
};

/// La anotación que pega a una clase, con los literales
/// concatenados ya unidos (la frase de la regla puede
/// vivir en un literal o repartida en varios).
String _anotacionPegada(String src, String clase) {
  final i = src.indexOf('class $clase extends');
  if (i <= 0) return '';
  final antes = src.substring(0, i);
  if (!antes.trimRight().endsWith(')')) return '';
  final inicio = antes.lastIndexOf('@Deprecated');
  if (inicio < 0) return '';
  return antes
      .substring(inicio)
      .replaceAll(RegExp(r"'\s*'"), '')
      .replaceAll(RegExp(r'\s+'), ' ');
}

void main() {
  group('GC-2 · marca de retirada', () {
    final src = File('lib/ui/widgets.dart').readAsStringSync();

    test('SyncBanner lleva @Deprecated con el texto de la regla', () {
      final anotacion = _anotacionPegada(src, 'SyncBanner');
      expect(anotacion, isNotEmpty,
          reason: 'la anotación @Deprecated(...) debe cerrar '
              'justo antes de la clase SyncBanner');
      expect(anotacion,
          contains('la sync se dice una sola vez, con el icono de cabecera'),
          reason: 'el texto de la marca es el de la regla de Jc');
    });

    test('SyncPill lleva @Deprecated con el texto de la regla', () {
      final anotacion = _anotacionPegada(src, 'SyncPill');
      expect(anotacion, isNotEmpty,
          reason: 'la anotación @Deprecated(...) debe cerrar '
              'justo antes de la clase SyncPill');
      expect(anotacion,
          contains('la sync se dice una sola vez, con el icono de cabecera'),
          reason: 'el texto de la marca es el de la regla de Jc');
    });

    test('IconoSyncCabecera NO está marcada (es la voz que queda)', () {
      final i = src.indexOf('class IconoSyncCabecera extends');
      expect(i, greaterThan(0));
      final antes = src.substring(0, i);
      final inicioAnotacion = antes.lastIndexOf('@Deprecated');
      // Entre la última @Deprecated del archivo y la clase
      // debe mediar otra declaración (la de SyncPill u otra):
      // si la anotación pegara a IconoSyncCabecera, el
      // segmento terminaría en ')'.
      if (inicioAnotacion > 0) {
        expect(antes.trimRight().endsWith(')'), isFalse,
            reason: 'el icono de cabecera es la superficie '
                'vigente: no lleva marca de retirada');
      }
    });
  });

  group('GC-2 · usos fuera de la lista blanca', () {
    test('todo uso vivo de SyncBanner(/SyncPill( está en la lista', () {
      final patron = RegExp(r'\b(SyncBanner|SyncPill)\s*\(');
      final fuera = <String>[];
      for (final raiz in ['lib', 'test']) {
        for (final entidad in Directory(raiz)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
          final ruta = entidad.path.replaceAll('\\', '/');
          if (ruta == 'lib/ui/widgets.dart') continue; // la definición
          if (ruta == 'test/lote135_sl8_gc2_deprecadas_test.dart') {
            continue; // este propio test nombra las piezas
          }
          for (final linea in entidad.readAsLinesSync()) {
            final t = linea.trimLeft();
            if (t.startsWith('//') || t.startsWith('*')) continue;
            if (patron.hasMatch(linea)) {
              if (!kUsosSyncBannerPillListaBlanca.contains(ruta)) {
                fuera.add('$ruta: ${linea.trim()}');
              }
              break;
            }
          }
        }
      }
      expect(fuera, isEmpty,
          reason: 'usos nuevos de piezas retiradas fuera de '
              'la lista blanca de ead3d63:\n${fuera.join('\n')}');
    });
  });
}
