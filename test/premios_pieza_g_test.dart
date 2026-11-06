// Premios Pieza G (1.26): puras de la bandeja del Panel
// y la guarda de dueño de la pantalla.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/premios_panel.dart';
import 'package:ironbody_gym/ui/panel_premios.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  // Patrón de la casa para pantallas que leen AuthService:
  // Supabase dummy sin red (la sesión queda null = no dueño).
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
        url: 'http://127.0.0.1:9', anonKey: 'dummy');
  });

  group('parseBandejaPremios', () {
    test('jsonb real de la RPC', () {
      final b = parseBandejaPremios({
        'vales': [
          {
            'id': 3,
            'cliente_id': 11,
            'nombre': 'Ada Aragon Herrera',
            'telefono': '52893421',
            'pagado_hasta': '2026-11-20',
            'logro_id': 'constancia_real',
            'premio_dias': 15,
            'dias_al_reclamar': 93,
            'creado_en': '2026-11-06T08:33:49Z',
          },
        ],
        'recientes': [
          {
            'id': 2,
            'cliente_id': 9,
            'nombre': 'Otro Cliente',
            'premio_dias': 15,
            'estado': 'canjeado',
            'resuelto_en': '2026-11-01T00:00:00Z',
            'resuelto_nota': 'Aprobado en Gestión por Jc',
          },
        ],
      });
      expect(b.vales, hasLength(1));
      expect(b.vales.single.nombre, 'Ada Aragon Herrera');
      expect(b.vales.single.premioDias, 15);
      expect(b.vales.single.diasAlReclamar, 93);
      expect(b.vales.single.pagadoHasta, '2026-11-20');
      expect(b.recientes, hasLength(1));
      expect(b.recientes.single.canjeado, isTrue);
    });

    test('tolerante: nulos, tipos raros y piezas ausentes', () {
      expect(parseBandejaPremios(null).vales, isEmpty);
      expect(parseBandejaPremios('x').recientes, isEmpty);
      final b = parseBandejaPremios({
        'vales': [
          {'id': '7', 'premio_dias': '15'},
          'basura',
        ],
      });
      expect(b.vales, hasLength(1));
      expect(b.vales.single.id, 7);
      expect(b.vales.single.premioDias, 15);
      expect(b.vales.single.nombre, '');
    });

    test('bandeja vacía', () {
      final b = parseBandejaPremios({'vales': [], 'recientes': []});
      expect(b.vales, isEmpty);
      expect(b.recientes, isEmpty);
    });
  });

  group('valesVisibles', () {
    ValePendiente v(int id) => ValePendiente(
        id: id,
        clienteId: 1,
        nombre: 'X',
        telefono: '',
        pagadoHasta: null,
        logroId: 'constancia_real',
        premioDias: 15,
        diasAlReclamar: 90,
        creadoEn: '');

    test('sin resueltos locales pasa todo', () {
      expect(valesVisibles([v(1), v(2)], {}), hasLength(2));
    });

    test('fuera los resueltos en este teléfono', () {
      final visibles = valesVisibles([v(1), v(2), v(3)], {2});
      expect(visibles.map((e) => e.id), [1, 3]);
    });
  });

  test('tituloLogroPremio', () {
    expect(tituloLogroPremio('constancia_real'), 'Constancia real');
    expect(tituloLogroPremio('otro'), 'otro');
  });

  testWidgets('sin sesión de dueño, la pantalla se cierra',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: PremiosPanelScreen()),
    );
    await tester.pump();
    expect(find.text('Solo el dueño aprueba premios.'),
        findsOneWidget);
    expect(find.text('Aprobar premio'), findsNothing);
  });
}
