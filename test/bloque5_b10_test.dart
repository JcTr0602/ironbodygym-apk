/// 1.23 Bloque 5 — B10 (tokens y AppBar compartida), pieza AppBar.
///
/// La AppBar plana del sistema vive en lib/ui/app_bar.dart
/// (appBarIron): título de texto + acciones, sin propiedades
/// visuales propias — el aspecto sale del AppBarTheme de
/// lib/ui/diseno.dart. La migración es progresiva: las AppBar
/// con bottom (tabs/buscadores), colores propios, leading
/// propio o título que no es texto simple quedan como están.
///
/// Pines:
/// - El helper existe y conserva su firma.
/// - Las pantallas migradas (las que importan app_bar.dart) no
///   bajan del conteo alcanzado en la pasada B10.
/// - El codemod de tokens previo no se revierte: ningún
///   literal de la escala vuelve a lib/ como número suelto
///   (EdgeInsets.all/symmetric/only en cualquier forma,
///   incluida multilínea, y BorderRadius.circular de la
///   escala AppEspacio/AppRadio). Los valores FUERA de
///   escala (p. ej. BorderRadius.circular(20) o un
///   vertical: 3) quedan permitidos a propósito: no son de
///   la escala y forzarlos cambiaría el dibujo.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartDeLib() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  group('B10 AppBar compartida', () {
    test('app_bar.dart existe y define appBarIron', () {
      final f = File('lib/ui/app_bar.dart');
      expect(f.existsSync(), isTrue,
          reason: 'la AppBar compartida vive en lib/ui/app_bar.dart');
      final src = f.readAsStringSync();
      expect(src, contains('AppBar appBarIron('),
          reason: 'el helper conserva su nombre y tipo de retorno');
      expect(src, contains('String titulo'));
      expect(src, contains('List<Widget>? acciones'));
      // Sin cambio visual buscado: el helper no fija colores ni
      // elevación como propiedades; eso es del AppBarTheme
      // (diseno.dart). (La documentación sí los nombra, sin
      // dos puntos de argumento.)
      expect(src, isNot(contains('backgroundColor:')));
      expect(src, isNot(contains('elevation:')));
    });

    test('pantallas migradas a appBarIron: no menos de 89', () {
      final migradas = _dartDeLib()
          .where((f) => f.path != 'lib/ui/app_bar.dart')
          .where((f) => f.readAsStringSync().contains('app_bar.dart'))
          .length;
      // Pasada B10: 168 AppBar planas migradas en 89 archivos.
      // El resto de AppBar( directas son a medida (bottom,
      // colores, leading, título con overflow) o la interna de
      // IronAppBar en componentes.dart.
      expect(migradas, greaterThanOrEqualTo(89),
          reason: 'la migración B10 no retrocede');
    });

    test('codemod de tokens: ningún literal de la escala en lib/',
        () {
      // Panel Bloque 5 (ajuste 3): la guarda cubre TAMBIÉN
      // symmetric y only, incluidas las formas multilínea.
      // Captura los argumentos de cada EdgeInsets.all/
      // symmetric/only (hasta el primer ')', 160 caracteres)
      // y busca dentro un valor de la escala como literal
      // suelto (all) o como `nombre: valor` (symmetric/only).
      // Los valores FUERA de escala dentro de la misma
      // llamada (p. ej. vertical: 3) quedan permitidos: la
      // migración es por VALOR, no por llamada.
      const escala = [4, 8, 12, 16, 24, 32];
      final ctor = RegExp(
          r'EdgeInsets\.(all|symmetric|only)\(([\s\S]{0,160}?)\)');
      final ofensores = <String>[];
      for (final f in _dartDeLib()) {
        final src = f.readAsStringSync();
        for (final m in ctor.allMatches(src)) {
          final args = m.group(2)!;
          for (final v in escala) {
            if (RegExp('(^|[\\s,:])$v(\\.0)?(\\s*[,)])')
                .hasMatch(args)) {
              ofensores.add(
                  '${f.path} :: EdgeInsets.${m.group(1)}($args)');
              break;
            }
          }
        }
        for (final v in [8, 12, 16, 999]) {
          if (RegExp('BorderRadius\\.circular\\(\\s*$v(\\.0)?\\s*\\)')
              .hasMatch(src)) {
            ofensores.add('${f.path} :: BorderRadius.circular($v)');
          }
        }
      }
      expect(ofensores, isEmpty,
          reason: 'los literales de la escala vuelven solo como '
              'AppEspacio/AppRadio');
    });
  });
}
