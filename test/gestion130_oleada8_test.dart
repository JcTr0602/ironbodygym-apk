/// Gestión 1.30 · Oleada 8 (§9.2 + §13): literales a tokens,
/// residuo *Texto, D-19 y errores amables (17 sitios + GEN-09).
///
/// Contrato que se fija:
/// · `mensajeErrorAmable`: la tabla del plan, texto exacto —
///   timeout (con y sin enTimeout), red, Postgrest P0001 (su
///   mensaje, que ya nace en español) frente a otro código,
///   StateError/Exception de negocio curado (fila GEN-09: pasa
///   sin el prefijo técnico) frente a resto técnico, y error
///   desconocido. La salida NUNCA contiene «Exception» ni
///   «Future not completed».
/// · Fuente: en los 18 archivos del alcance (17 sitios + los
///   11 de GEN-09), ningún snack/aviso interpola la excepción
///   cruda; cada sitio pasa por mensajeErrorAmable y deja el
///   crudo en AppLog.
/// · D-19 (nominal): MontoAnimado enseña el valor final en el
///   primer montaje, cuenta hacia el nuevo valor al cambiar
///   montado y pinta con cifras tabulares.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ironbody_gym/errores_sync.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('Oleada 8 · mensajeErrorAmable (tabla §9.2 + GEN-09)', () {
    test('timeout sin enTimeout: texto de la tabla', () {
      expect(mensajeErrorAmable(TimeoutException('Future not completed')),
          'Sin respuesta del servidor. Inténtalo de nuevo.');
    });

    test('timeout con enTimeout: manda el texto del llamador', () {
      expect(
          mensajeErrorAmable(TimeoutException('x'),
              enTimeout:
                  'Sin respuesta del servidor; se muestran los datos de tu teléfono'),
          'Sin respuesta del servidor; se muestran los datos de tu teléfono');
    });

    test('red: SocketException y ClientException', () {
      expect(mensajeErrorAmable(const SocketException('Failed host lookup: api.ejemplo.cu')),
          'Sin conexión a internet. Revisa tus datos o el Wi-Fi.');
      expect(mensajeErrorAmable(http.ClientException('Connection closed')),
          'Sin conexión a internet. Revisa tus datos o el Wi-Fi.');
    });

    test('Postgrest P0001: su mensaje pasa tal cual (nace en español)', () {
      expect(
          mensajeErrorAmable(const PostgrestException(
              message: 'El cliente ya tiene un pago hoy', code: 'P0001')),
          'El cliente ya tiene un pago hoy');
    });

    test('Postgrest con otro código: el servidor no aceptó', () {
      expect(
          mensajeErrorAmable(const PostgrestException(
              message: 'permission denied for table x', code: '42501')),
          'El servidor no aceptó la operación. Inténtalo de nuevo.');
    });

    test('GEN-09: StateError de negocio curado pasa sin prefijo', () {
      expect(
          mensajeErrorAmable(StateError(
              'La nómina de octubre ya está liquidada: no se puede anular este adelanto.')),
          'La nómina de octubre ya está liquidada: no se puede anular este adelanto.');
    });

    test('GEN-09: Exception de negocio curado pasa sin «Exception: »', () {
      expect(mensajeErrorAmable(Exception('Solo el dueño puede liquidar entregas de efectivo')),
          'Solo el dueño puede liquidar entregas de efectivo');
      expect(mensajeErrorAmable(Exception('Para rechazar, escribe el motivo')),
          'Para rechazar, escribe el motivo');
    });

    test('StateError técnico o vacío: cae al genérico', () {
      expect(mensajeErrorAmable(StateError('')),
          'Algo salió mal. Inténtalo de nuevo.');
      expect(
          mensajeErrorAmable(
              StateError('Null check operator used on a null value')),
          'Algo salió mal. Inténtalo de nuevo.');
    });

    test('Exception con resto técnico: cae al genérico', () {
      expect(mensajeErrorAmable(Exception('sqflite: database is locked')),
          'Algo salió mal. Inténtalo de nuevo.');
    });

    test('la red manda sobre el envoltorio: un resto de transporte '
        'envuelto en Exception se lee como red', () {
      expect(
          mensajeErrorAmable(
              Exception('ClientException: Connection closed before full header')),
          'Sin conexión a internet. Revisa tus datos o el Wi-Fi.');
    });

    test('error desconocido: genérico de la tabla', () {
      expect(mensajeErrorAmable(ArgumentError('fuera de rango')),
          'Algo salió mal. Inténtalo de nuevo.');
      expect(mensajeErrorAmable(Object()), 'Algo salió mal. Inténtalo de nuevo.');
    });

    test('garantía: la salida nunca trae restos técnicos', () {
      final errores = <Object>[
        TimeoutException('Future not completed after 0:00:12.000000'),
        const SocketException('OS Error: Network is unreachable, errno = 101'),
        const PostgrestException(message: 'stack trace interno', code: 'XX000'),
        StateError(''),
        Exception('Null check operator used on a null value'),
        const FormatException('Unexpected character at 1:5'),
      ];
      for (final e in errores) {
        final t = mensajeErrorAmable(e);
        expect(t.contains('Exception'), isFalse, reason: 'fuga en: $t');
        expect(t.contains('Future not completed'), isFalse, reason: 'fuga en: $t');
        expect(t.contains('errno'), isFalse, reason: 'fuga en: $t');
      }
    });
  });

  group('Oleada 8 · fuente: el alcance no interpola la excepción cruda', () {
    const archivos = [
      'lib/ui/ficha.dart',
      'lib/ui/ficha_acceso.dart',
      'lib/ui/ficha_acceso_app.dart',
      'lib/ui/home.dart',
      'lib/ui/hub_turnos.dart',
      'lib/ui/servicios.dart',
      'lib/ui/detalle_suplemento.dart',
      'lib/ui/venta_suplemento_inscripcion.dart',
      'lib/ui/arqueo.dart',
      'lib/ui/panel_resto_caja.dart',
      'lib/ui/dialogo_gasto.dart',
      'lib/ui/conciliacion.dart',
      'lib/ui/inscribir.dart',
      'lib/ui/nomina.dart',
      'lib/ui/mi_nomina.dart',
      'lib/ui/incidencias/detalle_incidencia.dart',
      'lib/ui/incidencias_sync.dart',
      'lib/ui/solicitudes_adelanto.dart',
    ];
    // Interpolación cruda de la variable del catch en una línea
    // de snack/aviso: «: $e'», «: $err'», «'$e'», «'$err'» o la
    // forma con llaves de la variable sola.
    final crudo = RegExp(r": \$(e|err)'|'\$(e|err)'|:\s*\$\{(e|err)\}");

    for (final ruta in archivos) {
      test('$ruta: ningún snack interpola \$e/\$err crudo', () {
        final lineas = File(ruta).readAsLinesSync();
        for (var i = 0; i < lineas.length; i++) {
          final l = lineas[i];
          final esSnack = l.contains('mostrarSnack(') ||
              l.contains("_snack('") ||
              l.contains("_aviso('") ||
              l.contains('_errorGuardado');
          if (!esSnack) continue;
          if (l.contains('mensajeErrorAmable') || l.contains('AppLog')) continue;
          expect(crudo.hasMatch(l), isFalse,
              reason: '$ruta:${i + 1}: $l');
        }
      });
    }

    test('los 28 sitios del alcance pasan por mensajeErrorAmable y AppLog', () {
      var usosAyudante = 0;
      var usosLog = 0;
      for (final ruta in archivos) {
        final s = File(ruta).readAsStringSync();
        usosAyudante += 'mensajeErrorAmable('.allMatches(s).length;
        usosLog += 'AppLog.error('.allMatches(s).length;
      }
      // 28 sitios: cada uno llama al ayudante una vez y registra
      // el crudo una vez. (AppLog.error puede aparecer además en
      // usos previos del archivo: por eso la cota es >=.)
      expect(usosAyudante, greaterThanOrEqualTo(28),
          reason: 'ayudante: $usosAyudante');
      expect(usosLog, greaterThanOrEqualTo(28), reason: 'log: $usosLog');
    });
  });

  group('Oleada 8 · fuente: literales a tokens (ítems 8 y 9)', () {
    // Recorre lib/ y cuenta renglones por archivo.
    Map<String, int> contar(RegExp re, {Set<String> excluir = const {}}) {
      final out = <String, int>{};
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        if (excluir.contains(e.path)) continue;
        final n = e
            .readAsLinesSync()
            .where((l) => re.hasMatch(l))
            .length;
        if (n > 0) out[e.path] = n;
      }
      return out;
    }

    test('Color(0x: solo quedan las excepciones declaradas', () {
      // diseno.dart es la casa de los tokens: se excluye.
      // Excepciones: cierre_nomina_imagen (la imagen de nomina
      // que se comparte) y vista_previa_cliente (declaradas en
      // la 1.29), componentes (definicion de colorSignificadoChip
      // + fabricas de badge, excepcion de la 1.29) y suplementos
      // (gradiente decorativo de la foto generica, excepcion
      // declarada en esta oleada).
      // 1.30 D1 (COMP-A): las fábricas de IconoModuloBadge
      // migran sus 5 literales a tokens de valor exacto
      // (naranjaTextoOscuro, bannerEnviandoB, exito y los
      // nuevos exitoIconoOscuro/Claro): en componentes solo
      // quedan los 6 de colorSignificadoChip, la excepción
      // real fijada por el test de contraste.
      final conteo = contar(RegExp(r'Color\(0x'),
          excluir: {'lib/ui/diseno.dart'});
      expect(conteo, {
        'lib/ui/cierre_nomina_imagen.dart': 10,
        'lib/ui/componentes.dart': 6,
        'lib/ui/vista_previa_cliente.dart': 9,
        'lib/ui/suplementos.dart': 2,
      });
    });

    test('fontSize literal: solo las excepciones declaradas', () {
      // Fuera: diseno.dart (las definiciones de AppTexto) y
      // cierre_nomina_imagen (excepcion declarada). Dentro,
      // excepciones de esta oleada con su motivo en el informe:
      // 19 de la vista previa de Comunidad, 12.5/11.5 de fotos
      // de progreso, 16 del candado y del cierre de mes, 21 del
      // numero de tarjeta y 11 del detalle tecnico T20.
      final conteo = contar(RegExp(r'fontSize:\s*[0-9]'),
          excluir: {'lib/ui/diseno.dart', 'lib/ui/cierre_nomina_imagen.dart'});
      // 1.32 (Oleada 2 F1): transferencia.dart sale del
      // inventario — su pantalla (la del literal de 21 del
      // número de tarjeta) se retiró sin llamadores y quedan
      // solo funciones puras. Entra marco.dart: 2 (el reloj
      // del Pulso a 10 px, de la Oleada 1): la excepción no
      // se declaró entonces y el test ya venía rojo en la
      // base fb34e6f — se declara ahora, verificado.
      // 1.32 (integración, RD-10): la excepción de
      // marco.dart se RETIRA — las dos cifras a 10 px (las
      // insignias de urgencias) pasaron al token
      // AppTexto.minuscula (11, el mínimo de la escala) y
      // el archivo ya no tiene literales fontSize: cumple
      // sin excepción, que es lo que este pin protege.
      expect(conteo, {
        'lib/ui/panel_comunidad.dart': 1,
        'lib/ui/fotos_progreso_nube_ficha.dart': 2,
        'lib/ui/capa_candado.dart': 1,
        'lib/ui/cierre_mes.dart': 1,
        'lib/ui/vista_previa_cliente.dart': 1,
      });
    });

    test('los tokens nacidos en la oleada existen en diseno.dart', () {
      final d = File('lib/ui/diseno.dart').readAsStringSync();
      for (final t in [
        'whatsapp', 'casaFondo', 'casaIcono', 'casaTexto',
        'doradoPlus', 'comprobanteFondo', 'avisoPanelFondoClaro',
        'avisoPanelFondoOscuro', 'avisoPanelBordeOscuro',
        'sobreNaranjaOscuro', 'errorIconoOscuro', 'azulAguaOscuro',
        'azulAguaClaro', 'resaltadoBusqueda',
      ]) {
        expect(d.contains('static const $t = '), isTrue, reason: t);
      }
    });

    test('residuo *Texto: ningun texto se colorea con el brillante '
        'en los 5 archivos del inventario', () {
      // El brillante es color de relleno o grafico (icono,
      // tinte, borde): como color de TEXTO manda el rol *Texto.
      // Se mira la ventana de cada TextStyle/copyWith por si su
      // color es un brillante directo.
      final brillante =
          RegExp(r'color:\s*AppColores\.(exito|error|alerta|info|naranja|dorado)\b');
      for (final ruta in [
        'lib/ui/ayuda.dart',
        'lib/ui/campana_wa.dart',
        'lib/ui/plantillas_mensaje.dart',
        'lib/ui/capa_candado.dart',
        'lib/ui/editor_foto.dart',
      ]) {
        final s = File(ruta).readAsStringSync();
        for (final marca in ['TextStyle(', '.copyWith(']) {
          var i = 0;
          while (true) {
            final j = s.indexOf(marca, i);
            if (j < 0) break;
            final ventana =
                s.substring(j, j + 160 > s.length ? s.length : j + 160);
            expect(brillante.hasMatch(ventana), isFalse,
                reason: '$ruta: texto con brillante: $ventana');
            i = j + marca.length;
          }
        }
      }
    });
  });

  group('D-19 · totales animados (MontoAnimado)', () {
    Widget envolver(double v) => MaterialApp(
          home: Scaffold(
            body: MontoAnimado(
              valor: v,
              formato: (x) => '${x.round()} CUP',
            ),
          ),
        );

    testWidgets('primer montaje: el valor final, sin cifra a medias',
        (tester) async {
      await tester.pumpWidget(envolver(1500));
      expect(find.text('1500 CUP'), findsOneWidget);
    });

    testWidgets('al cambiar montado, cuenta hasta el nuevo valor',
        (tester) async {
      await tester.pumpWidget(envolver(0));
      expect(find.text('0 CUP'), findsOneWidget);
      await tester.pumpWidget(envolver(1000));
      await tester.pump(const Duration(milliseconds: 150));
      // A mitad de los 300 ms aún no ha llegado al destino.
      expect(find.text('1000 CUP'), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('1000 CUP'), findsOneWidget);
    });

    testWidgets('las cifras son tabulares (el ancho no baila)',
        (tester) async {
      await tester.pumpWidget(envolver(250));
      final texto = tester.widget<Text>(find.byType(Text));
      expect(
          texto.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()));
    });
  });
}
