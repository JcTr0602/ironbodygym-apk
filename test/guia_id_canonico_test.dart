// Colisión de slug de GymPedia (2026-11-07, decisión de Jc:
// «ponle los nombres exactos de cada uno»): dos fichas del
// catálogo comparten slug con distinto equipo
// (barra-recta_peso-muerto-rumano y
// mancuernas_peso-muerto-rumano) y la PK de la tubería es el
// slug a secas. La segunda viaja con slug alias y su documento
// declara `idCanonico` con el id EXACTO de Clientes; el editor
// de rutinas debe componer AMBOS ids sin huérfanos ni cruces.
import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/guia_validacion.dart';
import 'package:ironbody_gym/ui/editor_rutinas_gym.dart';

Map<String, dynamic> fichaValida() => {
      'id': 'peso-muerto-rumano-mancuernas',
      'titulo': 'Peso muerto rumano con mancuernas',
      'sinonimos': ['rumano con mancuernas'],
      'equipoId': 'mancuernas',
      'musculosPrincipales': ['isquiotibiales'],
      'musculosSecundarios': ['glúteos'],
      'siluetaId': 'piernas',
      'esencial': false,
      'vistaRapida': {
        'ajusteMaquina': 'Mancuernas a los lados.',
        'claves': ['Bisagra de cadera.'],
        'advertenciaClave': 'Espalda neutra.',
      },
      'dosificacion': {
        'series': 3,
        'repeticiones': '8-12',
        'descanso': '2 min',
        'pesoInicial': 'Mancuernas ligeras',
      },
      'ejecutar': ['Bisagra de cadera.'],
      'errores': ['Redondear la espalda.'],
      'seguridad': {
        'senalParada': 'Dolor lumbar agudo.',
        'autoVerificacion': 'Espalda neutra.',
      },
      'regresion': '',
    };

void main() {
  group('editor de rutinas: composición con colisión de slug', () {
    final espejo = <Map<String, dynamic>>[
      {
        'id': 'peso-muerto-rumano',
        'equipoId': 'barra-recta',
        'titulo': 'Peso muerto rumano',
      },
      {
        'id': 'peso-muerto-rumano-mancuernas',
        'equipoId': 'mancuernas',
        'titulo': 'Peso muerto rumano con mancuernas',
        'idCanonico': 'mancuernas_peso-muerto-rumano',
      },
    ];

    test('las dos fichas componen ids exactos y distintos', () {
      final cat = fichasCatalogoDesdeEspejo(espejo);
      expect(cat.map((f) => f.id).toSet(), {
        'barra-recta_peso-muerto-rumano',
        'mancuernas_peso-muerto-rumano',
      });
      final mancuernas =
          cat.singleWhere((f) => f.id == 'mancuernas_peso-muerto-rumano');
      expect(mancuernas.titulo, 'Peso muerto rumano con mancuernas');
      final barra =
          cat.singleWhere((f) => f.id == 'barra-recta_peso-muerto-rumano');
      expect(barra.titulo, 'Peso muerto rumano');
    });

    test('idCanonico con prefijo ajeno NO se honra', () {
      expect(
        idCanonicoFichaGuia('peso-muerto-rumano-mancuernas', 'mancuernas',
            'barra-recta_peso-muerto-rumano'),
        'mancuernas_peso-muerto-rumano-mancuernas',
      );
    });

    test('sin idCanonico se compone como siempre', () {
      expect(idCanonicoFichaGuia('sentadilla', 'barra-recta', null),
          'barra-recta_sentadilla');
      expect(idCanonicoFichaGuia('sentadilla', 'barra-recta', ''),
          'barra-recta_sentadilla');
      expect(
          idCanonicoFichaGuia(
              'sentadilla', 'barra-recta', 'barra-recta_sentadilla'),
          'barra-recta_sentadilla');
    });

    test('idCanonico con resto no-slug NO se honra', () {
      expect(
        idCanonicoFichaGuia('alias', 'mancuernas', 'mancuernas_otro_slug'),
        'mancuernas_alias',
      );
    });

    test('la ficha sin equipoId sigue sin entrar (regla G-07)', () {
      final cat = fichasCatalogoDesdeEspejo([
        {'id': 'huerfana', 'titulo': 'Sin equipo'},
      ]);
      expect(cat, isEmpty);
    });
  });

  group('GuiaValidacion: forma de idCanonico', () {
    final equipos = {'mancuernas', 'barra-recta'};

    test('idCanonico válido no produce error', () {
      final p = fichaValida()
        ..['idCanonico'] = 'mancuernas_peso-muerto-rumano';
      final errores = GuiaValidacion.validar(p, equiposVigentes: equipos);
      expect(errores.where((e) => e.contains('canónico')), isEmpty);
    });

    test('idCanonico con prefijo de otro equipo produce error', () {
      final p = fichaValida()
        ..['idCanonico'] = 'barra-recta_peso-muerto-rumano';
      final errores = GuiaValidacion.validar(p, equiposVigentes: equipos);
      expect(errores.where((e) => e.contains('canónico')), isNotEmpty);
    });

    test('idCanonico igual al compuesto por defecto produce error',
        () {
      final p = fichaValida()
        ..['idCanonico'] = 'mancuernas_peso-muerto-rumano-mancuernas';
      final errores = GuiaValidacion.validar(p, equiposVigentes: equipos);
      expect(errores.where((e) => e.contains('canónico')), isNotEmpty);
    });

    test('sin idCanonico la ficha sigue válida (las 61 de siempre)',
        () {
      final errores =
          GuiaValidacion.validar(fichaValida(), equiposVigentes: equipos);
      expect(errores, isEmpty);
    });
  });
}
