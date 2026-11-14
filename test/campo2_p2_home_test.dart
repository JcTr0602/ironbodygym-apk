/// 1.34 Campo 2 (P-2b): al terminar una sync, Home solo
/// reconstruye el pilar VISIBLE; los demás quedan
/// marcados sucios y se reconstruyen al activarse.
///
/// El mecanismo es la identidad de widget: el build de
/// Home pasa por _pilarParaMostrar, que devuelve la
/// MISMA instancia guardada para un pilar inactivo
/// (Flutter no reconstruye un subárbol cuyo widget es
/// idéntico) y construye fresco el activo. Estos
/// contratos fijan el cableado; el comportamiento de la
/// cáscara lo cubren el banco de widgets y las suites de
/// Home (navegación entre pilares incluida).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/ui/home.dart').readAsStringSync();

  group('P-2b · pilares de Home', () {
    test('el IndexedStack pinta vía _pilarParaMostrar', () {
      expect(src, contains('child: _pilarParaMostrar(i, esDueno),'));
    });

    test('_pilarParaMostrar reutiliza la instancia del '
        'inactivo y construye fresco el activo', () {
      final ini = src.indexOf('Widget _pilarParaMostrar');
      final fin = src.indexOf('Widget _cuerpoPilar', ini);
      final cuerpo = src.substring(ini, fin);
      expect(cuerpo, contains('if (i == _pilarActivo)'));
      expect(cuerpo, contains('_cuerpoPilarCache[i]'));
      expect(cuerpo, contains('return cache;'));
    });

    test('al idle, los pilares no visibles quedan sucios',
        () {
      expect(
          src,
          contains('_pilaresSucios\n'
              '            .addAll(_pilaresVisitados.where((p) => p != _pilarActivo));'));
    });

    test('la suciedad se limpia al mostrar el pilar', () {
      final ini = src.indexOf('Widget _pilarParaMostrar');
      final fin = src.indexOf('Widget _cuerpoPilar', ini);
      expect(src.substring(ini, fin),
          contains('_pilaresSucios.remove(i);'));
    });
  });
}
