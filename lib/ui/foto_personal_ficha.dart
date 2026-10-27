/// Foto personal del cliente en su ficha de acceso (post-1.8.0,
/// ítem 12). Es la foto que el propio cliente se puso en su app.
///
/// SOLO el dueño: con rol entrenador este widget ni se construye
/// (la pantalla lo monta condicionalmente) ni se invoca la RPC —
/// que de todos modos es fail-closed con es_admin en el servidor.
///
/// Triestado explícito (Argón):
/// - con foto: imagen + «Retirar foto» (con confirmación previa).
/// - sin foto: no ocupa espacio (SizedBox.shrink).
/// - sin conexión/error al consultar: aviso compacto de una línea.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../fotos.dart';
import 'componentes.dart';
import 'diseno.dart';

class SeccionFotoPersonal extends StatefulWidget {
  final int clienteId;
  const SeccionFotoPersonal({super.key, required this.clienteId});

  @override
  State<SeccionFotoPersonal> createState() =>
      _SeccionFotoPersonalState();
}

enum _EstadoFoto { cargando, conFoto, sinFoto, error }

class _SeccionFotoPersonalState extends State<SeccionFotoPersonal> {
  _EstadoFoto _estado = _EstadoFoto.cargando;
  String? _path;
  File? _archivo;
  String? _actualizadaEn;
  bool _retirando = false;

  @override
  void initState() {
    super.initState();
    _consultar();
  }

  Future<void> _consultar() async {
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_foto_personal_de',
        params: {'p_cliente_id': widget.clienteId},
      );
      final data = Map<String, dynamic>.from(res as Map);
      if (data['ok'] != true) {
        throw Exception('${data['codigo'] ?? 'ERROR'}');
      }
      final path = data['foto_personal'] as String?;
      if (path == null || path.isEmpty) {
        if (mounted) setState(() => _estado = _EstadoFoto.sinFoto);
        return;
      }
      final archivo = await FotoCache.instance.obtener(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _archivo = archivo;
        _actualizadaEn = data['actualizada_en'] as String?;
        _estado = _EstadoFoto.conFoto;
      });
    } catch (_) {
      if (mounted) setState(() => _estado = _EstadoFoto.error);
    }
  }

  Future<void> _retirar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirar foto personal'),
        content: const Text(
            'El cliente perderá la foto que se puso en su app. '
            'Podrá subirse otra cuando quiera.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red),
              child: const Text('Retirar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _retirando = true);
    try {
      final res = await Supabase.instance.client.rpc(
        'admin_retirar_foto_personal',
        params: {'p_cliente_id': widget.clienteId},
      );
      final data = Map<String, dynamic>.from(res as Map);
      if (data['ok'] != true) {
        throw Exception('${data['codigo'] ?? 'ERROR'}');
      }
      await FotoCache.instance.invalidar(_path);
      if (!mounted) return;
      setState(() {
        _estado = _EstadoFoto.sinFoto;
        _path = null;
        _archivo = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Foto personal retirada')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No se pudo retirar la foto'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _retirando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_estado) {
      case _EstadoFoto.cargando:
      case _EstadoFoto.sinFoto:
        // Sin foto (o aún cargando): sin espacio muerto.
        return const SizedBox.shrink();
      case _EstadoFoto.error:
        return Tarjeta(
          child: Row(
            children: [
              const Icon(Icons.wifi_off, size: 18),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                    'Foto personal: sin conexión para verificar.',
                    style: AppTexto.secundario),
              ),
              TextButton(
                  onPressed: _consultar,
                  child: const Text('Reintentar')),
            ],
          ),
        );
      case _EstadoFoto.conFoto:
        return Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Foto personal del cliente',
                  style: AppTexto.titulo.copyWith(fontSize: 15)),
              Text('La que se puso en su app de cliente.',
                  style: AppTexto.secundario),
              const SizedBox(height: AppEspacio.sm),
              if (_archivo != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(_archivo!,
                      height: 220,
                      width: double.infinity,
                      fit: BoxFit.cover),
                )
              else
                Container(
                  height: 120,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  // Argón #8-5: sin botón de reintento, el dueño
                  // tenía que salir y volver a entrar a la ficha.
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('No se pudo descargar la foto'),
                        TextButton(
                          onPressed: _consultar,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_actualizadaEn != null) ...[
                const SizedBox(height: AppEspacio.xs),
                Text('Actualizada: ${_actualizadaEn!.split('T').first}',
                    style: AppTexto.secundario),
              ],
              const SizedBox(height: AppEspacio.sm),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _retirando ? null : _retirar,
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Retirar foto'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red),
                ),
              ),
            ],
          ),
        );
    }
  }
}
