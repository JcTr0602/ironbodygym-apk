/// Bloque 4 (B7+T7, 1.23): estados vacíos unificados y cruce
/// de estados en las pantallas del alcance.
///
/// B7: el estado vacío de PANTALLA COMPLETA deja de construirse
/// a mano (Center/Column con icono+texto) y pasa al compartido
/// [EstadoVacio] de componentes.dart, conservando textos y la
/// acción que tuviera. Los vacíos de SECCIÓN (una tarjeta dentro
/// de una lista con más contenido) NO se migran: quedan
/// fijados aquí como decisión, no como olvido.
///
/// T7: el cuerpo se envuelve en [CruceEstados] con la key SOLO
/// por tipo de estado ('cargando'/'contenido'/'vacio'/'error')
/// — veredicto de Argón: prohibido GlobalKey en los hijos y
/// prohibido que la key dependa de los datos (destruiría el
/// ScrollController en cada refresco).
///
/// Son pins de FUENTE a propósito: montar cada pantalla exige
/// sesión/BD/red; lo que la pieza garantiza es la gramática
/// (qué componente se usa y qué patrón manual desapareció).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String nombre) =>
    File('lib/ui/$nombre').readAsStringSync();

void main() {
  group('B7 — vacíos de pantalla completa migrados a EstadoVacio', () {
    test('solicitudes_adelanto: el Text suelto ahora es el título '
        'del EstadoVacio', () {
      final s = _src('solicitudes_adelanto.dart');
      expect(s, contains('EstadoVacio('));
      expect(s, contains("titulo: 'No hay solicitudes de adelanto.'"));
      // El patrón manual (Text centrado a mano) desapareció.
      expect(s, isNot(contains("Text(\n            'No hay solicitudes")));
    });

    test('avisos_entrenador: título y subtítulo conservan el texto '
        'completo anterior', () {
      final s = _src('avisos_entrenador.dart');
      expect(s, contains('EstadoVacio('));
      expect(s, contains("titulo: 'No hay avisos.'"));
      expect(s,
          contains("'Crea uno con el botón «Nuevo aviso»: '"));
      expect(s, isNot(contains("Text(\n            'No hay avisos.")));
    });

    test('plantillas_mensaje: sin el Center+Text manual', () {
      final s = _src('plantillas_mensaje.dart');
      expect(s, contains('EstadoVacio('));
      expect(s, contains("titulo: 'Sin plantillas.'"));
      expect(
          s, contains("subtitulo: 'Crea la primera con el botón +.'"));
      expect(s,
          isNot(contains("'Sin plantillas. Crea la primera")));
    });

    test('servicios_historial: la tarjeta casera del vacío se fue; '
        'textos y acción «Limpiar búsqueda» se conservan', () {
      final s = _src('servicios_historial.dart');
      expect(s, contains('EstadoVacio('));
      expect(s, contains("'Sin operaciones registradas.'"));
      expect(s, contains("'Sin operaciones con esa búsqueda.'"));
      expect(s, contains("'Sin operaciones con ese filtro.'"));
      // La acción sigue existiendo, ahora como acción del vacío.
      expect(s, contains("textoAccion:"));
      expect(s, contains("'Limpiar búsqueda'"));
      // El contenedor hecho a mano (fondo redondeado propio) no.
      expect(s, isNot(contains('BorderRadius.circular(12)')));
    });

    test('conteo de archivos con vacío migrado en esta pieza: 4', () {
      const migrados = [
        'solicitudes_adelanto.dart',
        'avisos_entrenador.dart',
        'plantillas_mensaje.dart',
        'servicios_historial.dart',
      ];
      var cuenta = 0;
      for (final f in migrados) {
        if (_src(f).contains('EstadoVacio(')) cuenta++;
      }
      expect(cuenta, 4);
    });
  });

  group('T7 — CruceEstados con key solo por tipo de estado', () {
    const conCruce = [
      'solicitudes_adelanto.dart',
      'avisos_entrenador.dart',
      'plantillas_mensaje.dart',
      'diferencias_caja.dart',
      'servicios_historial.dart',
      'estadisticas_adopcion.dart',
      'usuarios.dart',
    ];

    test('las 7 pantallas del alcance envuelven su cuerpo', () {
      for (final f in conCruce) {
        expect(_src(f), contains('CruceEstados('), reason: f);
      }
      // Seis incluyen la carga en el cruce. servicios_historial
      // NO: su carga devuelve un Scaffold propio temprano (sin
      // la cabecera de filtros) y su cruce cubre vacío/contenido
      // en la zona de resultados — forzar 'cargando' ahí dentro
      // cambiaría la estructura de la pantalla.
      for (final f in conCruce) {
        if (f == 'servicios_historial.dart') continue;
        expect(_src(f), contains("'cargando'"), reason: f);
      }
      final hist = _src('servicios_historial.dart');
      expect(hist,
          contains("estado: visibles.isEmpty ? 'vacio' : 'contenido'"));
      expect(hist,
          contains("EstadoCargando(texto: 'Cargando historial…')"));
    });

    test('los estados usados son solo tipos, nunca datos', () {
      for (final f in conCruce) {
        if (f == 'servicios_historial.dart') continue;
        final s = _src(f);
        // Ningún CruceEstados del alcance lleva GlobalKey ni una
        // key construida con datos de la lista.
        expect(s, isNot(contains('GlobalKey')), reason: f);
      }
      // servicios_historial SÍ tiene GlobalKeys PREEXISTENTES
      // (mapa por fila de venta, línea ~59: llaves de fila, no
      // hijos directos del switcher). La prohibición de Argón es
      // sobre los hijos directos de CruceEstados; la fila vive
      // dentro del ListView, que es UN solo hijo. Se fija aquí
      // para que nadie lo «corrija» a ciegas.
      expect(_src('solicitudes_adelanto.dart'), contains("'vacio'"));
      expect(_src('avisos_entrenador.dart'), contains("'vacio'"));
      expect(_src('plantillas_mensaje.dart'), contains("'vacio'"));
      expect(_src('servicios_historial.dart'), contains("'vacio'"));
      expect(_src('usuarios.dart'), contains("'vacio'"));
      expect(_src('estadisticas_adopcion.dart'), contains("'error'"));
      expect(_src('diferencias_caja.dart'), contains("'contenido'"));
    });
  });

  group('Fuera de alcance fijado (vacíos de sección, NO migrados)',
      () {
    test('medidas_cliente: es una TARJETA de la ficha, no una '
        'pantalla; su vacío sigue como texto de sección', () {
      final s = _src('medidas_cliente.dart');
      expect(s, contains("'Sin medidas registradas todavía.'"));
      expect(s, isNot(contains('EstadoVacio(')));
      expect(s, isNot(contains('CruceEstados(')));
    });

    test('diferencias_caja: «sin abiertas» sigue como tarjeta de '
        'sección dentro de la lista', () {
      final s = _src('diferencias_caja.dart');
      expect(s, contains("'No hay diferencias de caja abiertas.'"));
    });

    test('estadisticas_adopcion: los «sin datos» de cada gráfica '
        'siguen como texto de sección', () {
      final s = _src('estadisticas_adopcion.dart');
      expect(s, contains("'Sin datos de activaciones.'"));
      expect(s, contains("'Sin ingresos registrados.'"));
      expect(s, isNot(contains('EstadoVacio(')));
    });

    test('usuarios: su vacío YA era EstadoVacio y el del diálogo '
        'de accesos queda como texto (diálogo, no pantalla)', () {
      final s = _src('usuarios.dart');
      expect(s, contains("titulo: 'Sin datos'"));
      expect(s, contains("'Sin accesos registrados.'"));
    });
  });
}
