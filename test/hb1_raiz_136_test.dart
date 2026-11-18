/// H-B1 (1.36): familias raíz 136-319 … 136-323
/// (contratos de fuente).
///
/// Fuente: cola-123/hy4_ui_135_08/cruce/ENRUTADOS.md.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

void main() {
  group('136-319 · el error de carga no se rotula «Sin conexión»', () {
    test('invitados: avisos neutros al fallar la actualización', () {
      final s = _src('lib/ui/invitados.dart');
      expect(s, contains('No se pudo actualizar: se muestra la'));
      expect(s, contains('No se pudo actualizar: se mantiene la'));
    });
    test('reservas: refresco fallido con mensaje neutro', () {
      final s = _src('lib/ui/reservas.dart');
      expect(s, contains("'No se pudo actualizar: mostrando datos locales'"));
      expect(s, isNot(contains('Sin conexión: mostrando datos locales')));
    });
    test('fotos de la nube: sin atribuir a la conexión', () {
      final s = _src('lib/ui/fotos_progreso_nube_ficha.dart');
      expect(s, contains('No se pudieron verificar sus fotos en'));
      expect(s, isNot(contains('Sin conexión: no se pudieron verificar')));
    });
    test('adopción: sin «Revisa la conexión»', () {
      final s = _src('lib/ui/estadisticas_adopcion.dart');
      expect(s, isNot(contains('Revisa la conexión')));
    });
    test('actividad: Postgrest se clasifica antes de rotular', () {
      final s = _src('lib/ui/actividad_cliente.dart');
      expect(s, contains('_errorServidor = e is PostgrestException'));
      expect(s, contains('No se pudo actualizar la actividad.'));
    });
  });

  group('136-320 · launchUrl con el bool comprobado', () {
    test('modal del PIN', () {
      expect(_src('lib/ui/modal_pin_acceso.dart'),
          contains('final ok = await launchUrl'));
    });
    test('ficha: las tres aperturas de WhatsApp', () {
      final s = _src('lib/ui/ficha.dart');
      expect('final ok ='.allMatches(s).length, greaterThanOrEqualTo(3));
    });
    test('cumpleaños: el false cuenta como fallo', () {
      final s = _src('lib/ui/cumpleanos.dart');
      expect('ok = false;'.allMatches(s).length, greaterThanOrEqualTo(2));
    });
    test('buscar / arqueo / actividad', () {
      expect(_src('lib/ui/buscar.dart'), contains('tel:+53'));
      expect(_src('lib/ui/buscar.dart'),
          contains('No se pudo abrir el marcador.'));
      expect(_src('lib/ui/arqueo.dart'),
          contains('copia el resumen y pégalo allí'));
      expect(_src('lib/ui/actividad.dart'),
          contains('ok = await launchUrl'));
    });
  });

  group('136-321 · los diálogos validan dentro', () {
    test('teléfono: errorText + autofocus + done', () {
      final s = _src('lib/ui/dialogo_telefono.dart');
      expect(s, contains('errorText: _error'));
      expect(s, contains('autofocus: true'));
      expect(s, contains('TextInputAction.done'));
      expect(s, contains("labelText: 'Teléfono'"));
    });
    test('servicios admin: validación en los 4 diálogos', () {
      final s = _src('lib/ui/servicios_admin.dart');
      expect(s, contains('El principal solo tiene'));
      expect(s, contains('_errorCosto'));
      expect(s, contains('Solo hay'));
      expect(s, contains('Costo no válido: déjalo vacío'));
    });
    test('motivo de revocación obligatorio dentro', () {
      expect(_src('lib/ui/tarifas_especiales.dart'),
          contains('El motivo es obligatorio.'));
    });
    test('adelantos: pedir y rechazar validan dentro', () {
      expect(_src('lib/ui/mi_nomina.dart'), contains('_errorMonto'));
      expect(_src('lib/ui/solicitudes_adelanto.dart'),
          contains('El motivo del rechazo es obligatorio.'));
    });
    test('ajustes: texto/campo/clave/PIN validan dentro', () {
      final s = _src('lib/ui/ajustes.dart');
      expect(s, contains('validar: (t) => t.trim().length > 60'));
      expect(s, contains('_errorNueva2'));
      expect(s, contains('_errorPin1'));
    });
  });

  group('136-322 · SegmentedButton con guarda de selección vacía', () {
    for (final f in [
      'lib/ui/servicios_estadisticas.dart',
      'lib/ui/ranking_servicios.dart',
      'lib/ui/reservas.dart',
      'lib/ui/incidencias_sync.dart',
    ]) {
      test(f, () {
        expect(_src(f), contains('if (s.isEmpty) return;'));
      });
    }
    test('reservas: sin métodos aceptados no se abre el cobro', () {
      expect(_src('lib/ui/reservas.dart'),
          contains('No hay métodos de pago aceptados en los ajustes'));
    });
  });

  group('136-323 · CruceEstados en la ficha de acceso', () {
    test('ficha_acceso: el cuerpo cruza por estado', () {
      final s = _src('lib/ui/ficha_acceso.dart');
      expect(s, contains('body: CruceEstados('));
      expect(s, contains("'cache'"));
    });
    test('acceso app: el contenido cruza por rama', () {
      final s = _src('lib/ui/ficha_acceso_app.dart');
      expect(s, contains('CruceEstados('));
      expect(s, contains("'sin-conexion'"));
    });
    test('adopción ya cruzaba (instancia GC-063 cubierta)', () {
      expect(_src('lib/ui/estadisticas_adopcion.dart'),
          contains('body: CruceEstados('));
    });
  });
}
