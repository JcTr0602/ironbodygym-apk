// test/hb4_actividad_136_test.dart
// 1.36 H-B4 G6: contratos puros de Actividad / plantilla /
// comunidad.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/comunidad_panel.dart';
import 'package:ironbody_gym/plantilla_mensaje.dart';
import 'package:ironbody_gym/ui/actividad.dart';

void main() {
  group('136-974 avisoFrescura', () {
    test('sello no parseable avisa «sin registro válido», no silencio', () {
      final r = avisoFrescura(
        ultimoPullIso: 'no-es-una-fecha',
        opsPendientes: 0,
        ahora: DateTime(2026, 11, 18, 10),
      );
      expect(r, isNotNull);
      expect(r, contains('Sin registro válido'));
    });
  });

  group('136-998 textoComparativa sin base', () {
    test('previo 0 → neutra (esPositiva null)', () {
      final r = textoComparativa(500, 0, 'ayer');
      expect(r.$1, '— vs ayer');
      expect(r.$2, isNull);
    });
    test('con base sigue positiva/negativa', () {
      expect(textoComparativa(1150, 1000, 'ayer').$2, isTrue);
      expect(textoComparativa(920, 1000, 'ayer').$2, isFalse);
    });
  });

  group('136-995 montoTxtActividad', () {
    test('dos monedas: se muestran las dos', () {
      final t = montoTxtActividad(1500, 20);
      expect(t, contains('CUP'));
      expect(t, contains('USD'));
    });
    test('una sola moneda y ninguna', () {
      expect(montoTxtActividad(0, 20), contains('USD'));
      expect(montoTxtActividad(1500, 0), contains('CUP'));
      expect(montoTxtActividad(0, 0), isEmpty);
    });
  });

  group('136-969 filtrarPerfilesComunidad por Nick', () {
    test('encuentra por nick además de por nombre', () {
      final perfiles = [
        PerfilComunidadAdmin(
          clienteId: 1,
          nombre: 'Juan Pérez',
          nick: 'El Toro',
          visible: true,
          ocultoAdmin: false,
          mostrarMarcas: false,
          mostrarActividad: false,
          mostrarRutina: false,
          mostrarConstancia: false,
        ),
        PerfilComunidadAdmin(
          clienteId: 2,
          nombre: 'Ana Díaz',
          nick: null,
          visible: true,
          ocultoAdmin: false,
          mostrarMarcas: false,
          mostrarActividad: false,
          mostrarRutina: false,
          mostrarConstancia: false,
        ),
      ];
      expect(
          filtrarPerfilesComunidad(perfiles, 'toro')
              .map((p) => p.clienteId),
          [1]);
      expect(
          filtrarPerfilesComunidad(perfiles, 'ana')
              .map((p) => p.clienteId),
          [2]);
    });
  });
}
