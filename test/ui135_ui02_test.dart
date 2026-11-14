/// 1.35 (UI-02): la capa háptica Tacto emite por el canal
/// de plataforma solo cuando el ajuste «Vibración» está
/// activo; apagado, ninguna intención vibra.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/primitivas.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final llamadas = <String>[];

  setUp(() {
    llamadas.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      llamadas.add(call.method);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    Tacto.fijarHabilitado(true);
  });

  test('con el ajuste activo, cada intención vibra', () {
    Tacto.fijarHabilitado(true);
    Tacto.seleccion();
    Tacto.ligero();
    Tacto.confirmacion();
    Tacto.exito();
    Tacto.error();
    expect(llamadas.length, 5);
    expect(llamadas.every((m) => m.contains('HapticFeedback')), isTrue);
  });

  test('con el ajuste apagado, ninguna intención vibra', () {
    Tacto.fijarHabilitado(false);
    Tacto.seleccion();
    Tacto.ligero();
    Tacto.confirmacion();
    Tacto.exito();
    Tacto.error();
    expect(llamadas, isEmpty);
  });
}
