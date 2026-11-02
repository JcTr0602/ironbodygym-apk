/// Regresión del reporte de campo de Jc (2026-11-02): la
/// ficha se quedaba en el spinner para siempre sin conexión
/// porque dos RPC sin timeout se esperaban antes de pintar.
/// Una de ellas es AccesoAppCache.cargar(): este test la
/// enfrenta a un servidor que ACEPTA la conexión y nunca
/// responde (el cuelgue real de campo, distinto de un rechazo
/// rápido) y exige que devuelva false en tiempo acotado.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/acceso_app_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer servidorMudo;
  HttpOverrides? overridesPrevios;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    // El binding de test instala un HttpClient falso que
    // responde 400 al instante: con eso el test no probaría
    // el cuelgue real. Se restaura la red verdadera para que
    // la petición llegue al servidor mudo de verdad (y se
    // repone el override al terminar: panel Terra por Zen).
    overridesPrevios = HttpOverrides.current;
    HttpOverrides.global = null;
    // Servidor mudo: acepta y jamás responde.
    servidorMudo = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    servidorMudo.listen((req) {
      // No se escribe ni se cierra la respuesta: la petición
      // queda colgada, como una RPC en una red muerta.
    });
    await Supabase.initialize(
      url: 'http://127.0.0.1:${servidorMudo.port}',
      anonKey: 'dummy',
    );
  });

  tearDownAll(() async {
    HttpOverrides.global = overridesPrevios;
    await servidorMudo.close(force: true);
  });

  test(
      'cargar() ante un servidor que nunca responde devuelve '
      'false en tiempo acotado (no cuelga la ficha)', () async {
    AccesoAppCache.instance.limpiar();
    final crono = Stopwatch()..start();
    // La espera misma va envuelta en timeout: si el cuelgue
    // reapareciera, el test falla a los 30 s en vez de
    // esperar al timeout global del corredor (panel).
    final ok = await AccesoAppCache.instance
        .cargar()
        .timeout(const Duration(seconds: 30));
    crono.stop();
    expect(ok, isFalse);
    // El timeout interno es de 10 s; se deja margen amplio
    // para CI lenta, pero muy por debajo de «para siempre».
    expect(crono.elapsed, lessThan(const Duration(seconds: 30)));
    expect(AccesoAppCache.instance.cargado, isFalse);
  });
}
