/// Tests 1.14 (M8.12): la caché de permisos del entrenador.
/// Sin red, cargar() levanta la foto guardada en SharedPreferences
/// (el refresco a Supabase falla y se traga: offline). Sin sesión
/// en tests, el usuario NO es dueño, así que mandan las claves.
/// Un solo test: el singleton queda cargado tras el primero.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/permisos_entrenador.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  test('caché offline levanta permisos, activo y habilitado', () async {
    // El mock de prefs va PRIMERO: Supabase.initialize lo usa para
    // su storage de auth. URL local que rechaza al instante: la
    // sesión es null (no dueño) y el refresco RPC falla rápido y
    // se traga, como en offline real. Sin inicializar,
    // AuthService.isOwner revienta con assert y ningún getter se
    // puede probar.
    SharedPreferences.setMockInitialValues({
      'cache_permisos_entrenador_json': jsonEncode({
        'can_ver_ranking_servicios': true,
        'can_cobrar_pagos': false,
      }),
      'cache_entrenador_activo': false,
      'cache_entrenador_habilitado': true,
    });
    await Supabase.initialize(
      url: 'http://127.0.0.1:9',
      anonKey: 'dummy',
    );
    await PermisosEntrenador().cargar();

    final p = PermisosEntrenador();
    expect(p.cargado, isTrue);
    // Fila existente y desactivada = suspendido, no «sin habilitar».
    expect(p.estaSuspendido, isTrue);
    expect(p.sinHabilitar, isFalse);
    // La clave presente manda; la ausente no concede (fail-closed).
    expect(p.canVerRankingServicios, isTrue);
    expect(p.canCobrarPagos, isFalse);
    expect(p.canVerCifras, isFalse);
  });
}
