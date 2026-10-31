import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bloque3.dart';

void main() {
  test('destinatario null = todos', () {
    const a = AvisoEntrenador(id: 'x', titulo: 'T', mensaje: 'M');
    expect(a.destinatarioTelegramId, isNull);
    expect(
        a.visiblePara(esDueno: false, miTelegramId: 969869611), isTrue);
    expect(nombreDestinoAviso(null), 'Todos');
  });

  test('fromMirror parsea int y string', () {
    final a = AvisoEntrenador.fromMirror({
      'id': 'x',
      'titulo': 'T',
      'destinatario_telegram_id': 969869611,
    });
    expect(a.destinatarioTelegramId, 969869611);
    final b = AvisoEntrenador.fromMirror({
      'id': 'x',
      'titulo': 'T',
      'destinatario_telegram_id': '1403501391',
    });
    expect(b.destinatarioTelegramId, 1403501391);
  });

  test('el entrenador ajeno no ve el aviso, el dueño sí', () {
    const a = AvisoEntrenador(
        id: 'x',
        titulo: 'T',
        mensaje: 'M',
        destinatarioTelegramId: 969869611);
    expect(
        a.visiblePara(esDueno: false, miTelegramId: 1403501391), isFalse);
    expect(
        a.visiblePara(esDueno: false, miTelegramId: 969869611), isTrue);
    expect(a.visiblePara(esDueno: true, miTelegramId: 735772141), isTrue);
    expect(nombreDestinoAviso(969869611), 'Duany');
  });

  test('Argón avisos #2: sesión sin telegram_id no ve dirigidos', () {
    const dirigido = AvisoEntrenador(
        id: 'x',
        titulo: 'T',
        mensaje: 'M',
        destinatarioTelegramId: 969869611);
    expect(
        dirigido.visiblePara(esDueno: false, miTelegramId: null), isFalse);
    const general = AvisoEntrenador(id: 'x', titulo: 'T', mensaje: 'M');
    expect(
        general.visiblePara(esDueno: false, miTelegramId: null), isTrue);
  });

  test('Argón avisos #4: copyWith puede limpiar a Todos', () {
    const a = AvisoEntrenador(
        id: 'x',
        titulo: 'T',
        mensaje: 'M',
        destinatarioTelegramId: 969869611);
    expect(a.copyWith(limpiarDestinatario: true).destinatarioTelegramId,
        isNull);
    expect(a.copyWith().destinatarioTelegramId, 969869611);
    expect(
        a
            .copyWith(destinatarioTelegramId: 1403501391)
            .destinatarioTelegramId,
        1403501391);
    expect(a.copyWith(activo: false).destinatarioTelegramId, 969869611);
  });

  test('toJson round-trip conserva destinatario', () {
    const a = AvisoEntrenador(
        id: 'x',
        titulo: 'T',
        mensaje: 'M',
        destinatarioTelegramId: 1403501391);
    final b = AvisoEntrenador.fromMirror(a.toJson());
    expect(b.destinatarioTelegramId, 1403501391);
    const c = AvisoEntrenador(id: 'x', titulo: 'T', mensaje: 'M');
    expect(c.toJson().containsKey('destinatario_telegram_id'), isFalse);
  });
}
