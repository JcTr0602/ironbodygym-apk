// SL-2 (Ficha) — Lote siguiente 1.35: fichas G03-1..G03-14.
// Tests discriminantes: en la base ead3d63 fallan (rojo);
// con las correcciones pasan (verde). Solo se usan APIs
// públicas preexistentes para los widgets (TarjetaMedidas,
// SeccionFotoPersonal, SeccionAccesoAppFicha) y los
// traductores nuevos de cada ficha para el resto.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:ironbody_gym/ui/ficha.dart' show etiquetaSexoFicha, etiquetaMetodoPagoFicha;
import 'package:ironbody_gym/ui/medidas_cliente.dart';
import 'package:ironbody_gym/ui/auditoria_persona.dart' show fechaLegibleAuditoria;
import 'package:ironbody_gym/ui/vista_previa_cliente.dart' show etiquetaEstadoVistaPrevia;
import 'package:ironbody_gym/ui/ficha_acceso.dart' show etiquetaAccionAcceso;
import 'package:ironbody_gym/ui/ficha_congelacion.dart' show mensajeCierreCongelacionFallido;
import 'package:ironbody_gym/ui/foto_personal_ficha.dart';
import 'package:ironbody_gym/ui/ficha_acceso_app.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  // Arnés mínimo de la casa (patrón argon_125_126): los
  // widgets de la ficha consultan AuthService, que exige
  // Supabase inicializado aunque no haya sesión.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(url: 'http://127.0.0.1:9', publishableKey: 'dummy');
  });

  group('G03-4 sexo traducido', () {
    test('M → Masculino, F → Femenino, nunca la clave cruda', () {
      expect(etiquetaSexoFicha('M'), 'Masculino');
      expect(etiquetaSexoFicha('F'), 'Femenino');
      expect(etiquetaSexoFicha(null), '—');
    });
  });

  group('G03-6 método del histórico traducido', () {
    test('claves de método → etiquetas', () {
      expect(etiquetaMetodoPagoFicha('efectivo'), 'Efectivo');
      expect(etiquetaMetodoPagoFicha('transferencia'), 'Transferencia');
      expect(etiquetaMetodoPagoFicha('cortesia'), 'Cortesía');
    });
    test('la ficha ya no pinta el periodo crudo en el histórico', () {
      final s = _src('lib/ui/ficha.dart');
      expect(s.contains("\${p['periodo'] ?? 'mensual'}"), isFalse);
      expect(s.contains('etiquetaPeriodo(p)'), isTrue);
    });
  });

  group('G03-5 historial de medidas formateado', () {
    testWidgets('fecha legible y valor con nombre y formato', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: TarjetaMedidas(clienteId: 1, medidasIniciales: [
            {
              'fecha_medicion': '2026-11-05',
              'espejado': true,
              'medidas': {'peso_kg': 80.0},
            },
          ]),
        ),
      ));
      await t.pump();
      await t.tap(find.textContaining('Ver todo'));
      await t.pump();
      expect(find.text('05/11/2026'), findsWidgets);
      expect(find.textContaining('Peso: 80,0'), findsWidgets);
      expect(find.text('2026-11-05'), findsNothing);
      // F02-HD (z17_tests_sl2-4): la prohibición cubre la
      // clase, no solo el Text exacto: ningún texto puede
      // CONTENER la ISO cruda, ni con prefijo («Inicio:
      // 2026-11-05») ni con sufijo.
      expect(find.textContaining('2026-11-05'), findsNothing,
          reason: 'G03-5: la fecha cruda no se pinta ni '
              'acompañada: siempre 05/11/2026');
    });
  });

  group('G03-7 auditoría por persona en fecha legible', () {
    test('ISO → fecha legible, no substring crudo', () {
      expect(fechaLegibleAuditoria('2026-11-05T08:30:00'), '05/11/2026');
      expect(fechaLegibleAuditoria('2026-11-05'), '05/11/2026');
    });
  });

  group('G03-8 vista previa: estado traducido', () {
    test('claves conocidas traducidas; desconocida no se pinta cruda', () {
      expect(etiquetaEstadoVistaPrevia('activo'), 'Activo');
      expect(etiquetaEstadoVistaPrevia('congelado'), 'Congelado');
      expect(etiquetaEstadoVistaPrevia('inactivo'), 'Inactivo');
      expect(etiquetaEstadoVistaPrevia('clave_nueva_rara'), isNot('clave_nueva_rara'));
    });
    test('la vista previa no pinta el detalle crudo de la excepción', () {
      final s = _src('lib/ui/vista_previa_cliente.dart');
      expect(s.contains('Text(_errorDetalle!'), isFalse);
    });
    test('ninguna asignación a _error salta el traductor amable', () {
      final s = _src('lib/ui/vista_previa_cliente.dart');
      // F02-HD (z17_tests_sl2-5): la clase entera, no un
      // literal: la pantalla pinta Text(_error!), así que lo
      // que hay que fijar es el ORIGEN — _error solo puede
      // nacer de mensajeErrorAmable, de un literal amable o
      // de null. Un `_error = e.toString()` o `_error = '$e'`
      // pintaría el crudo sin contener el literal histórico.
      final asignaciones =
          RegExp(r'_error\s*=\s*([^;]+);').allMatches(s);
      expect(asignaciones, isNotEmpty,
          reason: 'control: la pantalla sí asigna su error');
      for (final m in asignaciones) {
        final rhs = m.group(1)!.trim();
        expect(
            rhs == 'null' ||
                rhs.startsWith("'") ||
                rhs.startsWith('"') ||
                rhs.contains('mensajeErrorAmable'),
            isTrue,
            reason: 'G03-8: «_error = $rhs» pintaría un error '
                'crudo: debe pasar por mensajeErrorAmable o '
                'ser un texto amable literal');
      }
    });
  });

  group('G03-9 corregir pago con CampoFecha', () {
    test('el diálogo usa el selector de la casa y no pide ISO tecleado', () {
      final s = _src('lib/ui/ficha.dart');
      expect(s.contains('Fecha (AAAA-MM-DD)'), isFalse);
      final i = s.indexOf('class _DialogoEditarPagoFicha');
      expect(i, greaterThan(0));
      expect(s.substring(i).contains('CampoFecha('), isTrue);
    });
    test('sin validación RegExp de fecha ISO en la corrección', () {
      final s = _src('lib/ui/ficha.dart');
      expect(s.contains(r"RegExp(r'^\d{4}-\d{2}-\d{2}$')"), isFalse);
    });
  });

  group('G03-10 foto personal: no afirmar «sin conexión» sin saberlo', () {
    testWidgets('un fallo que no es de red se lee genérico-amable', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: SeccionFotoPersonal(clienteId: 1)),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('sin conexión para verificar'), findsNothing);
      expect(find.textContaining('no se pudo verificar'), findsWidgets);
    });
  });

  group('G03-11 cierre de congelación amable', () {
    test('el error del servidor no se pinta crudo en el snack', () {
      final m = mensajeCierreCongelacionFallido('23514: duplicate key raw');
      expect(m, isNot(contains('23514')));
      expect(m, contains('No se pudo cerrar'));
    });
    test('la rama else del cierre no interpola res[error] crudo', () {
      final s = _src('lib/ui/ficha_congelacion.dart');
      expect(s.contains("_snack('\${res['error']"), isFalse);
    });
    test('ningún _snack del cierre interpola res[error] sin traductor', () {
      final s = _src('lib/ui/ficha_congelacion.dart');
      // F02-HD (z17_tests_sl2-5): la clase entera, no un
      // literal: CUALQUIER _snack(...) cuyo argumento
      // mencione res['error'] debe envolverlo en
      // mensajeCierreCongelacionFallido. Variantes como
      // _snack('Error: ${res['error']}') quedan cazadas
      // aunque no contengan el literal histórico, y los
      // textos amables sembrados no disparan la regla
      // (no mencionan res['error'] a pelo).
      final llamadas = RegExp(r'_snack\(([^)]*)\)').allMatches(s);
      expect(llamadas, isNotEmpty,
          reason: 'control: la pantalla sí presenta snacks');
      for (final m in llamadas) {
        final arg = m.group(1)!;
        if (arg.contains("res['error']")) {
          expect(arg, contains('mensajeCierreCongelacionFallido'),
              reason: 'G03-11: res[error] solo llega al snack '
                  'traducido, nunca crudo: _snack($arg…)');
        }
      }
    });
  });

  group('G03-12 auditoría de acceso: clave desconocida no se pinta', () {
    test('conocidas traducidas; inventada → genérico', () {
      expect(etiquetaAccionAcceso('bloquear'), 'Bloqueo');
      expect(etiquetaAccionAcceso('accion_nueva_del_servidor'), 'Acción registrada');
    });
  });

  // G03-13 DESBLOQUEADA (Jc aprobó el paquete, 2026-11-17;
  // Yunque Exhaustivo): el contrato de
  // correccion_campo2_editar_test.dart se actualizó a la
  // conducta nueva y el sufijo se retiró de la ficha.
  group('G03-13 snacks sin sufijo de sync', () {
    test('ningún snack de guardado lleva «(se sincronizará/n)»', () {
      final s = _src('lib/ui/ficha.dart');
      expect(s.contains('(se sincronizará)'), isFalse);
      expect(s.contains('(se sincronizarán)'), isFalse);
    });
  });

  // G03-1 DESBLOQUEADA (Jc aprobó el paquete, 2026-11-17;
  // Yunque Exhaustivo): los tres contratos que tocaban el
  // botón por «Registrar pago» se actualizaron a «Cobrar» y
  // el pie de la ficha se renombró.
  group('G03-1 la acción se llama Cobrar', () {
    test('ningún «Registrar pago» en la ficha', () {
      final s = _src('lib/ui/ficha.dart');
      expect(s.contains("'Registrar pago'"), isFalse);
      expect(s.contains('texto: \'Cobrar\''), isTrue);
    });
  });

  group('G03-2 acciones ocasionales de acceso plegadas', () {
    test('hay un plegable «Más acciones» en la sección de acciones', () {
      final s = _src('lib/ui/ficha_acceso.dart');
      expect(s.contains('Más acciones'), isTrue);
      expect(s.contains('ExpansionTile'), isTrue);
    });
  });

  group('G03-14 filas de datos con FilaInfoFicha', () {
    test('ficha_acceso usa FilaInfoFicha de la casa', () {
      final s = _src('lib/ui/ficha_acceso.dart');
      expect(s.contains('FilaInfoFicha('), isTrue);
    });
  });

  group('G03-3 salidas secundarias de Acceso App degradadas', () {
    testWidgets('ninguna salida secundaria es botón a ancho completo', (t) async {
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SeccionAccesoAppFicha(
              clienteId: 999999,
              nombreCliente: 'Prueba',
              telefonoEfectivoWa: '',
            ),
          ),
        ),
      ));
      await t.pump();
      for (final txt in ['Vista previa App']) {
        final f = find.widgetWithText(OutlinedButton, txt);
        expect(f, findsNothing, reason: '$txt no debe ser OutlinedButton principal');
        expect(find.text(txt), findsWidgets);
      }
    });
  });
}
