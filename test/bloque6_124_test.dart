// Tests 1.24 Bloque 6 (ítem 8): regla de atribución de la
// actividad reciente para entrenadores (Argón): mensualidades
// e inscripciones se ven si YO registré la acción O si el
// cliente es MÍO (lo inscribí yo), lo haya cobrado quien sea;
// los pagos diarios de otros NO se ven nunca.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  const yo = 'Gabriel';
  const miTelegram = 1403501391;

  Map<String, dynamic> item(String accion, String actor) => {
        'accion': accion,
        'actor': actor,
        'cliente_id': 42,
      };

  final clienteMioNum = <String, dynamic>{
    'id': 42,
    'registrado_por': miTelegram,
    'registrado_por_nombre': 'Gabriel',
  };
  final clienteMioNombre = <String, dynamic>{
    'id': 42,
    'registrado_por_nombre': 'Gabriel',
  };
  final clienteDeOtro = <String, dynamic>{
    'id': 42,
    'registrado_por': 969869611,
    'registrado_por_nombre': 'Duany',
  };
  final clienteSinFirma = <String, dynamic>{'id': 42};

  group('ítem 8: atribución de actividad', () {
    test('mi propio pago diario se ve', () {
      expect(
        actividadVisibleParaEntrenador(item('pago_diario', yo),
            cliente: clienteDeOtro,
            miActor: yo,
            miTelegramId: miTelegram),
        isTrue,
      );
    });

    test('pago diario de OTRO no se ve aunque el cliente sea mío',
        () {
      expect(
        actividadVisibleParaEntrenador(item('pago_diario', 'Duany'),
            cliente: clienteMioNum,
            miActor: yo,
            miTelegramId: miTelegram),
        isFalse,
      );
    });

    test('mensualidad de mi cliente cobrada por el dueño se ve '
        '(firma numérica)', () {
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Jc'),
            cliente: clienteMioNum,
            miActor: yo,
            miTelegramId: miTelegram),
        isTrue,
      );
    });

    test('mensualidad de mi cliente cobrada por otro se ve '
        '(firma por nombre)', () {
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Duany'),
            cliente: clienteMioNombre,
            miActor: yo,
            miTelegramId: miTelegram),
        isTrue,
      );
    });

    test('mensualidad de cliente de otro no se ve', () {
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Duany'),
            cliente: clienteDeOtro,
            miActor: yo,
            miTelegramId: miTelegram),
        isFalse,
      );
    });

    test('inscripción de mi cliente hecha por otro se ve', () {
      expect(
        actividadVisibleParaEntrenador(
            item('inscripcion', 'Duany'),
            cliente: clienteMioNum,
            miActor: yo,
            miTelegramId: miTelegram),
        isTrue,
      );
    });

    test('cliente sin firma no se acredita a nadie (fail-closed)',
        () {
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Duany'),
            cliente: clienteSinFirma,
            miActor: yo,
            miTelegramId: miTelegram),
        isFalse,
      );
    });

    test('sin fila de cliente no hay atribución posible', () {
      expect(
        actividadVisibleParaEntrenador(item('pago_mensual', 'Duany'),
            cliente: null, miActor: yo, miTelegramId: miTelegram),
        isFalse,
      );
    });

    test('venta de suplemento de otro no entra por la vía del '
        'cliente', () {
      expect(
        actividadVisibleParaEntrenador(
            item('venta_suplemento', 'Duany'),
            cliente: clienteMioNum,
            miActor: yo,
            miTelegramId: miTelegram),
        isFalse,
      );
    });
  });
}
