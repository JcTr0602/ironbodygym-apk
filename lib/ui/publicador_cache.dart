/// 1.32 (Oleada 2, Fase 3 — Publicador Unificado,
/// Compuerta 3 del rediseño): la COPIA LOCAL de las dos
/// listas del Publicador (anuncios de portada G-63 y
/// avisos a clientes G-64), guardada en preferencias
/// POR USUARIO (lección M5-A1 de panel_cache: una copia
/// de un usuario no se hereda en el teléfono de otro).
///
/// Al abrir, el Publicador pinta en 0 ms la última copia
/// buena CON SU SELLO («Copia guardada de las 09:41»)
/// mientras la red revalida detrás con su timeout de
/// 12 s (Compuerta 4). La copia JAMÁS se disfraza de
/// dato fresco: si la revalidación falla, la lista se
/// queda pintada pero el sello dice «Sin conexión ·
/// copia de las HH:MM»; y si no hay copia, el fallo de
/// red se declara como error con reintento, nunca como
/// lista vacía (la regla de BandejaSwr y de la
/// Compuerta 1: error ≠ vacío, jamás).
///
/// Las escrituras NO pasan por aquí: publicar, retirar
/// y borrar siguen siendo operaciones de red con su
/// comprobación post-fallo (el patrón verificado de
/// cada pantalla). Esto es solo la foto de lectura.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tiempo.dart';
import 'diseno.dart';

/// Clave de la copia de anuncios, por telegramId
/// (0 = sin sesión identificada).
String claveCopiaAnuncios(int? telegramId) =>
    'publicador_anuncios_v1_${telegramId ?? 0}';

/// Clave de la copia de avisos, por telegramId.
String claveCopiaAvisos(int? telegramId) =>
    'publicador_avisos_v1_${telegramId ?? 0}';

/// La copia de ANUNCIOS: la respuesta cruda de
/// admin_anuncios_listar (JSON seguro: viene de la RPC)
/// con la hora habanera en que se verificó.
class CopiaAnuncios {
  final DateTime hora;
  final Map<String, dynamic> json;

  const CopiaAnuncios(this.hora, this.json);

  // La hora se guarda como wall-clock habanero SIN
  // offset (el patrón de FotoPanelCache): [hora] ya
  // trae los campos de La Habana (ahoraHabana) y así
  // el sello se lee tal cual en cualquier zona del
  // aparato; con offset, el parseo reconvertiría a la
  // zona local y el sello mentiría las horas del
  // desfase.
  String codificar() => jsonEncode({
        'ts': hora.toIso8601String(),
        'datos': json,
      });

  /// Decodificación tolerante (patrón FotoPanelCache):
  /// cualquier degradación = null (no hay copia; la
  /// pantalla carga de red como siempre).
  static CopiaAnuncios? decodificar(String? texto) {
    if (texto == null || texto.isEmpty) return null;
    try {
      final j = jsonDecode(texto);
      if (j is! Map) return null;
      final hora = DateTime.tryParse('${j['ts'] ?? ''}');
      final datos = j['datos'];
      if (hora == null || datos is! Map) return null;
      return CopiaAnuncios(hora, Map<String, dynamic>.from(datos));
    } catch (_) {
      return null;
    }
  }
}

/// La copia de AVISOS: las filas tal como las entrega
/// admin_listar_avisos (mapas con las claves de
/// AvisoCliente.fromJson) con su hora de verificación.
class CopiaAvisos {
  final DateTime hora;
  final List<Map<String, dynamic>> filas;

  const CopiaAvisos(this.hora, this.filas);

  String codificar() => jsonEncode({
        'ts': hora.toIso8601String(),
        'datos': filas,
      });

  static CopiaAvisos? decodificar(String? texto) {
    if (texto == null || texto.isEmpty) return null;
    try {
      final j = jsonDecode(texto);
      if (j is! Map) return null;
      final hora = DateTime.tryParse('${j['ts'] ?? ''}');
      final datos = j['datos'];
      if (hora == null || datos is! List) return null;
      return CopiaAvisos(hora, [
        for (final e in datos)
          if (e is Map) Map<String, dynamic>.from(e),
      ]);
    } catch (_) {
      return null;
    }
  }
}

/// Lee la copia de anuncios. NUNCA lanza: cualquier
/// fallo de preferencias degrada a «sin copia».
Future<CopiaAnuncios?> leerCopiaAnuncios(int? telegramId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return CopiaAnuncios.decodificar(
        prefs.getString(claveCopiaAnuncios(telegramId)));
  } catch (_) {
    return null;
  }
}

/// Guarda la copia de anuncios con la hora de AHORA
/// (la verificación que la produjo acaba de ocurrir).
/// NUNCA lanza: perder la copia no es un error de la
/// pantalla.
Future<void> guardarCopiaAnuncios(
    int? telegramId, Map<String, dynamic> json) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      claveCopiaAnuncios(telegramId),
      CopiaAnuncios(ahoraHabana(), json).codificar(),
    );
  } catch (_) {}
}

/// Lee la copia de avisos. NUNCA lanza.
Future<CopiaAvisos?> leerCopiaAvisos(int? telegramId) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    return CopiaAvisos.decodificar(
        prefs.getString(claveCopiaAvisos(telegramId)));
  } catch (_) {
    return null;
  }
}

/// Guarda la copia de avisos. NUNCA lanza.
Future<void> guardarCopiaAvisos(
    int? telegramId, List<Map<String, dynamic>> filas) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      claveCopiaAvisos(telegramId),
      CopiaAvisos(ahoraHabana(), filas).codificar(),
    );
  } catch (_) {}
}

/// «09:41» — la hora del sello, hora de pared habanera
/// (el mismo formato del sello de la foto de Por
/// Decidir).
String textoHoraCopia(DateTime hora) =>
    '${hora.hour.toString().padLeft(2, '0')}:'
    '${hora.minute.toString().padLeft(2, '0')}';

/// El sello de copia que va sobre la lista mientras lo
/// pintado es la copia local: «Copia guardada de las
/// 09:41 · actualizando…» durante la revalidación, y
/// «Sin conexión · copia de las 09:41» si la red falló.
/// Cuando la red verifica, el sello desaparece: lo
/// pintado ya es el dato, no su copia.
class SelloCopiaPublicador extends StatelessWidget {
  final DateTime hora;
  final bool actualizando;

  const SelloCopiaPublicador({
    super.key,
    required this.hora,
    required this.actualizando,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(
          actualizando
              ? Icons.sync_rounded
              : Icons.cloud_off_rounded,
          size: 14,
          color: AppColores.alerta,
        ),
        const SizedBox(width: AppEspacio.xs),
        Expanded(
          child: Text(
            actualizando
                ? 'Copia guardada de las ${textoHoraCopia(hora)}'
                    ' · actualizando…'
                : 'Sin conexión · copia de las '
                    '${textoHoraCopia(hora)}',
            style: AppTexto.metadato
                .copyWith(color: AppColores.alerta),
          ),
        ),
      ],
    );
  }
}
