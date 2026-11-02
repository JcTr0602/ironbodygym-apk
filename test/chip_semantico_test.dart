import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

void main() {
  testWidgets('ChipEstado.semantico muestra los 6 significados',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            ChipEstado.semantico(texto: 'Activo', significado: SignificadoChip.exito),
            ChipEstado.semantico(texto: 'Info', significado: SignificadoChip.info),
            ChipEstado.semantico(texto: 'Pronto', significado: SignificadoChip.alerta),
            ChipEstado.semantico(texto: 'Vencido', significado: SignificadoChip.error),
            ChipEstado.semantico(texto: 'Otro', significado: SignificadoChip.neutral),
            ChipEstado.semantico(texto: 'Agotado', significado: SignificadoChip.agotado),
            // Prueba de const: si el constructor no fuera const, esto
            // no compila (Argón 1.20: constructor nombrado real).
            ChipEstado.semantico(
                texto: 'Fijo', significado: SignificadoChip.info),
          ],
        ),
      ),
    ));
    for (final t in ['Activo', 'Info', 'Pronto', 'Vencido', 'Otro', 'Agotado', 'Fijo']) {
      expect(find.text(t), findsOneWidget);
    }
    // El chip semántico ES un ChipEstado (no un envoltorio privado):
    // se puede buscar por tipo y por key sin excepciones.
    expect(find.byType(ChipEstado), findsNWidgets(7));
  });

  testWidgets('ContadorBadge muestra el número y recorta a 99+',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Row(
          children: [ContadorBadge(numero: 3), ContadorBadge(numero: 150)],
        ),
      ),
    ));
    expect(find.text('3'), findsOneWidget);
    expect(find.text('99+'), findsOneWidget);
    // Fondo naranjaTexto (Argón 1.20): blanco sobre naranja brillante
    // daba 2.59:1 y fallaba AA; sobre naranjaTexto pasa.
    final contenedor = tester.widget<Container>(find
        .ancestor(
            of: find.text('3'), matching: find.byType(Container))
        .first);
    expect((contenedor.decoration as BoxDecoration).color,
        AppColores.naranjaTexto);
  });

  testWidgets('semantico resuelve el color por significado y brillo',
      (tester) async {
    const significados = {
      'Activo': SignificadoChip.exito,
      'Info': SignificadoChip.info,
      'Pronto': SignificadoChip.alerta,
      'Vencido': SignificadoChip.error,
      'Otro': SignificadoChip.neutral,
      'Agotado': SignificadoChip.agotado,
    };
    // Valores claros fijados por el ajuste de contraste (Terra-Zen):
    // un futuro aclarado debe romper este test, no colarse.
    expect(colorSignificadoChip(SignificadoChip.exito, false),
        const Color(0xFF166534));
    expect(colorSignificadoChip(SignificadoChip.alerta, false),
        const Color(0xFF92400E));
    expect(colorSignificadoChip(SignificadoChip.neutral, false),
        const Color(0xFF616161));
    expect(colorSignificadoChip(SignificadoChip.agotado, false),
        const Color(0xFF4B5563));
    for (final tema in [AppTema.claro(), AppTema.oscuro()]) {
      final oscuro = tema.brightness == Brightness.dark;
      for (final e in significados.entries) {
        // Theme directo (no MaterialApp.theme): evita la animación
        // de AnimatedTheme, que dejaría el brillo anterior tras un
        // solo pump al cambiar de tema en el bucle.
        await tester.pumpWidget(MaterialApp(
          home: Theme(
            data: tema,
            child: Scaffold(
              body: ChipEstado.semantico(
                  texto: e.key, significado: e.value),
            ),
          ),
        ));
        final texto =
            tester.widget<Text>(find.text(e.key));
        expect(texto.style?.color,
            colorSignificadoChip(e.value, oscuro));
      }
    }
  });
}
