/// Biblioteca / Guía (v47): validación local de fichas (§2.2).
/// Espejo de `_validar_ficha_guia` del servidor: mismos topes en
/// BYTES UTF-8. La regresión vacía NO es error (D8: aviso).
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/guia_validacion.dart';

Map<String, dynamic> fichaBase() => {
      'id': 'press-banca-plano',
      'titulo': 'Press de banca plano',
      'sinonimos': ['press plano'],
      'equipoId': 'banca-plana',
      'musculosPrincipales': ['pecho'],
      'musculosSecundarios': ['tríceps'],
      'siluetaId': 'pecho',
      'esencial': true,
      'vistaRapida': {
        'ajusteMaquina': 'Banco plano, barra a la altura del pecho',
        'claves': ['Escápulas juntas'],
        'advertenciaClave': 'No rebotar la barra en el pecho',
      },
      'dosificacion': {
        'series': 3,
        'repeticiones': '8-12',
        'descanso': '90 s',
        'pesoInicial': 'Barra sola',
      },
      'ejecutar': ['Acuéstate y toma la barra.'],
      'errores': ['Arquear la espalda.'],
      'seguridad': {
        'senalParada': 'Dolor en el hombro',
        'autoVerificacion': 'La barra toca el pecho sin rebote',
      },
      'regresion': 'Flexiones',
    };

void main() {
  const vigentes = {'banca-plana', 'polea-alta'};

  List<String> validar(Map<String, dynamic> f) =>
      GuiaValidacion.validar(f, equiposVigentes: vigentes);

  test('ficha válida pasa sin errores', () {
    expect(validar(fichaBase()), isEmpty);
  });

  test('título vacío y título de más de 300 bytes fallan', () {
    final a = fichaBase()..['titulo'] = '';
    expect(validar(a), isNotEmpty);
    // 160 'é' = 320 bytes (aunque son 160 caracteres).
    final b = fichaBase()..['titulo'] = 'é' * 160;
    expect(validar(b), isNotEmpty);
  });

  test('slug inválido falla', () {
    final a = fichaBase()..['id'] = 'Press Banca';
    expect(validar(a), isNotEmpty);
  });

  test('sinónimos: más de 6, de más de 40 bytes, repetido o igual '
      'al título fallan', () {
    final a = fichaBase()..['sinonimos'] = ['s1', 's2', 's3', 's4', 's5', 's6', 's7'];
    expect(validar(a), isNotEmpty);
    final b = fichaBase()..['sinonimos'] = ['x' * 41];
    expect(validar(b), isNotEmpty);
    final c = fichaBase()..['sinonimos'] = ['press plano', 'press plano'];
    expect(validar(c), isNotEmpty);
    final d = fichaBase()..['sinonimos'] = ['Press de banca plano'];
    expect(validar(d), isNotEmpty);
  });

  test('equipo no vigente o con slug inválido falla', () {
    final a = fichaBase()..['equipoId'] = 'maquina-inexistente';
    expect(validar(a), isNotEmpty);
    final b = fichaBase()..['equipoId'] = 'Banca Plana';
    expect(validar(b), isNotEmpty);
  });

  test('músculos principales: 0 o 7 fallan; silueta inválida falla',
      () {
    final a = fichaBase()..['musculosPrincipales'] = <String>[];
    expect(validar(a), isNotEmpty);
    final b = fichaBase()
      ..['musculosPrincipales'] = ['m1', 'm2', 'm3', 'm4', 'm5', 'm6', 'm7'];
    expect(validar(b), isNotEmpty);
    final c = fichaBase()..['siluetaId'] = 'cuello';
    expect(validar(c), isNotEmpty);
  });

  test('esencial no booleano falla', () {
    final a = fichaBase()..['esencial'] = 1;
    expect(validar(a), isNotEmpty);
  });

  test('vista rápida: 0 o 3 claves fallan', () {
    final a = fichaBase()
      ..['vistaRapida'] = {
        'ajusteMaquina': 'x',
        'claves': <String>[],
        'advertenciaClave': 'y',
      };
    expect(validar(a), isNotEmpty);
    final b = fichaBase()
      ..['vistaRapida'] = {
        'ajusteMaquina': 'x',
        'claves': ['c1', 'c2', 'c3'],
        'advertenciaClave': 'y',
      };
    expect(validar(b), isNotEmpty);
  });

  test('series fuera de 1–10 fallan', () {
    final a = fichaBase()
      ..['dosificacion'] = {
        'series': 0,
        'repeticiones': '8-12',
        'descanso': '90 s',
        'pesoInicial': 'Barra sola',
      };
    expect(validar(a), isNotEmpty);
    final b = fichaBase()
      ..['dosificacion'] = {
        'series': 11,
        'repeticiones': '8-12',
        'descanso': '90 s',
        'pesoInicial': 'Barra sola',
      };
    expect(validar(b), isNotEmpty);
  });

  test('ejecutar/errores: 0 o 13 fallan', () {
    final a = fichaBase()..['ejecutar'] = <String>[];
    expect(validar(a), isNotEmpty);
    final b = fichaBase()..['errores'] = List.filled(13, 'e');
    expect(validar(b), isNotEmpty);
  });

  test('regresión vacía NO es error; de más de 150 bytes sí', () {
    final a = fichaBase()..['regresion'] = '';
    expect(validar(a), isEmpty);
    final b = fichaBase()..['regresion'] = 'x' * 151;
    expect(validar(b), isNotEmpty);
  });

  test('total mayor de 16384 bytes falla aunque cada campo pase', () {
    final a = fichaBase()..['campo_futuro'] = 'x' * 20000;
    expect(validar(a), isNotEmpty);
  });
}
