// 1.25 T113: ajustes que se encuentran — el índice por
// sección refleja la reagrupación y el buscador filtra
// por título normalizado.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/ajustes.dart';

void main() {
  test('la reagrupación quedó fijada en el índice', () {
    expect(titulosPorSeccionAjustes['Apariencia'],
        containsAll(['Vibración', 'Alto contraste']));
    expect(titulosPorSeccionAjustes['Notificaciones'],
        isNot(contains('Vibración')));
    expect(titulosPorSeccionAjustes['Notificaciones'],
        isNot(contains('Alto contraste')));
    expect(titulosPorSeccionAjustes['Notificaciones'],
        isNot(contains('Sincronizar al abrir la app')));
    expect(titulosPorSeccionAjustes['Datos'],
        contains('Sincronizar al abrir la app'));
    expect(titulosPorSeccionAjustes['Datos'],
        isNot(contains('Exportar bitácora')));
    expect(titulosPorSeccionAjustes['Diagnóstico'], [
      'Exportar bitácora',
      'Exportar novedades de la bitácora',
      'Exportar y reiniciar bitácora',
      'Reiniciar bitácora',
    ]);
  });
  test('ningún título vive en dos secciones', () {
    final vistos = <String>{};
    for (final titulos in titulosPorSeccionAjustes.values) {
      for (final t in titulos) {
        expect(vistos.add(t), isTrue, reason: 'duplicado: $t');
      }
    }
  });
  test('la coincidencia es sin acentos y por tokens', () {
    expect(coincideBusquedaAjuste('Alto contraste', 'contraste'), isTrue);
    expect(coincideBusquedaAjuste('PIN rápido', 'pin'), isTrue);
    expect(coincideBusquedaAjuste('Exportar bitácora', 'bitacora'), isTrue);
    expect(coincideBusquedaAjuste('Tema', 'contraste'), isFalse);
    expect(coincideBusquedaAjuste('Tema', ''), isTrue);
  });
  test('la sección se enseña solo si algo suyo coincide', () {
    expect(seccionVisibleAjustes('Apariencia', 'vibración'), isTrue);
    expect(seccionVisibleAjustes('Notificaciones', 'vibración'), isFalse);
    expect(seccionVisibleAjustes('Diagnóstico', 'bitácora'), isTrue);
    expect(seccionVisibleAjustes('Perfil', ''), isTrue);
    expect(seccionVisibleAjustes('Perfil', 'xyz'), isFalse);
  });
}
