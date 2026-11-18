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

class AvatarEntrenador extends StatefulWidget {
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
      // 1.36 H-B1 (136-376): un mapa vacío (la carga falló
      // o el meta aún no bajó) NO se cachea — el próximo
      // avatar lo reintenta; y al cambiar los usuarios el
      // mapa se refresca en vez de quedar fósil.
      if (mapa.isEmpty) _mapaFut = null;
      return mapa;
    }();
  }

  /// 136-376: punto de refresco al cambiar los usuarios.
  static void invalidarMapa() => _mapaFut = null;

  @override
  State<AvatarEntrenador> createState() => _AvatarEntrenadorState();
}

/// 1.34 Campo 2 (P-4): la resolución (mapa de usuarios +
/// foto en caché) vive en el State y se hace una vez por
/// nombre — antes el build creaba DOS futuros nuevos en
/// cada reconstrucción (mapa + disco por avatar).
class _AvatarEntrenadorState extends State<AvatarEntrenador> {
  File? _foto;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _resolver();
  }

  @override
  void didUpdateWidget(AvatarEntrenador old) {
    super.didUpdateWidget(old);
    if (old.nombre != widget.nombre) {
      _foto = null;
      _resolver();
    }
  }

  Future<void> _resolver() async {
    final gen = ++_gen;
    final nombre = widget.nombre;
    final mapa = await AvatarEntrenador._mapa();
    final user = mapa[normalizarNombreTurno(nombre)];
    if (user == null) return;
    final f = await FotoCache.instance
        .enCache('usuarios/${user.toLowerCase()}.jpg');
    if (f == null || !mounted || gen != _gen) return;
    setState(() => _foto = f);
  }

  @override
  Widget build(BuildContext context) {
    final nombre = widget.nombre;
    final tamano = widget.tamano;
    final inicial = nombre.trim().isEmpty
        ? '?'
        : nombre.trim()[0].toUpperCase();
    // 1.36 H-B1 (136-381): el respaldo lleva EL MISMO
    // borde que la rama con foto (mismo aro, mismo radio
    // útil) — el avatar no cambia de silueta al cargar.
    final borde = BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(
          color: colorChipEntrenador(nombre), width: 1.6),
    );
    final respaldo = Container(
      decoration: borde,
      child: CircleAvatar(
        radius: tamano / 2 - 1.6,
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
      ),
    );
    final f = _foto;
    final Widget contenido = f == null
        ? KeyedSubtree(
            key: const ValueKey('avatar-respaldo'), child: respaldo)
        : KeyedSubtree(
            key: const ValueKey('avatar-foto'),
            child: Container(
              decoration: borde,
              child: CircleAvatar(
                radius: tamano / 2 - 1.6,
                // 1.34 Campo 2 (P-1): decodificación acotada
                // al tamaño del avatar.
                backgroundImage: providerFotoAcotada(FileImage(f),
                    ancho: (tamano *
                            MediaQuery.devicePixelRatioOf(context) *
                            2)
                        .round()),
                backgroundColor: AppColores.borde(context),
              ),
            ),
          );
    // 1.36 H-B1 (136-385): la foto FUNDE al llegar
    // (fundido corto; instantáneo con «reducir movimiento»).
    return AnimatedSwitcher(
      duration: MediaQuery.of(context).disableAnimations
          ? Duration.zero
          : AppMovimiento.corta,
      child: contenido,
    );
  }
}
