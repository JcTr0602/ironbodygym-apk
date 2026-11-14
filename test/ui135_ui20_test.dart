/// 1.35 (UI-20): Apariencia reúne tema, letra, vibración,
/// contraste y el nuevo «Reducir movimiento» de la app;
/// el tema se previsualiza en vivo al tocarlo (aplicar
/// sin cerrar, Guardar se lo queda, Cancelar revierte).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ironbody_gym/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Reducir movimiento: notifier, persistencia y '
      'recarga', () async {
    SharedPreferences.setMockInitialValues({});
    await ThemeController.setReducirMovimiento(true);
    expect(ThemeController.reducirMovimiento.value, isTrue);
    ThemeController.reducirMovimiento.value = false;
    await ThemeController.load();
    expect(ThemeController.reducirMovimiento.value, isTrue,
        reason: 'load() relee la preferencia guardada');
    await ThemeController.setReducirMovimiento(false);
    expect(ThemeController.reducirMovimiento.value, isFalse);
  });

  testWidgets('con Reducir movimiento, la MediaQuery de '
      'la raíz nace con disableAnimations', (t) async {
    ThemeController.reducirMovimiento.value = true;
    addTearDown(
        () => ThemeController.reducirMovimiento.value = false);
    var visto = false;
    await t.pumpWidget(MaterialApp(
      builder: (ctx, child) => ValueListenableBuilder<bool>(
        valueListenable: ThemeController.reducirMovimiento,
        builder: (_, reducirMov, __) {
          final mq = MediaQuery.of(ctx);
          return MediaQuery(
            data: mq.copyWith(
                disableAnimations:
                    mq.disableAnimations || reducirMov),
            child: Builder(builder: (c2) {
              visto = MediaQuery.disableAnimationsOf(c2);
              return const SizedBox();
            }),
          );
        },
      ),
      home: const SizedBox(),
    ));
    await t.pump();
    expect(visto, isTrue);
  });

  test('contrato: el ajuste vive en Apariencia y el tema '
      'se previsualiza aplicando', () {
    final aj = File('lib/ui/ajustes.dart').readAsStringSync();
    expect(aj, contains("'Reducir movimiento'"));
    expect(aj, contains("titulo: 'Reducir movimiento'"));
    expect(aj, contains('setReducirMovimiento'));
    expect(aj, contains('StatefulBuilder'));
    expect(aj, contains('se revierte'));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('ThemeController.reducirMovimiento'));
    expect(main, contains('disableAnimations:'));
  });
}
