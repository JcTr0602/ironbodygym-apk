/// Bandeja GymPedia 1.19: funciones puras de `lib/bandeja.dart`.
/// Sin BD: solo slug, filtro por estado y fusión espejo + ops.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/bandeja.dart';

Map<String, dynamic> _opBorrador(Map<String, dynamic> payload) => {
      'tipo': kTipoOpBorradorUpsert,
      'payload': jsonEncode(payload),
    };

void main() {
  group('slugBandeja', () {
    test('minúsculas, acentos y separadores', () {
      expect(slugBandeja('Hipertrofia: ¿Cómo Ganar Músculo?'),
          'hipertrofia-como-ganar-musculo');
    });
    test('ñ y ü se normalizan', () {
      expect(slugBandeja('Año Nuevo'), 'ano-nuevo');
    });
    test('vacío y solo signos dan vacío', () {
      expect(slugBandeja(''), '');
      expect(slugBandeja('!!!'), '');
    });
    test('trunca a 80', () {
      expect(slugBandeja('a' * 100).length, 80);
    });
  });

  group('solicitudesPorEstado', () {
    final todas = [
      {'id': '1', 'estado_bandeja': 'pendiente'},
      {'id': '2', 'estado_bandeja': 'publicada'},
      {'id': '3', 'estado_bandeja': 'descartada'},
      {'id': '4'}, // sin estado = pendiente (el puente nunca lo deja null)
    ];
    test('pendientes incluye sin-estado', () {
      final ids = solicitudesPorEstado(todas, kBandejaPendiente)
          .map((s) => s['id'])
          .toList();
      expect(ids, ['1', '4']);
    });
    test('publicadas y descartadas', () {
      expect(
          solicitudesPorEstado(todas, kBandejaPublicada)
              .map((s) => s['id'])
              .toList(),
          ['2']);
      expect(
          solicitudesPorEstado(todas, kBandejaDescartada)
              .map((s) => s['id'])
              .toList(),
          ['3']);
    });
  });

  group('fusionarBorradoresBandeja', () {
    final espejo = [
      {
        'id': 'a',
        'titulo': 'Viejo',
        'texto': 'texto viejo',
        'actualizado_en': '2026-10-01T00:00:00Z',
      },
      {
        'id': 'b',
        'titulo': 'Eliminado',
        'eliminado': true,
        'actualizado_en': '2026-10-02T00:00:00Z',
      },
      {
        'id': 'c',
        'titulo': 'Solo espejo',
        'actualizado_en': '2026-10-03T00:00:00Z',
      },
    ];
    test('espejo eliminado no se lista', () {
      final lista =
          fusionarBorradoresBandeja(espejo: espejo, opsPendientes: []);
      expect(lista.map((b) => b['id']).toList(), ['c', 'a']);
    });
    test('op pendiente fusiona claves sin destruir el resto', () {
      final lista = fusionarBorradoresBandeja(
        espejo: espejo,
        opsPendientes: [
          _opBorrador({
            'slug': 'a',
            'data': {'titulo': 'Nuevo'},
            'eliminado': false,
          }),
        ],
      );
      final a = lista.firstWhere((b) => b['id'] == 'a');
      expect(a['titulo'], 'Nuevo');
      expect(a['texto'], 'texto viejo');
      expect(a['pendiente'], true);
    });
    test('op pendiente crea el borrador que aún no bajó', () {
      final lista = fusionarBorradoresBandeja(
        espejo: espejo,
        opsPendientes: [
          _opBorrador({
            'slug': 'd',
            'data': {'titulo': 'Nuevo'},
            'eliminado': false,
          }),
        ],
      );
      expect(lista.map((b) => b['id']).toList(), contains('d'));
    });
    test('op pendiente con eliminado=true oculta', () {
      final lista = fusionarBorradoresBandeja(
        espejo: espejo,
        opsPendientes: [
          _opBorrador(
              {'slug': 'c', 'data': {}, 'eliminado': true}),
        ],
      );
      expect(lista.map((b) => b['id']).toList(), ['a']);
    });
    test('ops de otro tipo y payload roto se ignoran', () {
      final lista = fusionarBorradoresBandeja(
        espejo: espejo,
        opsPendientes: [
          {'tipo': 'otro_tipo', 'payload': '{}'},
          {'tipo': kTipoOpBorradorUpsert, 'payload': 'no-json'},
          _opBorrador({'slug': '', 'data': {}, 'eliminado': false}),
        ],
      );
      expect(lista.map((b) => b['id']).toList(), ['c', 'a']);
    });
    test('op revive una tumba conservando texto y autor', () {
      final lista = fusionarBorradoresBandeja(
        espejo: [
          {
            'id': 'b',
            'titulo': 'Viejo',
            'texto': 'texto viejo',
            'autor_telegram_id': 969869611,
            'eliminado': true,
            'actualizado_en': '2026-10-02T00:00:00Z',
          },
        ],
        opsPendientes: [
          _opBorrador({
            'slug': 'b',
            'data': {'titulo': 'Nuevo'},
            'eliminado': false,
          }),
        ],
      );
      expect(lista.map((b) => b['id']).toList(), ['b']);
      expect(lista.first['texto'], 'texto viejo');
      expect(lista.first['autor_telegram_id'], 969869611);
      expect(lista.first['titulo'], 'Nuevo');
    });
    test('borrador nuevo pendiente lleva el autor firmante', () {
      final lista = fusionarBorradoresBandeja(
        espejo: [],
        opsPendientes: [
          {
            'tipo': kTipoOpBorradorUpsert,
            'telegram_id': 1403501391,
            'creada_ts': '2026-10-30T10:00:00Z',
            'payload': jsonEncode({
              'slug': 'nuevo',
              'data': {'titulo': 'Nuevo'},
              'eliminado': false,
            }),
          },
        ],
      );
      expect(lista.first['autor_telegram_id'], 1403501391);
      expect(lista.first['pendiente'], true);
    });
    test('el overlay no pisa el autor existente', () {
      final lista = fusionarBorradoresBandeja(
        espejo: [
          {
            'id': 'a',
            'titulo': 'Viejo',
            'autor_telegram_id': 969869611,
            'actualizado_en': '2026-10-01T00:00:00Z',
          },
        ],
        opsPendientes: [
          {
            'tipo': kTipoOpBorradorUpsert,
            'telegram_id': 1403501391,
            'payload': jsonEncode({
              'slug': 'a',
              'data': {'titulo': 'Nuevo'},
              'eliminado': false,
            }),
          },
        ],
      );
      expect(lista.first['autor_telegram_id'], 969869611);
    });
  });

  group('accesoBandeja', () {
    List<Map<String, dynamic>> permisos(List<int> tids) => [
          for (final t in tids) {'telegram_id': t},
        ];
    List<Map<String, dynamic>> ops(List<Map<String, dynamic>> accs) => [
          for (final a in accs)
            {
              'tipo': kTipoOpPermisoBandeja,
              'payload': jsonEncode(a),
            },
        ];
    test('dueño siempre', () {
      expect(
          accesoBandeja(
              esDueno: true,
              tid: 1,
              permisosEspejo: [],
              opsPendientes: []),
          true);
    });
    test('sin tid no hay acceso', () {
      expect(
          accesoBandeja(
              esDueno: false,
              tid: null,
              permisosEspejo: permisos([5]),
              opsPendientes: []),
          false);
    });
    test('espejo otorga', () {
      expect(
          accesoBandeja(
              esDueno: false,
              tid: 5,
              permisosEspejo: permisos([5]),
              opsPendientes: []),
          true);
    });
    test('revocación pendiente cierra el acceso del espejo', () {
      expect(
          accesoBandeja(
              esDueno: false,
              tid: 5,
              permisosEspejo: permisos([5]),
              opsPendientes: ops([
                {'telegram_id': 5, 'accion': 'revocar'},
              ])),
          false);
    });
    test('otorgar pendiente abre sin espejo', () {
      expect(
          accesoBandeja(
              esDueno: false,
              tid: 5,
              permisosEspejo: [],
              opsPendientes: ops([
                {'telegram_id': 5, 'accion': 'otorgar'},
              ])),
          true);
    });
    test('última acción manda (revocar luego otorgar)', () {
      expect(
          accesoBandeja(
              esDueno: false,
              tid: 5,
              permisosEspejo: permisos([5]),
              opsPendientes: ops([
                {'telegram_id': 5, 'accion': 'revocar'},
                {'telegram_id': 5, 'accion': 'otorgar'},
              ])),
          true);
    });
    test('acciones de otro entrenador no afectan', () {
      expect(
          accesoBandeja(
              esDueno: false,
              tid: 5,
              permisosEspejo: [],
              opsPendientes: ops([
                {'telegram_id': 9, 'accion': 'otorgar'},
              ])),
          false);
    });
  });

  group('solicitudesTrasDescartes', () {
    final espejo = [
      {'id': 's1', 'estado_bandeja': 'pendiente'},
      {'id': 's2', 'estado_bandeja': 'pendiente'},
    ];
    test('descarte pendiente oculta la solicitud', () {
      final lista = solicitudesTrasDescartes(espejo, [
        {
          'tipo': kTipoOpDescartarSolicitud,
          'payload': jsonEncode({'solicitud_id': 's1'}),
        },
      ]);
      expect(lista.map((s) => s['id']).toList(), ['s2']);
    });
    test('otro tipo y payload roto no afectan', () {
      final lista = solicitudesTrasDescartes(espejo, [
        {'tipo': 'otro', 'payload': jsonEncode({'solicitud_id': 's1'})},
        {'tipo': kTipoOpDescartarSolicitud, 'payload': 'no-json'},
      ]);
      expect(lista.map((s) => s['id']).toList(), ['s1', 's2']);
    });
    test('publicación pendiente la mueve a publicadas con Por subir', () {
      final lista = solicitudesTrasDescartes(espejo, [
        {
          'tipo': kTipoOpPublicar,
          'payload': jsonEncode({'solicitud_id': 's1'}),
        },
      ]);
      expect(
          solicitudesPorEstado(lista, kBandejaPendiente)
              .map((s) => s['id'])
              .toList(),
          ['s2']);
      final publicadas =
          solicitudesPorEstado(lista, kBandejaPublicada);
      expect(publicadas.map((s) => s['id']).toList(), ['s1']);
      expect(publicadas.first['pendiente'], true);
      // La fila del espejo no se muta: el overlay es una copia.
      expect(espejo.first['estado_bandeja'], 'pendiente');
      expect(espejo.first.containsKey('pendiente'), false);
    });
    test('descarte manda sobre publicación pendiente', () {
      final lista = solicitudesTrasDescartes(espejo, [
        {
          'tipo': kTipoOpPublicar,
          'payload': jsonEncode({'solicitud_id': 's1'}),
        },
        {
          'tipo': kTipoOpDescartarSolicitud,
          'payload': jsonEncode({'solicitud_id': 's1'}),
        },
      ]);
      expect(lista.map((s) => s['id']).toList(), ['s2']);
    });
    test('publicación sin solicitud_id y borrador no cambian nada', () {
      final lista = solicitudesTrasDescartes(espejo, [
        {'tipo': kTipoOpPublicar, 'payload': jsonEncode({})},
        {
          'tipo': kTipoOpBorradorUpsert,
          'payload': jsonEncode({'solicitud_id': 's1'}),
        },
      ]);
      expect(lista.map((s) => s['id']).toList(), ['s1', 's2']);
      expect(lista.first['estado_bandeja'], 'pendiente');
    });
  });
}
