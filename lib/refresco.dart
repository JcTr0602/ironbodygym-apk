// lib/refresco.dart
// 1.35 (HZ-2, de la auditoría de 120 Hz): la app no
// pedía NUNCA la tasa de refresco alta — en un
// teléfono de panel discreto 90/120 Hz (sin LTPO)
// corría probablemente a 60 Hz, y la fluidez en el
// S23 Ultra de Jc la ponía el panel adaptativo de
// Samsung, no la app. (La misma corrección ya vive
// en la app de Clientes desde su campo nº 10.)
//
// La corrección es UNA SOLA llamada global al
// arranque: pedir el modo de refresco más alto que
// el panel ofrezca. Es un VOTO, no una orden: la
// plataforma decide, y en paneles LTPO manda el
// sistema. PROHIBIDO pedirlo por pantalla o por
// ruta: cambiar de modo en mitad de la navegación
// provoca parpadeos — sería crear al corregir el
// defecto que se sospechaba.
//
// Solo Android (el plugin es Android; en el resto
// de plataformas ni se intenta). El fallo se traga
// en silencio: si el dispositivo o el fabricante no
// lo soportan, la app sigue exactamente igual que
// hoy. Y la llamada NO espera al primer frame (va
// sin await desde main, con su try/catch dentro):
// un canal de plataforma colgado no puede retrasar
// el arranque.
import 'dart:io' show Platform;

import 'package:flutter_displaymode/flutter_displaymode.dart';

/// Pide la tasa de refresco alta una vez. [esAndroid]
/// y [accion] existen para el test: por defecto se
/// usa la plataforma real y la llamada real al plugin.
Future<void> pedirAltaTasaDeRefresco({
  bool? esAndroid,
  Future<void> Function()? accion,
}) async {
  if (!(esAndroid ?? Platform.isAndroid)) return;
  try {
    await (accion ?? FlutterDisplayMode.setHighRefreshRate)();
  } catch (_) {
    // Tragado a propósito: sin modo alto, la app
    // sigue a la tasa de siempre. Nada que registrar:
    // no es un error del usuario ni del dato.
  }
}
