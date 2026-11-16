/// F9 (1.20): abrir turno pudiendo marcar suplencia — si
/// hoy cubres a otro entrenador, su nombre viaja con la
/// apertura y se ve en el hub («Gabriel cubre a Duany»).
/// Sin otros entrenadores configurados, abre directo.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
import '../localdb.dart';
import '../turno_service.dart';
import 'componentes.dart';

/// Nombres de los demás entrenadores (meta usuarios_apk),
/// sin el propio. Vacío si no hay nadie más configurado.
Future<List<String>> nombresOtrosEntrenadores() async {
  final yo = AuthService().telegramId;
  final nombres = <String>[];
  try {
    final raw = await LocalDb.instance.getMeta('usuarios_apk');
    if (raw != null && raw.isNotEmpty) {
      for (final u in jsonDecode(raw) as List) {
        final m = Map<String, dynamic>.from(u as Map);
        final tid = LocalDb.normalizarTelegramId(m['telegram_id']);
        final nombre =
            '${m['nombre'] ?? m['username'] ?? ''}'.trim();
        // FIN-26 de Argón (1.20): la suplencia es entre
        // entrenadores — fuera el dueño/admin (rol de la lista)
        // y los usuarios bloqueados en la APK.
        final rol = '${m['rol'] ?? ''}'.trim().toLowerCase();
        if (rol == 'owner' ||
            rol == 'dueno' ||
            rol == 'dueño' ||
            rol == 'admin') {
          continue;
        }
        if (m['bloqueado'] == true) continue;
        if (tid != null && nombre.isNotEmpty && tid != yo) {
          nombres.add(nombre);
        }
      }
    }
  } catch (e) {
    // SL-11 (G12-5): la suplencia NO se pierde en silencio.
    // Antes el fallo se tragaba (solo bitácora) y la lista
    // vacía hacía abrir el turno «normal», sin preguntar ni
    // avisar: el «cubre a…» desaparecía. Ahora la lectura
    // fallida LANZA un error limpio y quien abre (Home, hub)
    // lo muestra amable SIN abrir el turno.
    AppLog.aviso('turno_abrir', 'otros_entrenadores_fallo', d: '$e');
    throw StateError(
        'No se pudo comprobar a quién podrías cubrir hoy. '
        'El turno no se abrió; inténtalo de nuevo.');
  }
  return nombres;
}

/// Selector «¿a quién cubres hoy?». Devuelve (cancelado,
/// nombre): nombre null = turno propio, sin cubrir a nadie.
Future<(bool, String?)> elegirCubreA(
    BuildContext context, List<String> nombres) async {
  final elegido = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('¿A quién cubres hoy?'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, -1),
          child: const Text('A nadie — es mi turno'),
        ),
        for (var i = 0; i < nombres.length; i++)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, i),
            child: Text('Cubro a ${nombres[i]}'),
          ),
      ],
    ),
  );
  if (elegido == null) return (true, null);
  if (elegido < 0) return (false, null);
  return (false, nombres[elegido]);
}

/// Abre el turno preguntando antes por la suplencia (si
/// hay a quién cubrir). Devuelve false si se canceló.
/// SL-11 (G12-5): si la lectura de entrenadores FALLA, la
/// excepción sube al llamador (Home/hub la muestran amable)
/// y el turno NO se abre: nunca un «normal» fingido.
Future<bool> abrirTurnoConSuplente(BuildContext context) async {
  final nombres = await nombresOtrosEntrenadores();
  if (nombres.isEmpty || !context.mounted) {
    await TurnoService.instance.abrirTurno();
    return true;
  }
  final (cancelado, cubreA) = await elegirCubreA(context, nombres);
  if (cancelado) return false;
  await TurnoService.instance.abrirTurno(cubreA: cubreA);
  return true;
}

/// Marca (o cambia) a quién cubre el turno ya abierto.
Future<void> marcarCubreA(BuildContext context) async {
  // SL-11 (G12-5): misma regla al remarcar — si la lectura
  // falla se avisa y no se toca la marca, en silencio no.
  final List<String> nombres;
  try {
    nombres = await nombresOtrosEntrenadores();
  } catch (e) {
    if (context.mounted) {
      mostrarSnack(context,
          'No se pudo marcar la suplencia: ${mensajeErrorAmable(e)}',
          significado: SignificadoChip.error);
    }
    return;
  }
  if (nombres.isEmpty) {
    if (context.mounted) {
      mostrarSnack(
          context, 'No hay otros entrenadores configurados.');
    }
    return;
  }
  final (cancelado, cubreA) = await elegirCubreA(context, nombres);
  if (cancelado) return;
  await TurnoService.instance.abrirTurno(cubreA: cubreA);
}
