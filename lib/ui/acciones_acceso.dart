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
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../negocio.dart' show validarTelefono, sanitizarTelefono;
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'modal_pin_acceso.dart';

void _snack(BuildContext ctx, String mensaje) {
  if (!ctx.mounted) return;
  mostrarSnack(ctx, mensaje);
}

/// 1.32 (H-RPC-3/B1-H2): el mensaje que la generación
/// INDIVIDUAL de acceso debe enseñar cuando el servidor
/// OMITE la generación a propósito (conversión con vale de
/// canje vivo): la explicación del propio servidor
/// (`mensaje`), como aviso — no el error genérico «El
/// servidor no devolvió el PIN», que hacía al dueño
/// reintentar durante horas creyendo que era la conexión.
/// Devuelve null si la respuesta NO es una omisión (trae
/// PIN o es otro desenlace): el llamador sigue su curso.
String? mensajeOmitidoGeneracion(Map<String, dynamic> data) {
  if (data['omitido'] != true) return null;
  final m = '${data['mensaje'] ?? ''}'.trim();
  return m.isEmpty
      ? 'El servidor omitió la generación del PIN para este cliente.'
      : m;
}

/// 1.28 (M4-A5/R2M4-H1): guarda «en curso» del helper
/// COMPARTIDO (patrón de reportes_plus). Las acciones de un
/// mismo cliente se ejecutan DE UNA EN UNA: un segundo toque
/// con la confirmación o la RPC de la primera aún en vuelo se
/// rechaza con aviso, en vez de apilar dos diálogos o dos
/// mutaciones sobre el mismo acceso. La guarda cubre el flujo
/// ENTERO (confirmación incluida) y se libera en finally.
final Set<int> _accesoEnCurso = <int>{};

/// ¿Hay una acción de acceso en curso para este cliente?
bool accesoAccionEnCurso(int clienteId) =>
    _accesoEnCurso.contains(clienteId);

Future<void> _conGuardaAcceso(
  BuildContext ctx,
  int clienteId,
  Future<void> Function() accion,
) async {
  if (!_accesoEnCurso.add(clienteId)) {
    _snack(ctx,
        'Ya hay una acción en curso para este cliente; espera a que termine.');
    return;
  }
  // 1.36 H-C1 (136-453): señal de procesamiento — tras
  // cerrar la hoja, la RPC puede tardar hasta 12 s y el
  // primer aviso ya no es el final: se dice que corre.
  // El aviso final la reemplaza (el helper no encola).
  _snack(ctx, 'Procesando…');
  try {
    await accion();
  } finally {
    _accesoEnCurso.remove(clienteId);
  }
}

/// Autoauditoría 1.22 #2 (P-3): guarda de dueño COMPARTIDA.
/// Todas las acciones de este archivo son operaciones del
/// dueño; los llamadores ya filtran la UI, pero la función
/// compartida es el hogar natural de la guarda (defensa en
/// profundidad, fail-closed): si una vía futura la invoca sin
/// filtrar, no ejecuta la RPC.
bool _soloDueno(BuildContext ctx) {
  if (AuthService().isOwner) return true;
  _snackError(ctx, 'Solo el dueño puede hacer esto');
  return false;
}

/// 1.36 H-B1 (136-451): el error crudo («Error: $e») no le
/// dice nada al dueño — se mapea a su causa en sencillo:
/// tiempo agotado, red o el mensaje del servidor.
String mensajeErrorAcceso(Object e) {
  if (e is String) return e;
  if (e is TimeoutException) {
    return 'Se acabó el tiempo de espera. Revisa tu conexión '
        'e inténtalo de nuevo.';
  }
  if (e is PostgrestException) {
    final m = e.message.trim();
    if (m.isNotEmpty) return m;
  }
  final s = '$e'.toLowerCase();
  if (s.contains('socket') ||
      s.contains('network') ||
      s.contains('failed host lookup') ||
      s.contains('connection') ||
      s.contains('timeout')) {
    return 'Sin conexión: no se pudo completar la acción.';
  }
  return 'No se pudo completar la acción. Inténtalo de nuevo.';
}

void _snackError(BuildContext ctx, Object e) {
  if (!ctx.mounted) return;
  mostrarSnack(ctx, mensajeErrorAcceso(e),
      significado: SignificadoChip.error);
}

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
  // 1.36 H-B1 (136-452): el peligro de la acción llega
  // hasta su confirmación (botón en rojo).
  bool peligro = false,
}) =>
    // 1.28 (M4-A5): guarda compartida anti-doble-acción.
    _conGuardaAcceso(
      ctx,
      clienteId,
      () => _accionSimpleAccesoInterna(
        ctx,
        clienteId: clienteId,
        rpc: rpc,
        mensajeOk: mensajeOk,
        alTerminar: alTerminar,
        confirmarAntes: confirmarAntes,
        titulo: titulo,
        texto: texto,
        peligro: peligro,
      ),
    );

Future<void> _accionSimpleAccesoInterna(
  BuildContext ctx, {
  required int clienteId,
  required String rpc,
  required String mensajeOk,
  required Future<void> Function() alTerminar,
  bool confirmarAntes = false,
  String titulo = '',
  String texto = '',
  bool peligro = false,
}) async {
  if (!_soloDueno(ctx)) return;
  if (confirmarAntes) {
    if (!await confirmarAccionAcceso(ctx, titulo, texto,
        boton: 'Sí, continuar', peligro: peligro)) {
      return;
    }
    // Guarda de ciclo de vida (panel R2): si el anfitrión se desmontó
    // con la confirmación abierta, no ejecutar la RPC.
    if (!ctx.mounted) return;
  }
  try {
    await Supabase.instance.client
        .rpc(rpc, params: {'p_cliente_id': clienteId})
        // 1.24 Bloque 4: toda RPC de escritura con timeout (12 s).
        .timeout(const Duration(seconds: 12));
    if (!ctx.mounted) return;
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
  required bool? esReenvio,
  required Future<void> Function() alTerminar,
  String? titulo,
}) =>
    // 1.28 (M4-A5): guarda compartida anti-doble-acción.
    _conGuardaAcceso(
      ctx,
      clienteId,
      () => _resetearPinAccesoInterna(
        ctx,
        clienteId: clienteId,
        nombre: nombre,
        telefono: telefono,
        esReenvio: esReenvio,
        alTerminar: alTerminar,
        titulo: titulo,
      ),
    );

Future<void> _resetearPinAccesoInterna(
  BuildContext ctx, {
  required int clienteId,
  required String nombre,
  required String telefono,
  required bool? esReenvio,
  required Future<void> Function() alTerminar,
  String? titulo,
}) async {
  if (!_soloDueno(ctx)) return;
  // 1.25 T119 (F3-25): esReenvio == null = la confirmación misma
  // ofrece las dos salidas (ver el PIN aquí o prepararlo para
  // WhatsApp). Antes la ficha tenía DOS botones («Resetear PIN»
  // y «Reenviar credenciales») que ejecutaban esta misma función
  // cambiando solo el texto de este diálogo: la RPC y el
  // resultado (el modal con el PIN, que ya deja compartirlo)
  // eran idénticos.
  if (esReenvio == null) {
    if (!ctx.mounted) return;
    final modo = await showDialog<bool>(
      context: ctx,
      builder: (dctx) => AlertDialog(
        title: Text(titulo ?? 'Restablecer acceso'),
        content: Text(
          'Se generará un PIN NUEVO para $nombre. El anterior '
          'dejará de funcionar y su sesión se cerrará. Al '
          'terminar verás el PIN y podrás enviárselo por '
          'WhatsApp desde la misma ventana.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Generar PIN nuevo'),
          ),
        ],
      ),
    );
    if (modo != true) return;
  } else {
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
  }
  // Guarda de ciclo de vida (panel R2): con el anfitrión desmontado,
  // la RPC invalidaría el PIN viejo sin poder mostrar el nuevo.
  if (!ctx.mounted) return;
  try {
    final res = await Supabase.instance.client
        .rpc(
          'resetear_pin_cliente',
          params: {'p_cliente_id': clienteId},
        )
        // 1.24 Bloque 4: timeout de escritura (12 s).
        .timeout(const Duration(seconds: 12));
    final data = Map<String, dynamic>.from(res as Map);
    final pin = '${data['pin_temporal'] ?? ''}';
    if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
    if (!ctx.mounted) return;
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
}) =>
    // 1.28 (M4-A5): guarda compartida anti-doble-acción.
    _conGuardaAcceso(
      ctx,
      clienteId,
      () => _bloquearAccesoInterna(
        ctx,
        clienteId: clienteId,
        alTerminar: alTerminar,
      ),
    );

Future<void> _bloquearAccesoInterna(
  BuildContext ctx, {
  required int clienteId,
  required Future<void> Function() alTerminar,
}) async {
  if (!_soloDueno(ctx)) return;
  if (!ctx.mounted) return;
  final datos = await showDialog<({int dias, String motivo})>(
    context: ctx,
    builder: (dctx) => const _DialogoBloquearAcceso(),
  );
  if (datos == null) return;
  if (!ctx.mounted) return;
  final dias = datos.dias;
  final motivo =
      datos.motivo.trim().isEmpty ? null : datos.motivo.trim();
  try {
    await Supabase.instance.client
        .rpc(
          'bloquear_acceso_cliente',
          params: {
            'p_cliente_id': clienteId,
            // 1.28 (M4-A5/R1M4-B16): la duración es de
            // CALENDARIO (misma hora, N días después), no
            // 24 h × N sobre el reloj: cruzando el cambio de
            // hora, «1 día» duraba 23 o 25 horas reales.
            'p_hasta': dias < 0
                ? null
                : isoHabana(sumarDiasCalendario(ahoraHabana(), dias)),
            'p_motivo': motivo,
          },
        )
        // 1.24 Bloque 4: timeout de escritura (12 s).
        .timeout(const Duration(seconds: 12));
    if (!ctx.mounted) return;
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
}) =>
    // 1.28 (M4-A5): guarda compartida anti-doble-acción.
    _conGuardaAcceso(
      ctx,
      clienteId,
      () => _cambiarTelefonoAccesoInterna(
        ctx,
        clienteId: clienteId,
        telefonoActual: telefonoActual,
        alTerminar: alTerminar,
      ),
    );

Future<void> _cambiarTelefonoAccesoInterna(
  BuildContext ctx, {
  required int clienteId,
  required String telefonoActual,
  required Future<void> Function() alTerminar,
}) async {
  if (!_soloDueno(ctx)) return;
  if (!ctx.mounted) return;
  final texto = await showDialog<String>(
    context: ctx,
    builder: (dctx) =>
        _DialogoCambiarTelefonoAcceso(telefonoActual: telefonoActual),
  );
  if (texto == null) return;
  if (!ctx.mounted) return;
  // Yunque B (YB-CLI-11): a la RPC viaja el teléfono
  // SANITIZADO (8 dígitos), no el texto crudo del campo.
  final nuevoTelefono = sanitizarTelefono(texto) ?? '';
  // 1.28 (M4-A5/R1M4-B18): validación LOCAL de la casa (8
  // dígitos empezando por 5 o 6) ANTES de la RPC — el campo
  // solo limitaba el largo al teclear (maxLength) y un valor
  // pegado o corto llegaba al servidor y rebotaba como un
  // error genérico sin decir qué estaba mal.
  if (!validarTelefono(nuevoTelefono)) {
    _snack(ctx,
        'Teléfono inválido: 8 dígitos empezando con 5 o 6.');
    return;
  }
  try {
    await Supabase.instance.client
        .rpc(
          'cambiar_telefono_acceso',
          params: {
            'p_cliente_id': clienteId,
            'p_telefono': nuevoTelefono,
          },
        )
        // 1.24 Bloque 4: timeout de escritura (12 s).
        .timeout(const Duration(seconds: 12));
    if (!ctx.mounted) return;
    await alTerminar();
    _snack(ctx, 'Teléfono actualizado.');
  } catch (e) {
    _snackError(ctx, e);
  }
}

/// 1.28 (M4-B1): puerta de entrada al menú de acceso desde
/// una FILA (pulsación larga en Listas, menú rápido en
/// Buscar). Resuelve el acceso del cliente desde el caché
/// (cargándolo si hace falta) y abre EL MISMO menú del
/// helper A5 — nada de una segunda vía sin guarda. Si el
/// cliente NO tiene acceso verificado, el alta vive en la
/// sección «Acceso App» de su ficha (con las guardas de
/// A8): se delega en [alDarAcceso]. Sin caché ni red, se
/// dice la verdad en vez de adivinar un estado. Solo dueño:
/// el dominio de accesos es suyo (la ficha sigue siendo la
/// vía del entrenador con permiso de generar PIN).
Future<void> abrirMenuAccesoDesdeLista(
  BuildContext ctx, {
  required int clienteId,
  required Future<void> Function() alTerminar,
  required Future<void> Function() alAbrirFicha,
  required Future<void> Function() alDarAcceso,
}) async {
  if (!_soloDueno(ctx)) return;
  if (!AccesoAppCache.instance.cargado) {
    await AccesoAppCache.instance.cargar();
    if (!ctx.mounted) return;
  }
  final a = AccesoAppCache.instance.obtener(clienteId);
  // 1.36 H-B1 (136-449): con la foto PERSISTIDA (guardada,
  // sin verificar en esta sesión) no se ofrecen acciones
  // de acceso sobre datos sin confirmar — se avisa «sin
  // conexión» y la vía es la ficha, como en la rama sin
  // dato de abajo.
  if (a != null && AccesoAppCache.instance.esPersistido) {
    _snack(ctx,
        'Sin conexión: el acceso guardado no está verificado; abre su ficha.');
    return;
  }
  if (a != null) {
    await mostrarMenuAccionesAcceso(
      ctx,
      a: a,
      alTerminar: alTerminar,
      alAbrirFicha: alAbrirFicha,
    );
  } else if (AccesoAppCache.instance.cargado) {
    await alDarAcceso();
  } else {
    _snack(ctx,
        'Sin conexión para verificar el acceso; abre su ficha.');
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
  // 1.28 (M4-A6): un acceso INACTIVO (no revocado) también
  // ofrece «Reactivar acceso»; antes la etiqueta única
  // 'revocado' lo escondía en esa misma rama.
  final inactivo = a.estado == 'inactivo';
  final bloqueado = a.estado == 'bloqueado';

  // Panel R2 (Luna): la hoja solo ANOTA la opción elegida y se
  // cierra; la acción se ejecuta cuando showModalBottomSheet ya
  // terminó, nunca sobre la transición de cierre de la hoja.
  Future<void> Function()? elegida;

  await showModalBottomSheet<void>(
    context: ctx,
    showDragHandle: true,
    builder: (sheetCtx) {
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
          onTap: () {
            elegida = accion;
            Navigator.of(sheetCtx).pop();
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
              Icons.pin_rounded,
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
              Icons.lock_rounded,
              'Bloquear',
              () => bloquearAcceso(ctx,
                  clienteId: a.clienteId, alTerminar: alTerminar),
            ),
          if (!revocado && bloqueado)
            item(
              Icons.lock_open_rounded,
              'Desbloquear',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'desbloquear_acceso_cliente',
                mensajeOk: '${a.nombre} desbloqueado.',
                // 1.25 T88: desbloquear pide la MISMA
                // confirmacion en las tres puertas (lista,
                // menu y ficha); era la unica accion del
                // menu que entraba sin preguntar.
                confirmarAntes: true,
                titulo: 'Desbloquear acceso',
                texto: '¿Desbloquear el acceso de ${a.nombre}?',
                alTerminar: alTerminar,
              ),
            ),
          if (!revocado)
            item(
              Icons.key_rounded,
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
              Icons.logout_rounded,
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
              Icons.phone_rounded,
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
              Icons.block_rounded,
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
                // 136-452: el peligro también va DENTRO de
                // la acción, no solo en la fila del menú.
                peligro: true,
              ),
              peligro: true,
            ),
          if (revocado || inactivo)
            item(
              Icons.restore_rounded,
              'Reactivar acceso',
              () => accionSimpleAcceso(
                ctx,
                clienteId: a.clienteId,
                rpc: 'reactivar_acceso_cliente',
                mensajeOk: 'Acceso reactivado.',
                // 1.28 (M4-A5/R1M4-M14): reactivar también
                // confirma — era la única acción del menú
                // que entraba sin preguntar.
                confirmarAntes: true,
                titulo: 'Reactivar acceso',
                texto:
                    '¿Reactivar el acceso de ${a.nombre}? Podrá entrar a la app con su PIN actual.',
                alTerminar: alTerminar,
              ),
            ),
            const Divider(),
            item(Icons.person_rounded, 'Abrir ficha', alAbrirFicha),
          ],
        ),
      );
    },
  );

  if (elegida != null && ctx.mounted) {
    try {
      await elegida!();
    } catch (e) {
      _snackError(ctx, e);
    }
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Bloquear acceso» como
/// StatefulWidget propio: posee y dispone el controlador del
/// motivo (antes se creaba en la función y nunca se liberaba;
/// disponerlo tras showDialog estaba prohibido por Argón
/// G-05). Devuelve días y motivo al bloquear, o null.
class _DialogoBloquearAcceso extends StatefulWidget {
  const _DialogoBloquearAcceso();

  @override
  State<_DialogoBloquearAcceso> createState() =>
      _DialogoBloquearAccesoState();
}

class _DialogoBloquearAccesoState
    extends State<_DialogoBloquearAcceso> {
  final _ctrlMotivo = TextEditingController();
  var _dias = 7; // -1 = indefinido

  @override
  void dispose() {
    _ctrlMotivo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bloquear acceso'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _ctrlMotivo,
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
                  selected: _dias == d,
                  onSelected: (_) => setState(() => _dias = d),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: AppColores.error),
          onPressed: () => Navigator.of(context)
              .pop((dias: _dias, motivo: _ctrlMotivo.text)),
          child: const Text('Bloquear'),
        ),
      ],
    );
  }
}

/// 1.30 (Oleada 7, clase B): diálogo «Cambiar teléfono del
/// acceso» como StatefulWidget propio: posee y dispone su
/// controlador (antes se creaba en la función y nunca se
/// liberaba). Devuelve el texto escrito o null si se cancela.
class _DialogoCambiarTelefonoAcceso extends StatefulWidget {
  final String telefonoActual;
  const _DialogoCambiarTelefonoAcceso(
      {required this.telefonoActual});

  @override
  State<_DialogoCambiarTelefonoAcceso> createState() =>
      _DialogoCambiarTelefonoAccesoState();
}

class _DialogoCambiarTelefonoAccesoState
    extends State<_DialogoCambiarTelefonoAcceso> {
  late final TextEditingController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.telefonoActual);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambiar teléfono del acceso'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.phone,
            // Yunque 3 (K5-5): SIN maxLength — la clase exacta
            // de D-6 (Y2) que la corrección del diálogo
            // compartido no alcanzó en este diálogo privado.
            // Con 8, pegar «5358191577» se truncaba a
            // «53581915» ANTES de sanitizar y ese número
            // equivocado pero «válido» quedaba como teléfono
            // de acceso del cliente. Quien juzga es
            // sanitizarTelefono al guardar
            // (_cambiarTelefonoAccesoInterna), que acepta el
            // prefijo 53 y los espacios; la etiqueta «8
            // dígitos» queda como ayuda.
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: const Text('Guardar'),
        ),
      ],
    );
  }
}
