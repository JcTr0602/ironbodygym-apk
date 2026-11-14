/// 1.25 T83: el avatar del entrenador con su foto de
/// usuario APK (`usuarios/<username>.jpg` en Storage,
/// vía FotoCache). La identidad visual es el NOMBRE
/// visible: el mapa nombre→username sale del meta
/// `usuarios_apk` y se carga una sola vez. Sin foto (o
/// sin usuario que case), la inicial con el color del
/// entrenador — el mismo color de sus chips de turno.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../fotos.dart';
import '../localdb.dart';
import 'componentes.dart';
import '../turnos_resolucion.dart';
import 'diseno.dart';
import 'turnos_calendario.dart' show colorChipEntrenador;

class AvatarEntrenador extends StatelessWidget {
  final String nombre;
  final double tamano;

  const AvatarEntrenador(
      {super.key, required this.nombre, this.tamano = 28});

  static Future<Map<String, String>>? _mapaFut;

  /// Mapa nombre visible (normalizado) → username.
  static Future<Map<String, String>> _mapa() {
    return _mapaFut ??= () async {
      final mapa = <String, String>{};
      try {
        final raw = await LocalDb.instance.getMeta('usuarios_apk');
        if (raw != null && raw.isNotEmpty) {
          for (final u in jsonDecode(raw) as List) {
            final m = Map<String, dynamic>.from(u as Map);
            final nom = '${m['nombre'] ?? ''}'.trim();
            final user = '${m['username'] ?? ''}'.trim();
            if (nom.isNotEmpty && user.isNotEmpty) {
              mapa[normalizarNombreTurno(nom)] = user;
            }
          }
        }
      } catch (_) {}
      return mapa;
    }();
  }

  @override
  Widget build(BuildContext context) {
    final inicial = nombre.trim().isEmpty
        ? '?'
        : nombre.trim()[0].toUpperCase();
    final respaldo = CircleAvatar(
      radius: tamano / 2,
      backgroundColor:
          colorChipEntrenador(nombre).withValues(alpha: 0.18),
      child: Text(
        inicial,
        style: TextStyle(
          color: colorChipEntrenador(nombre),
          fontWeight: FontWeight.bold,
          fontSize: tamano * 0.42,
        ),
      ),
    );
    return FutureBuilder<Map<String, String>>(
      future: _mapa(),
      builder: (ctx, snapMapa) {
        final user =
            snapMapa.data?[normalizarNombreTurno(nombre)];
        if (user == null) return respaldo;
        return FutureBuilder<File?>(
          future: FotoCache.instance
              .enCache('usuarios/${user.toLowerCase()}.jpg'),
          builder: (ctx, snap) {
            final f = snap.data;
            if (f == null) return respaldo;
            return Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                    color: colorChipEntrenador(nombre), width: 1.6),
              ),
              child: CircleAvatar(
                radius: tamano / 2 - 1.6,
                // 1.34 Campo 2 (P-1): decodificación acotada
                // al tamaño del avatar.
                backgroundImage: providerFotoAcotada(FileImage(f),
                    ancho: (tamano *
                            MediaQuery.devicePixelRatioOf(ctx) *
                            2)
                        .round()),
                backgroundColor: AppColores.borde(ctx),
              ),
            );
          },
        );
      },
    );
  }
}
