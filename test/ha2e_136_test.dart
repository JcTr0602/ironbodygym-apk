// H-A2 (1.36) — contratos de fuente: 136-806 (bonos históricos),
// 136-846 (previas de tarifa en espejo), 136-954 (editor
// GymPedia), 136-1052 (recibos sin anulados) y 136-1068
// (guardas canónicas del pendiente).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String src(String p) => File(p).readAsStringSync();

void main() {
  group('136-806 migración de bonos solo en el mes en curso', () {
    test('mes histórico lee sin migrar claves legacy', () {
      final s = src('lib/nomina_foto.dart');
      expect(
          s.contains('leerBonosMesConMigracion('),
          isTrue);
      final i = s.indexOf('Future<List<Map<String, dynamic>>> leerBonosMesConMigracion(');
      final seg = s.substring(i, i + 900);
      expect(seg.contains('pref != prefActual'), isTrue);
      expect(seg.contains('BonosNominaService.instance.leerBonos(pref)'),
          isTrue);
    });
  });

  group('136-846 previa del espejo con copia local se inactiva', () {
    test('sin continue seco: update activa=0 + historial local', () {
      final s = src('lib/tarifa_especial.dart');
      final i = s.indexOf('for (final f in previasEspejo)');
      final seg = s.substring(i, i + 1600);
      expect(seg.contains('yaLocal.isNotEmpty'), isTrue);
      expect(seg.contains("'activa': 0"), isTrue);
      expect(seg.contains("'actualizada_ts': ts"), isTrue);
      expect(seg.contains('histLocal'), isTrue);
    });
  });

  group('136-954 editor GymPedia ocupado', () {
    test('PopScope no sale con operación en curso', () {
      final s = src('lib/ui/gympedia_editor.dart');
      final i = s.indexOf('onPopInvokedWithResult');
      final seg = s.substring(i, i + 700);
      expect(seg.contains('if (_ocupado)'), isTrue);
      expect(seg.contains('Espera a que termine la operación'), isTrue);
      // la salida directa ya no incluye el caso ocupado
      expect(seg.contains('!_sucio || _ocupado'), isFalse);
    });
    test('guardar y retirar corren como operación (_ocupado)', () {
      final s = src('lib/ui/gympedia_editor.dart');
      expect(s.contains('Future<void> _guardarBorradorFlujo()'), isTrue);
      final i = s.indexOf('Future<void> _guardarBorrador() async {');
      expect(s.substring(i, i + 500).contains('if (_ocupado) return;'),
          isTrue);
      final j = s.indexOf('Future<void> _retirar() async {');
      expect(s.substring(j, j + 400).contains('if (_ocupado) return;'),
          isTrue);
    });
    test('selectores remontan con la revisión recargada', () {
      final s = src('lib/ui/gympedia_editor.dart');
      expect(s.contains("ValueKey('gym-cat-\$_baseRevision')"), isTrue);
      expect(s.contains("ValueKey('gym-sello-\$_baseRevision')"), isTrue);
      expect(s.contains("ValueKey('gym-nivel-\$_baseRevision')"), isTrue);
    });
  });

  group('136-1052 recibos de hoy sin pagos anulados', () {
    test('avisosWhatsappHoy filtra espejo y cola con anulados', () {
      final s = src('lib/negocio.dart');
      final i = s.indexOf('avisosWhatsappHoy() async {');
      final seg = s.substring(i, s.indexOf('W8 (1.20)', i));
      expect(seg.contains('anuladosColaRecibos'), isTrue);
      expect(seg.contains('esPagoAnulado(p, anuladosColaRecibos)'),
          isTrue);
      expect(seg.contains('anuladosColaRecibos.contains(pagoIdOp)'),
          isTrue);
    });
  });

  group('136-1068 guardas canónicas en cifras de pendiente', () {
    test('antiguedadPendiente excluye anulado/casa/dueño/liquidado',
        () {
      final s = src('lib/negocio.dart');
      final i = s.indexOf('antiguedadPendiente(');
      final seg = s.substring(i, s.indexOf('entregasRecientes', i));
      expect(seg.contains('esPagoAnulado(p, anuladosColaA)'), isTrue);
      expect(seg.contains('_esPagoCasa(p, casasA)'), isTrue);
      expect(seg.contains('AuthService.esDelDueno(tidP)'), isTrue);
      expect(seg.contains('esPagoDiarioEfectivo(d)'), isTrue);
    });
    test('pendienteDetalleHoy excluye casa y dueño', () {
      final s = src('lib/negocio.dart');
      final i = s.indexOf('pendienteDetalleHoy(');
      final seg = s.substring(i, s.indexOf('cobradoMes', i));
      expect(seg.contains('_esPagoCasa(p, casasHoy)'), isTrue);
      expect(seg.contains('AuthService.esDelDueno(tidH)'), isTrue);
      expect(seg.contains('AuthService.esDelDueno(tidDiario)'), isTrue);
    });
    test('entregadoHoy excluye Casa', () {
      final s = src('lib/negocio.dart');
      final i = s.indexOf('entregadoHoy() async {');
      final seg = s.substring(i, s.indexOf('_diaEntrega', i));
      expect(seg.contains('_esPagoCasa(p, casasE)'), isTrue);
    });
  });
}
