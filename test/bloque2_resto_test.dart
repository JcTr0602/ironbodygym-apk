/// Tests del Bloque 2 RESTO (1.11.0, Argón AMARILLO).
///
/// Puros (sin BD): C1 delta, C5 transacciones reales + Plus +
/// convertido sin doble conteo, C6 fuente única + monto congelado,
/// F5 bloqueo con cola, G2 candados, H5 aviso, H2 Markdown.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque2_resto.dart';

void main() {
  group('C1 delta (Argón ajuste 1)', () {
    test('liquidar resta el monto exacto, nunca pone pendiente = 0', () {
      expect(pendienteTrasEntregas(5000, 2000), 3000);
      expect(pendienteTrasEntregas(5000, 5000), 0);
    });
    test('un cobro offline que llega DESPUÉS de liquidar no se pierde '
        'ni se descuenta dos veces', () {
      // Antes: pendiente vigente 5000. Se liquidan 2000 → 3000.
      final trasLiquidar = pendienteTrasEntregas(5000, 2000);
      expect(trasLiquidar, 3000);
      // El cobro tardío de 2000 entra sin marcar: el vigente sube a
      // 7000 y la entrega ya registrada (2000) se resta UNA sola vez.
      final trasCobroTardio = pendienteTrasEntregas(7000, 2000);
      expect(trasCobroTardio, 5000);
      // Ni 3000 (cobro tragado por el reseteo) ni 3000 por doble
      // descuento: el cobro está íntegro en el pendiente.
    });
    test('nunca baja de 0 aunque la entrega supere el pendiente', () {
      expect(pendienteTrasEntregas(100, 500), 0);
    });
    test('la op C1 lleva monto_entregado y movimiento de custodia', () {
      final p = payloadLiquidarEntrega(
        entrenadorTelegramId: 1,
        montoEntregado: 2000,
        fechaHoraHabana: '2026-10-24T10:00:00-04:00',
        autorDuenoId: 735772141,
      );
      expect(p['monto_entregado'], 2000);
      expect(p['movimiento'], 'entrega_efectivo_dueno');
      expect(p.containsKey('pendiente'), isFalse);
    });
  });

  group('C5 ingresos por período (Argón ajuste 2)', () {
    test('Plus es línea propia y suma a Transferencias y al Total', () {
      final r = resumenIngresos([
        const FilaIngreso('mensualidades', 'efectivo', 2000, '2026-10-10'),
        const FilaIngreso('plus', 'transferencia', 1000, '2026-10-11'),
      ], '2026-10-01', '2026-10-31');
      expect(r.porConcepto['plus'], 1000);
      expect(r.porConcepto['mensualidades'], 2000);
      expect(r.transferencia, 1000);
      expect(r.efectivo, 2000);
      expect(r.total, 3000);
    });
    test('convertido: diario + completivo suman lo real, sin duplicar', () {
      // El cliente entró con pase diario (200) y luego completó la
      // mensualidad abonando la diferencia (1800). Lo real que entró
      // es 2000. Calcular por estado actual (mensualidad 2000 +
      // diario 200) daría 2200: ese es el error que C5 no comete
      // porque suma transacciones, no fichas.
      final r = resumenIngresos([
        const FilaIngreso('diarios', 'efectivo', 200, '2026-10-05'),
        const FilaIngreso('mensualidades', 'efectivo', 1800, '2026-10-06'),
      ], '2026-10-01', '2026-10-31');
      expect(r.porConcepto['diarios'], 200);
      expect(r.porConcepto['mensualidades'], 1800);
      expect(r.total, 2000);
    });
    test('fuera del rango no suma; los límites son inclusivos', () {
      final r = resumenIngresos([
        const FilaIngreso('mensualidades', 'efectivo', 100, '2026-10-01'),
        const FilaIngreso('mensualidades', 'efectivo', 200, '2026-10-31'),
        const FilaIngreso('mensualidades', 'efectivo', 999, '2026-09-30'),
        const FilaIngreso('mensualidades', 'efectivo', 999, '2026-11-01'),
      ], '2026-10-01', '2026-10-31');
      expect(r.total, 300);
    });
    test('el monto es el congelado de la fila, no el precio actual', () {
      // El estándar subió a 2500, pero el cobro viejo fue de 2000:
      // C5 lee 2000 porque el monto vive en la fila, no se recalcula
      // con calcularPrecioCobro() (que aquí ni se llama).
      final r = resumenIngresos([
        const FilaIngreso('mensualidades', 'efectivo', 2000, '2026-09-10'),
      ], '2026-09-01', '2026-09-30');
      expect(r.total, 2000);
    });
    test('fila espejo: anulada no suma; Casa en dosis no suma', () {
      expect(
          filaIngresoDesdeEspejo('pagos', {
            'monto': 2000,
            'fecha': '2026-10-10',
            'metodo': 'efectivo',
            'anulada': 1,
          }),
          isNull);
      expect(
          filaIngresoDesdeEspejo('servicio_ventas', {
            'precio_unitario': 600,
            'cantidad': 1,
            'fecha': '2026-10-10',
            'metodo': 'efectivo',
            'casa': 1,
            'tipo': 'dosis_sin_agua',
          }),
          isNull);
      final agua = filaIngresoDesdeEspejo('servicio_ventas', {
        'precio_unitario': 300,
        'cantidad': 2,
        'fecha': '2026-10-10',
        'metodo': 'efectivo',
        'tipo': 'agua_suelta',
      });
      expect(agua?.concepto, 'agua');
      expect(agua?.monto, 600);
    });
  });

  group('C6/H1 fuente única (Argón ajuste 3)', () {
    test('C6 tiene todos los precios por método, incluido A++', () {
      for (final k in [
        'mensualidad',
        'mensualidad_menores',
        'transferencia',
        'pago_diario',
        'pago_semanal',
        'pago_quincenal',
        'precio_app_plus',
      ]) {
        expect(kClavesPreciosC6, contains(k));
      }
    });
    test('H1 no duplica ninguna clave de precio de C6', () {
      final interseccion = kClavesPreciosC6
          .toSet()
          .intersection(kClavesAjustesH1.toSet());
      expect(interseccion, isEmpty);
    });
  });

  group('F5 bloqueo con cola (Argón ajuste 4)', () {
    test('re-descargar espejo solo con cola vacía', () {
      expect(puedeRedescargarEspejo(0), isTrue);
      expect(puedeRedescargarEspejo(1), isFalse);
      expect(puedeRedescargarEspejo(27), isFalse);
    });
  });

  group('G2 candados (ajuste 7 del núcleo)', () {
    test('entrenador no crea para otros; dueño sí', () {
      expect(puedeCrearParaOtros(esDueno: false), isFalse);
      expect(puedeCrearParaOtros(esDueno: true), isTrue);
      expect(alcancePermitido('todos', esDueno: false), isFalse);
      expect(alcancePermitido('solo_mio', esDueno: false), isTrue);
    });
    test('masivos solo en el teléfono del dueño y una vez al día', () {
      expect(
          puedeDispararMasivo(
              esTelefonoDueno: false,
              disparadoEnFechaHabana: null,
              hoyHabana: '2026-10-24'),
          isFalse);
      expect(
          puedeDispararMasivo(
              esTelefonoDueno: true,
              disparadoEnFechaHabana: '2026-10-24',
              hoyHabana: '2026-10-24'),
          isFalse);
      expect(
          puedeDispararMasivo(
              esTelefonoDueno: true,
              disparadoEnFechaHabana: null,
              hoyHabana: '2026-10-24'),
          isTrue);
    });
    test('cumpleaños desde carnet 6 dígitos y desde fecha_nac', () {
      expect(esCumpleanosHoy({'carnet': '050317'}, '03-17'), isTrue);
      expect(esCumpleanosHoy({'carnet': '050317'}, '03-18'), isFalse);
      expect(esCumpleanosHoy({'fecha_nac': '2005-03-17'}, '03-17'), isTrue);
      expect(esCumpleanosHoy({}, '03-17'), isFalse);
    });
    test('vencimiento dentro de la ventana (hoy incluido)', () {
      expect(venceEnVentana('2026-10-24', '2026-10-24', 3), isTrue);
      expect(venceEnVentana('2026-10-27', '2026-10-24', 3), isTrue);
      expect(venceEnVentana('2026-10-28', '2026-10-24', 3), isFalse);
      expect(venceEnVentana('2026-10-23', '2026-10-24', 3), isFalse);
      expect(venceEnVentana(null, '2026-10-24', 3), isFalse);
    });
  });

  group('H5 aviso + H2 Markdown', () {
    test('el aviso fijo menciona que no hay restauración y que hay '
        'que sincronizar antes', () {
      expect(kAvisoCopiaFria, contains('no tiene botón de restaurar'));
      expect(kAvisoCopiaFria, contains('sincroniza antes de exportar'));
    });
    test('el resumen Markdown trae ingresos, pagaron y altas/bajas '
        'sin inventar números', () {
      final r = resumenIngresos([
        const FilaIngreso('mensualidades', 'efectivo', 2000, '2026-10-10'),
      ], '2026-10-01', '2026-10-31');
      final md =
          resumenMensualMarkdown(mes: '2026-10', ingresos: r, pagaron: 90);
      expect(md, contains('# Registro mensual — 2026-10'));
      expect(md, contains('Pagaron el mes: 90'));
      expect(md, contains('Altas: — (se dicta en el archivo maestro)'));
    });
  });
}
