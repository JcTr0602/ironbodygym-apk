// H-A2 (1.36) — contratos de fuente: 136-776 (guardas GD-007),
// 136-796 (tarifa GD-028), 136-802 (triestado de carga) y
// 136-861 (cola de autoguardado).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String src(String p) => File(p).readAsStringSync();

void main() {
  group('136-776 guardas síncronas antes del primer await', () {
    test('hub _cerrar entra con guarda _procesando', () {
      final s = src('lib/ui/hub_turnos.dart');
      final i = s.indexOf('Future<void> _cerrar() async {');
      expect(s.substring(i, i + 200).contains('if (_procesando) return;'),
          isTrue);
    });
    test('mi_nomina marca _confirmando ANTES del diálogo', () {
      final s = src('lib/ui/mi_nomina.dart');
      final i = s.indexOf('Future<void> _confirmarRecepcion(');
      final seg = s.substring(i, i + 500);
      expect(seg.indexOf('_confirmando = true;'),
          lessThan(seg.indexOf('DialogoApp.confirmar')));
    });
    test('cierre_mes _confirmarManual con _operando y finally', () {
      final s = src('lib/ui/cierre_mes.dart');
      expect(s.contains('bool _operando = false;'), isTrue);
      final i = s.indexOf('Future<void> _confirmarManual(');
      final seg = s.substring(i, i + 300);
      expect(seg.contains('if (_operando) return;'), isTrue);
      expect(seg.contains('_operando = true;'), isTrue);
    });
    test('admin_secciones: cobros e invitados con _operando', () {
      final s = src('lib/ui/admin_secciones.dart');
      expect(s.contains('bool _operandoCobros = false;'), isTrue);
      expect(s.contains('bool _operandoUmbral = false;'), isTrue);
      expect(s.contains('if (_operandoCobros) return;'), isTrue);
      expect(s.contains('if (_operandoUmbral) return;'), isTrue);
    });
    test('errores sync: acciones con guarda por clave en curso', () {
      final s = src('lib/ui/panel_resto_sistema.dart');
      expect(s.contains('final Set<String> _enCurso = {};'), isTrue);
      expect(s.contains('Future<void> _reintentarOp('), isTrue);
      expect(s.contains('Future<void> _descartarHuerfana('), isTrue);
      expect(s.contains('if (_enCurso.contains(clave)) return;'), isTrue);
    });
    test('nomina: apertura de Cierre de mes con _operando', () {
      final s = src('lib/ui/nomina.dart');
      final i = s.indexOf('Cierre de mes');
      expect(i, greaterThan(0));
      final seg = s.substring(i, i + 500);
      expect(seg.contains('if (_operando) return;'), isTrue);
    });
  });

  group('136-796 tarifa de nómina sin 150 silencioso', () {
    test('_guardarTarifa usa montoTolerante y no ?? 150', () {
      final s = src('lib/ui/nomina.dart');
      final i = s.indexOf('Future<void> _guardarTarifa() async {');
      final seg = s.substring(i, i + 700);
      expect(seg.contains('montoTolerante(texto)'), isTrue);
      expect(seg.contains('?? 150'), isFalse);
      expect(seg.contains('tarifa == null'), isTrue);
    });
  });

  group('136-802 triestado carga/éxito/fallo', () {
    final casos = <String, String>{
      'lib/ui/nomina.dart': 'No se pudo cargar la nómina',
      'lib/ui/mi_nomina.dart': 'No se pudo cargar tu nómina',
      'lib/ui/solicitudes_adelanto.dart': "'error'",
      'lib/ui/tarifas_especiales.dart': 'No se pudieron cargar las tarifas',
      'lib/ui/congelados.dart': 'No se pudieron cargar los congelados',
      'lib/ui/riesgo.dart': 'No se pudieron cargar los clientes en riesgo',
      'lib/ui/usuarios.dart': 'No se pudieron cargar los usuarios',
      'lib/ui/papelera.dart': 'No se pudo cargar la papelera',
      'lib/ui/admin_secciones.dart': 'No se pudieron buscar',
      'lib/ui/panel_resto_sistema.dart':
          'No se pudieron cargar los errores de sync',
      'lib/ui/panel_bloque2.dart': 'No se pudo cargar',
      'lib/ui/panel_resto_caja.dart': 'No se pudo cargar esta pantalla',
      'lib/ui/panel_resto_config.dart':
          'No se pudo cargar el registro mensual',
    };
    casos.forEach((ruta, texto) {
      test('$ruta declara _errorCarga y pinta EstadoError', () {
        final s = src(ruta);
        expect(s.contains('String? _errorCarga;'), isTrue, reason: ruta);
        expect(s.contains('EstadoError('), isTrue, reason: ruta);
        expect(s.contains(texto), isTrue, reason: ruta);
      });
    });
  });

  group('136-861 autoguardado de precios sin descarte silencioso', () {
    test('cola por clave + aviso + drenaje al terminar', () {
      final s = src('lib/ui/panel_resto_caja.dart');
      expect(s.contains('final Set<String> _colaAutoguardar = {};'),
          isTrue);
      expect(s.contains('_colaAutoguardar.add(k)'), isTrue);
      expect(s.contains('se guarda enseguida'), isTrue);
      expect(s.contains('unawaited(_autoguardar(sig))'), isTrue);
    });
  });
}
