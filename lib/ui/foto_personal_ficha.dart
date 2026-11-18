/// Foto personal del cliente en su ficha de acceso (post-1.8.0,
/// ítem 12). Es la foto que el propio cliente se puso en su app.
///
/// SOLO el dueño: con rol entrenador este widget ni se construye
/// (la pantalla lo monta condicionalmente) ni se invoca la RPC —
/// que de todos modos es fail-closed con es_admin en el servidor.
///
/// Triestado explícito (Argón):
/// - con foto: imagen (tocable, abre el visor) + «Retirar foto»
///   (con confirmación previa).
/// - sin foto: no ocupa espacio (SizedBox.shrink).
/// - cargando: línea compacta «verificando» (1.25 T117 F1-45:
///   ya no se confunde con el estado sin foto).
/// - error al consultar: aviso compacto de una línea; dice
///   «sin conexión» SOLO si la causa es de red con certeza
///   (SL-2 G03-10), si no «no se pudo verificar».
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../fotos.dart';
import '../negocio.dart' show fmtFecha;
import 'componentes.dart';
import 'diseno.dart';

class SeccionFotoPersonal extends StatefulWidget {
  final int clienteId;

  /// 1.25 T58: la foto de gestión del cliente (la de la
  /// ficha) para pintar el PAR etiquetado «Gestión» /
  /// «Del cliente». Sin ella, la personal va grande como
  /// siempre.
  final File? fotoGestion;

  /// 1.25 T58: abrir la foto de gestión en el visor de la
  /// ficha (el mismo gesto que tocar el avatar).
  final VoidCallback? onVerFotoGestion;

  const SeccionFotoPersonal(
      {super.key,
      required this.clienteId,
      this.fotoGestion,
      this.onVerFotoGestion});

  @override
  State<SeccionFotoPersonal> createState() =>
      _SeccionFotoPersonalState();
}

enum _EstadoFoto { cargando, conFoto, sinFoto, error }

/// SL-2 G03-10: ¿el fallo al verificar la foto personal es
/// de RED con certeza? Solo entonces la pantalla puede
/// decir «sin conexión»: un 500 del servidor, un timeout o
/// un error de la RPC NO son «sin conexión» y afirmarlo
/// mentía sobre la causa. Ante la duda, false.
bool esFalloDeRedFotoPersonal(Object e) {
  if (e is SocketException) return true;
  if (e is TimeoutException) return false;
  final raw = e.toString().toLowerCase();
  return raw.contains('socketexception') ||
      raw.contains('failed host lookup') ||
      raw.contains('clientexception') ||
      raw.contains('handshakeexception') ||
      raw.contains('network is unreachable') ||
      raw.contains('connection closed') ||
      raw.contains('connection reset');
}

/// SL-2 G03-10: el texto del estado de error de la foto
/// personal según la causa CONOCIDA; sin causa conocida,
/// genérico-amable que no afirma conexión.
String textoErrorFotoPersonal({required bool fueDeRed}) => fueDeRed
    ? 'Foto personal: sin conexión para verificar.'
    : 'Foto personal: no se pudo verificar.';

class _SeccionFotoPersonalState extends State<SeccionFotoPersonal> {
  _EstadoFoto _estado = _EstadoFoto.cargando;
  // SL-2 G03-10: la causa del último fallo de verificación
  // era de red con certeza (solo entonces «sin conexión»).
  bool _falloFueDeRed = false;
  String? _path;
  File? _archivo;
  String? _actualizadaEn;
  bool _retirando = false;

  /// 1.28 (M4-A7): generación de la consulta en curso. Una
  /// respuesta tardía del cliente anterior no puede pintar
  /// (ni invalidar) sobre la ficha del cliente visible.
  int _consultaGen = 0;

  @override
  void initState() {
    super.initState();
    _consultar();
  }

  // Caza Fotos L5-MEDIA (Argón): sin didUpdateWidget, si el padre
  // reutiliza este hueco para OTRO cliente, la sección seguía
  // mostrando la foto personal del anterior. Al cambiar el
  // clienteId se resetea el estado y se consulta de nuevo.
  @override
  void didUpdateWidget(SeccionFotoPersonal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.clienteId != widget.clienteId) {
      _estado = _EstadoFoto.cargando;
      _path = null;
      _archivo = null;
      _actualizadaEn = null;
      _retirando = false;
      _consultar();
    }
  }

  Future<void> _consultar() async {
    // 1.28 (M4-A7): se captura el cliente y la generación al
    // arrancar; tras CADA await se verifica que la sección
    // sigue montada, que no hay una consulta más nueva y que
    // el cliente visible sigue siendo este. Sin esto, la
    // respuesta del cliente A podía pintar su foto en la
    // ficha de B (y «Retirar» retiraba con el RPC de B
    // habiendo invalidado el path de A).
    final id = widget.clienteId;
    final gen = ++_consultaGen;
    bool vigente() =>
        mounted && gen == _consultaGen && widget.clienteId == id;
    try {
      // Autoauditoría 1.22 #2: lectura con timeout (12 s): la
      // sección quedaba en «cargando» para siempre si la RPC
      // colgaba (un cuelgue no llega al catch de abajo, que ya
      // sabe pintar el estado de error).
      final res = await Supabase.instance.client
          .rpc(
            'admin_foto_personal_de',
            params: {'p_cliente_id': id},
          )
          .timeout(const Duration(seconds: 12));
      if (!vigente()) return;
      final data = Map<String, dynamic>.from(res as Map);
      if (data['ok'] != true) {
        throw Exception('${data['codigo'] ?? 'ERROR'}');
      }
      final path = data['foto_personal'] as String?;
      if (path == null || path.isEmpty) {
        setState(() => _estado = _EstadoFoto.sinFoto);
        return;
      }
      final archivo = await FotoCache.instance.obtener(path);
      if (!vigente()) return;
      setState(() {
        _path = path;
        _archivo = archivo;
        _actualizadaEn = data['actualizada_en'] as String?;
        _estado = _EstadoFoto.conFoto;
      });
    } catch (e) {
      if (vigente()) {
        setState(() {
          // SL-2 G03-10: se guarda la causa conocida para
          // que el texto no afirme «sin conexión» sin
          // saberlo (un 500 no es un corte de red).
          _falloFueDeRed = esFalloDeRedFotoPersonal(e);
          _estado = _EstadoFoto.error;
        });
      }
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
                  backgroundColor: AppColores.error),
              child: const Text('Retirar')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _retirando = true);
    try {
      final res = await Supabase.instance.client
          .rpc(
            'admin_retirar_foto_personal',
            params: {'p_cliente_id': widget.clienteId},
          )
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
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
      mostrarSnack(context, 'Foto personal retirada', significado: SignificadoChip.exito);
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo retirar la foto',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _retirando = false);
    }
  }

  /// 1.25 T58: una miniatura del par, con su etiqueta.
  Widget _miniaturaPar({
    required String etiqueta,
    required File archivo,
    required VoidCallback? alTocar,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: alTocar,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.md),
            child: Image.file(archivo,
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover),
          ),
        ),
        const SizedBox(height: AppEspacio.xs),
        Text(etiqueta, style: AppTexto.etiqueta),
      ],
    );
  }

  // 1.25 T117 (F1-45): tocar la foto la abre grande, como la
  // foto de la ficha (_verFotoGrande).
  void _verGrande() {
    final f = _archivo;
    if (f == null) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(AppEspacio.lg),
        child: GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadio.lg),
            child: Image.file(f, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    switch (_estado) {
      case _EstadoFoto.cargando:
        // 1.25 T117 (F1-45): cargando ya no se confunde con
        // «sin foto» (antes ambos eran el mismo hueco vacío y
        // la ficha saltaba al aparecer la foto): una línea
        // compacta lo dice mientras se verifica.
        // 1.36 FICHA (136-212): el estado de carga RESERVA
        // el alto del bloque con foto (180 de imagen +
        // cabecera) en vez de nacer compacto y recolocar
        // la pestaña al resolver.
        return const Tarjeta(
          child: SizedBox(
            height: 236,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: AppEspacio.sm),
                  Text('Foto personal: verificando…'),
                ],
              ),
            ),
          ),
        );
      case _EstadoFoto.sinFoto:
        // Sin foto: sin espacio muerto.
        return const SizedBox.shrink();
      case _EstadoFoto.error:
        // 136-212: el error también reserva el alto del
        // bloque (no recoloca la pestaña al aparecer).
        return Tarjeta(
          child: SizedBox(
            height: 236,
            child: Row(
            children: [
              Icon(
                  _falloFueDeRed
                      ? Icons.wifi_off_rounded
                      : Icons.help_outline_rounded,
                  size: 18),
              const SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                    textoErrorFotoPersonal(fueDeRed: _falloFueDeRed),
                    style: AppTexto.secundario),
              ),
              TextButton(
                  onPressed: _consultar,
                  child: const Text('Reintentar')),
            ],
            ),
          ),
        );
      case _EstadoFoto.conFoto:
        return Tarjeta(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Foto personal del cliente',
                  style: AppTexto.subtitulo.copyWith(fontWeight: FontWeight.bold)),
              Text('La que se puso en su app de cliente.',
                  style: AppTexto.secundario),
              const SizedBox(height: AppEspacio.sm),
              if (_archivo != null && widget.fotoGestion != null)
                // 1.25 T58: el par etiquetado — la de
                // gestión y la del cliente, lado a lado,
                // cada una con su visor.
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _miniaturaPar(
                        etiqueta: 'Gestión',
                        archivo: widget.fotoGestion!,
                        alTocar: widget.onVerFotoGestion,
                      ),
                    ),
                    const SizedBox(width: AppEspacio.sm),
                    Expanded(
                      child: _miniaturaPar(
                        etiqueta: 'Del cliente',
                        archivo: _archivo!,
                        alTocar: _verGrande,
                      ),
                    ),
                  ],
                )
              else if (_archivo != null)
                GestureDetector(
                  onTap: _verGrande,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadio.md),
                    child: Image.file(_archivo!,
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover),
                  ),
                )
              else
                Container(
                  // 1.36 FICHA (136-226): un solo alto
                  // (180) para el área de foto en todos
                  // sus estados — miniaturas, foto sola y
                  // error de descarga ya no hacen saltar
                  // lo de debajo.
                  height: 180,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    // 1.23 (Delta Argón 6ª): token del tema en
                    // vez de grey.shade200 fijo (parche claro en
                    // modo oscuro).
                    color: AppColores.superficieHundida(context),
                    borderRadius: BorderRadius.circular(AppRadio.md),
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
                // F1-45: fecha legible (dd/mm/aaaa), no el ISO crudo.
                Text('Actualizada: ${fmtFecha(_actualizadaEn)}',
                    style: AppTexto.secundario),
              ],
              const SizedBox(height: AppEspacio.sm),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: _retirando ? null : _retirar,
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Retirar foto'),
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColores.error),
                ),
              ),
            ],
          ),
        );
    }
  }
}
