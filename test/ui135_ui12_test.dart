/// 1.35 (UI-12, oleada 1): cinco diálogos de las
/// pantallas principales pasan a DialogoApp (dos de la
/// cáscara: cierre automático y acceso suspendido; tres
/// de Listas: quitar vista, confirmar envío de WhatsApp
/// y guardar vista). Aquí: el flujo de confirmar de la
/// casa y el contrato de migración.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/ui/componentes.dart';

void main() {
  testWidgets('DialogoApp.confirmar: Cancelar devuelve '
      'false y Quitar devuelve true', (t) async {
    bool? res;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              res = await DialogoApp.confirmar(
                ctx,
                titulo: 'Quitar vista',
                mensaje: '¿Quitar la vista «X» (todas)?',
                aceptar: 'Quitar',
              );
            },
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    expect(find.text('Quitar vista'), findsOneWidget);
    await t.tap(find.text('Cancelar'));
    await t.pumpAndSettle();
    expect(res, isFalse);
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    await t.tap(find.text('Quitar'));
    await t.pumpAndSettle();
    expect(res, isTrue);
  });

  testWidgets('DialogoApp pinta título, contenido y '
      'acciones con su forma de la casa', (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () => showDialog(
              context: ctx,
              builder: (_) => DialogoApp(
                titulo: 'Cierre automático',
                contenido: const Text('Se cerró por horario.'),
                acciones: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Todo en orden')),
                ],
              ),
            ),
            child: const Text('abrir'),
          ),
        ),
      ),
    ));
    await t.tap(find.text('abrir'));
    await t.pumpAndSettle();
    expect(find.text('Cierre automático'), findsOneWidget);
    expect(find.text('Se cerró por horario.'), findsOneWidget);
    expect(find.text('Todo en orden'), findsOneWidget);
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  test('contrato: los cinco sitios migrados usan '
      'DialogoApp', () {
    final home = File('lib/ui/home.dart').readAsStringSync();
    expect(home, contains("titulo: 'Cierre automático'"));
    expect(home, contains("'Acceso suspendido'"));
    final listas = File('lib/ui/listas.dart').readAsStringSync();
    expect(listas, contains('DialogoApp.confirmar('));
    expect(listas, contains("titulo: '¿Se envió el aviso?'"));
    expect(listas, contains("titulo: 'Guardar vista'"));
    expect('AlertDialog('.allMatches(listas).length, 0,
        reason: 'Listas ya no monta AlertDialog a mano');
  });
}
