// lib/ui/acciones_acceso.dart
// v1.4.1 (Pieza 2): acciones sobre el acceso de un cliente a la app,
// COMPARTIDAS entre la ficha del acceso (ficha_acceso.dart) y el menú
// ⋮ de la lista de Control de Acceso (control_acceso.dart). Antes las
// acciones solo vivían en la ficha; ahora ambas vías ejecutan el
// mismo código (misma confirmación, misma RPC, mismo modal del PIN).
//
// Regla de Argón (hallazgo 2.1): quien llama pasa SIEMPRE el
// BuildContext de su pantalla anfitriona, nunca el de la hoja modal
// efímera: la hoja se cierra ANTES de confirmar/ejecutar, y tras cada
// await se comprueba `mounted` antes de abrir diálogos o el modal del
// PIN. Sin esto, la RPC cambiaría el PIN en el servidor pero el modal
// con el PIN nuevo nunca se abriría (contexto desmontado).
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../acceso_app_cache.dart';
import '../tiempo.dart';
import 'diseno.dart';
import 'modal_pin_acceso.dart';

void _snack(BuildContext ctx, String mensaje) {
  if (!ctx.mounted) return;
  ScaffoldMessenger.of(ctx).showSnackBar(
    SnackBar(content: Text(mensaje)),
  );
}

void _snackError(BuildContext ctx, Object e) => _snack(ctx, 'Error: $e');

/// Confirmación estándar de las acciones de acceso (extraída de la
/// ficha, que la usaba para todas sus acciones).
Future<bool> confirmarAccionAcceso(
  BuildContext ctx,
  String titulo,
  String texto, {
  String boton = 'Continuar',
  bool peligro = false,
}) async {
  if (!ctx.mounted) return false;
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (dctx) => AlertDialog(
      title: Text(titulo),
      content: Text(texto),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: peligro
              ? FilledButton.styleFrom(backgroundColor: AppColores.error)
              : null,
          onPressed: () => Navigator.of(dctx).pop(true),
          child: Text(boton),
        ),
      ],
    ),
  );
  return ok == true;
}

/// RPC simple de acceso con confirmación opcional, recarga del anfitrión
/// (`alTerminar`) y aviso de éxito. Equivale al `_accionSimple` de la
/// ficha.
Future<void> accionSimpleAcceso(
  BuildContext ctx, {
  required int clienteId,
  required String rpc,
  required String mensajeOk,
  required Future<void> Function() alTerminar,
  bool confirmarAntes = false,
  String titulo = '',
  String texto = '',
}) async {
  if (confirmarAntes) {
    if (!await confirmarAccionAcceso(ctx, titulo, texto,
        boton: 'Sí, continuar')) {
      return;
    }
  }
  try {
    await Supabase.instance.client
        .rpc(rpc, params: {'p_cliente_id': clienteId});
    await alTerminar();
    _snack(ctx, mensajeOk);
  } catch (e) {
    _snackError(ctx, e);
  }
}

/// Resetear PIN (también es "reenviar credenciales": PIN nuevo + modal
/// con botón de WhatsApp). El PIN viejo queda invalidado.
Future<void> resetearPinAcceso(
  BuildContext ctx, {
  required int clienteId,
  required String nombre,
  required String telefono,
  required bool esReenvio,
  required Future<void> Function() alTerminar,
  String? titulo,
}) async {
  final ok = await confirmarAccionAcceso(
    ctx,
    titulo ??
        (esReenvio ? 'Reenviar credenciales' : 'Resetear PIN'),
    esReenvio
        ? 'Se generará un PIN NUEVO para $nombre (el anterior dejará '
            'de funcionar) y podrás enviárselo por WhatsApp.'
        : 'Se generará un PIN nuevo para $nombre. El anterior dejará '
            'de funcionar y su sesión se cerrará.',
    boton: 'Generar PIN nuevo',
  );
  if (!ok) return;
  try {
    final res = await Supabase.instance.client.rpc(
      'resetear_pin_cliente',
      params: {'p_cliente_id': clienteId},
    );
    final data = Map<String, dynamic>.from(res as Map);
    final pin = '${data['pin_temporal'] ?? ''}';
    if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
    await alTerminar();
    if (!ctx.mounted) return;
    mostrarModalPin(
      ctx,
      pin,
      '${data['telefono'] ?? telefono}',
      '${data['nombre'] ?? nombre}',
    );
  } catch (e) {
    _snackError(ctx, e);
  }
}

/// Bloquear el acceso con motivo y duración (diálogo de la ficha).
Future<void> bloquearAcceso(
  BuildContext ctx, {
  required int clienteId,
  required Future<void> Function() alTerminar,
}) async {
  if (!ctx.mounted) return;
  final ctrlMotivo = TextEditingController();
  var dias = 7; // -1 = indefinido
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (dctx) => StatefulBuilder(
      builder: (dctx, setLocal) => AlertDialog(
        title: const Text('Bloquear acceso'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrlMotivo,
              decoration: const InputDecoration(
                labelText: 'Motivo (opcional)',
                hintText: 'Ej.: Pago pendiente de aclarar',
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            const Text('Duración:', style: AppTexto.secundario),
            Wrap(
              spacing: 8,
              children: [
                for (final (d, et) in [
                  (1, '1 día'),
                  (7, '7 días'),
                  (30, '30 días'),
                  (-1, 'Indefinido'),
                ])
                  ChoiceChip(
                    label: Text(et),
                    selected: dias == d,
                    onSelected: (_) => setLocal(() => dias = d),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: AppColores.error),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Bloquear'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  try {
    await Supabase.instance.client.rpc(
      'bloquear_acceso_cliente',
      params: {
        'p_cliente_id': clienteId,
        'p_hasta': dias < 0
            ? null
            : isoHabana(ahoraHabana().add(Duration(days: dias))),
        'p_motivo':
            ctrlMotivo.text.trim().isEmpty ? null : ctrlMotivo.text.trim(),
      },
    );
    await alTerminar();
    _snack(ctx, 'Acceso bloqueado.');
  } catch (e) {
    _snackError(ctx, e);
  }
}

/// Cambiar el teléfono de entrada a la app (no el de la ficha del
/// cliente, que se edita en su ficha).
Future<void> cambiarTelefonoAcceso(
  BuildContext ctx, {
  required int clienteId,
  required String telefonoActual,
  required Future<void> Function() alTerminar,
}) async {
  if (!ctx.mounted) return;
  final ctrl = TextEditingController(text: telefonoActual);
  final ok = await showDialog<bool>(
    context: ctx,
    builder: (dctx) => AlertDialog(
      title: const Text('Cambiar teléfono del acceso'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: ctrl,
            keyboardType: TextInputType.phone,
            maxLength: 8,
            decoration: const InputDecoration(
              labelText: 'Nuevo teléfono (8 dígitos)',
            ),
          ),
          const Text(
            'Solo cambia el teléfono de entrada a la app. El teléfono '
            'de la ficha del cliente se edita en su ficha.',
            style: AppTexto.secundario,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dctx).pop(false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dctx).pop(true),
          child: const Text('Guardar'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await Supabase.instance.client.rpc(
      'cambiar_telefono_acceso',
      params: {
        'p_cliente_id': clienteId,
        'p_telefono': ctrl.text.trim(),
      },
    );
    await alTerminar();
    _snack(ctx, 'Teléfono actualizado.');
  } catch (e) {
    _snackError(ctx, e);
  }
}

/// Hoja de opciones rápidas de un acceso (menú ⋮ de la lista).
/// [ctx] debe ser el contexto de la pantalla anfitriona: la hoja se
/// cierra antes de ejecutar cualquier acción y todo lo posterior
/// (confirmaciones, RPC, modal del PIN) usa ese contexto.
Future<void> mostrarMenuAccionesAcceso(
  BuildContext ctx, {
  required AccesoCliente a,
  required Future<void> Function() alTerminar,
  required Future<void> Function() alAbrirFicha,
}) async {
  if (!ctx.mounted) return;
  final revocado = a.estado == 'revocado';
  final bloqueado = a.estado == 'bloqueado';

  await showModalBottomSheet<void>(
    context: ctx,
    showDragHandle: true,
    builder: (sheetCtx) {
      // La hoja se cierra con SU contexto antes de actuar (Argón 2.1);
      // las acciones reciben el contexto anfitrión [ctx].
      Widget item(
          IconData icono, String texto, Future<void> Function() accion,
          {bool peligro = false}) {
        return ListTile(
          leading: Icon(icono,
              color: peligro ? AppColores.error : null, size: 22),
          title: Text(texto,
              style: peligro
                  ? const TextStyle(color: AppColores.error)
                  : null),
          onTap: () async {
            Navigator.of(sheetCtx).pop();
            await accion();
          },
        );
      }

      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppEspacio.lg, AppEspacio.sm, AppEspacio.lg, AppEspacio.sm),
            child: Text(a.nombre, style: AppTexto.subtitulo),
          ),
          if (!revocado)
            item(
              Icons.pin,
              'Resetear PIN y compartir',
              () => resetearPinAcceso(
                ctx,
                clienteId: a.clienteId,
                nombre: a.nombre,
                telefono: a.telefono,
                esReenvio: true,
                titulo: 'Resetear PIN y compartir',
                alTerminar: alTerminar,
              ),
            ),
          if (!revocado && !bloqueado)
            item(
              Icons.lock,
              'Bloquear',
              () => bloquearAcceso(ctx,
                  clienteId: a.clienteId, alTerminar: alTerminar),
            ),
          if (!revocado && bloqueado)
            item(
              Icons.lock_open,
              'Desbloquear',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'desbloquear_acceso_cliente',
                mensajeOk: '${a.nombre} desbloqueado.',
                alTerminar: alTerminar,
              ),
            ),
          if (!revocado)
            item(
              Icons.key,
              'Forzar cambio de PIN',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'forzar_cambio_pin_cliente',
                mensajeOk:
                    'En su próximo ingreso deberá cambiar el PIN.',
                confirmarAntes: true,
                titulo: 'Forzar cambio de PIN',
                texto:
                    'En el próximo ingreso se le pedirá cambiar el PIN antes de entrar.',
                alTerminar: alTerminar,
              ),
            ),
          if (!revocado)
            item(
              Icons.logout,
              'Cerrar sesión remota',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'cerrar_sesion_cliente',
                mensajeOk: 'Sesión cerrada. Deberá entrar de nuevo.',
                confirmarAntes: true,
                titulo: 'Cerrar sesión remota',
                texto:
                    'Su sesión actual dejará de funcionar al instante.',
                alTerminar: alTerminar,
              ),
            ),
          if (!revocado)
            item(
              Icons.phone,
              'Cambiar teléfono',
              () => cambiarTelefonoAcceso(
                ctx,
                clienteId: a.clienteId,
                telefonoActual: a.telefono,
                alTerminar: alTerminar,
              ),
            ),
          if (!revocado)
            item(
              Icons.block,
              'Revocar acceso',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'revocar_acceso_cliente',
                mensajeOk: 'Acceso revocado.',
                confirmarAntes: true,
                titulo: 'Revocar acceso',
                texto:
                    'El cliente ya no podrá entrar a la app. Puedes reactivarlo cuando quieras.',
                alTerminar: alTerminar,
              ),
              peligro: true,
            ),
          if (revocado)
            item(
              Icons.restore,
              'Reactivar acceso',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'reactivar_acceso_cliente',
                mensajeOk: 'Acceso reactivado.',
                alTerminar: alTerminar,
              ),
            ),
            const Divider(),
            item(Icons.person, 'Abrir ficha', alAbrirFicha),
          ],
        ),
      );
    },
  );
}
