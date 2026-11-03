/// 1.23 (campo 2026-11-03) — La capa del candado de Gestión
/// anuncia la pausa en una tarjeta legible (misma pieza que en
/// Clientes): título propio, mensaje del dueño sin decoración
/// y hora de reactivación. La versión anterior pintaba el
/// mensaje sobre el velo translúcido: «feo y poco legible».
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_bloqueo.dart';
import 'package:ironbody_gym/ui/capa_candado.dart';

void main() {
  testWidgets('tarjeta del candado: título, mensaje limpio y '
      'reactivación', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Center(child: Text('contenido de la app')),
              CapaCandado(
                bloqueo: BloqueoVigente(
                  alcance: 'persona',
                  objetivo: '205',
                  mensaje: 'esto es una prueba',
                  expiraEn: DateTime.utc(2026, 11, 3, 18, 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Acceso pausado'), findsOneWidget);
    expect(find.text('esto es una prueba'), findsOneWidget);
    // 18:20 UTC = 13:20 en La Habana (UTC-5 en noviembre).
    expect(find.textContaining('Se reactiva solo el 03/11'),
        findsOneWidget);
    expect(find.textContaining('13:20'), findsOneWidget);
    expect(find.byIcon(Icons.lock_rounded), findsOneWidget);

    final texto = tester.widget<Text>(find.text('esto es una prueba'));
    expect(texto.style?.decoration, isNull);
    expect(texto.style?.fontSize, 16);
  });
}
