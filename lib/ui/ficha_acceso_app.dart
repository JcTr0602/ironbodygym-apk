// lib/ui/ficha_acceso_app.dart
// 1.28 (M4, ítem fijo «ficha perezosa» + A8): las dos secciones
// de la ficha que dependen de la RED viven aquí como widgets
// con estado PROPIO. Antes el Plus residual y el caché de
// accesos se consultaban desde _FichaScreenState y cada
// respuesta hacía setState de la PANTALLA ENTERA: la lista
// completa se reconstruía por un dato de una fila (una de las
// causas del lag de scroll de la ficha). Ahora cada sección
// carga, falla y se repinta sola; la ficha ni se entera.
//
// A8 (la sección «Acceso App» dice la verdad):
// - Mientras el caché de accesos carga, la sección dice
//   «Verificando acceso…»: antes pintaba «aún no tiene
//   acceso» con el botón de generar, y tocarlo REGENERABA el
//   PIN de un cliente que SÍ tenía acceso (invalidando el
//   suyo) porque la rama «sin acceso» era también la rama
//   «aún no sé».
// - TODA generación sobre un acceso EXISTENTE (activo,
//   bloqueado, revocado o inactivo) pasa por la confirmación
//   con las consecuencias; solo la primera generación
//   VERIFICADA (caché cargado y sin registro) va directa.
// - El entrenador con permiso de generar no puede verificar
//   (el listado es solo del dueño): su botón pide
//   confirmación avisando de que no se pudo verificar, y tras
//   generar, la sección enseña el acceso recién creado en vez
//   de seguir diciendo «sin acceso».
// - El PIN se comparte al teléfono EFECTIVO del cliente
//   (móvil primero, forma wa.me): antes iba al campo
//   `telefono` crudo, que en clientes migrados puede traer el
//   carnet — el PIN viajaba al destino equivocado cuando el
//   anterior ya había quedado invalidado (R3M4-H7).
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../acceso_app_cache.dart';
import '../auth.dart';
import '../invitados.dart';
import '../negocio.dart' show fmtFecha, tiempoRelativo;
import '../plus_residual.dart';
import '../tiempo.dart';
import 'actividad_cliente.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha_secciones.dart';
import 'modal_pin_acceso.dart';
import 'panel_comunidad.dart';
import 'vista_previa_cliente.dart';
import '../errores_sync.dart';
import '../app_log.dart';
import 'acciones_acceso.dart' show mensajeOmitidoGeneracion;

/// Fila «Plus» de la tarjeta Membresía: consulta SOLA el Plus
/// residual (todo el staff autenticado, como manda la guarda
/// es_staff() de la RPC desde IMP-14) y se repinta sola al
/// llegar.
class FilaPlusResidualFicha extends StatefulWidget {
  final int clienteId;
  const FilaPlusResidualFicha({super.key, required this.clienteId});

  @override
  State<FilaPlusResidualFicha> createState() =>
      _FilaPlusResidualFichaState();
}

class _FilaPlusResidualFichaState extends State<FilaPlusResidualFicha> {
  ({bool activo, String? hasta})? _plus;
  bool _sinVerificar = false;
  bool _listo = false;

  @override
  void initState() {
    super.initState();
    _consultar();
  }

  Future<void> _consultar() async {
    // plu06_ H5a: la consulta ya no es solo del dueño —
    // la RPC responde el residual real a todo el staff
    // (es_staff()) y el entrenador debe poder devolverlo.
    // Sin sesión no hay llamador posible: se queda lista
    // y sin fila, como antes para el no-dueño.
    if (AuthService().session == null) {
      if (mounted) setState(() => _listo = true);
      return;
    }
    try {
      final res = await Supabase.instance.client
          .rpc(
            'cliente_plus_residual_staff',
            params: {'p_cliente_id': widget.clienteId},
          )
          // 1.32: 12 s, la norma de lectura de Gestión
          // (antes 8 s, fuera de norma según el barrido).
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      // Cola menor del estudio (R1M4-B7): una RPC que devuelve
      // null SIN lanzar no es «sin Plus»: es «no se pudo
      // verificar». plusResidualDe(null) cerraba en inactivo
      // silencioso y la fila desaparecía como si no hubiera
      // Plus que comprobar.
      if (res == null) {
        setState(() {
          _sinVerificar = true;
          _listo = true;
        });
        return;
      }
      setState(() {
        _plus = plusResidualDe(res);
        _listo = true;
      });
    } catch (_) {
      // 1.25 T117 (F1-41): sin red o sin la RPC, la fila dice
      // «Sin verificar en esta visita» — no verificar no es
      // lo mismo que no tener Plus.
      if (mounted) {
        setState(() {
          _sinVerificar = true;
          _listo = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1.36 H-B1 (136-528): la altura de la fila se anima
    // al aterrizar el resultado (la fila nace, cambia o
    // desaparece sin salto seco de la tarjeta).
    return AnimatedSize(
      duration: AppMovimiento.corta,
      curve: AppMovimiento.curva,
      alignment: Alignment.topCenter,
      child: _fila(context),
    );
  }

  Widget _fila(BuildContext context) {
    // 1.36 FICHA (136-196): mientras la RPC del residual
    // resuelve (hasta 12 s), la fila pinta su estado en
    // el hueco que ocupará — la tarjeta Membresía ya no
    // crece de golpe cuando el Plus aterriza.
    if (!_listo) {
      return const FilaInfoFicha(
          icono: Icons.star_rounded,
          etiqueta: 'Plus',
          // 136-528: el placeholder nombra QUÉ se verifica.
          valor: 'Verificando Plus…');
    }
    final p = _plus;
    final texto = p == null
        ? null
        : textoPlusResidual(
            activo: p.activo, hasta: p.hasta, hoyIso: hoyHabanaIso());
    if (texto != null) {
      return FilaInfoFicha(
          icono: Icons.star_rounded, etiqueta: 'Plus', valor: texto);
    }
    if (_sinVerificar && AuthService().isOwner) {
      return const FilaInfoFicha(
          icono: Icons.star_rounded,
          etiqueta: 'Plus',
          valor: 'Sin verificar en esta visita');
    }
    return const SizedBox.shrink();
  }
}

/// Sección «Acceso App» de la ficha, con su carga y sus
/// acciones locales (generar/regenerar/revocar PIN).
class SeccionAccesoAppFicha extends StatefulWidget {
  final int clienteId;
  final String nombreCliente;

  /// Teléfono efectivo en forma wa.me ('53' + 8 dígitos) para
  /// compartir el PIN; '' si el cliente no tiene válido.
  final String telefonoEfectivoWa;

  const SeccionAccesoAppFicha({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
    required this.telefonoEfectivoWa,
  });

  @override
  State<SeccionAccesoAppFicha> createState() =>
      _SeccionAccesoAppFichaState();
}

class _SeccionAccesoAppFichaState extends State<SeccionAccesoAppFicha> {
  bool _sinConexion = false;
  bool _verificando = false;
  bool _generandoPin = false;

  /// 1.29 (D-B1-09 FIJO): bandera de vuelo de la revocación
  /// (diálogo + RPC). «Regenerar PIN» y «Revocar» no la
  /// tenían: un doble toque abría dos diálogos de
  /// confirmación y la revocación podía dispararse dos
  /// veces, mientras las demás ramas sí respetaban la suya.
  bool _revocando = false;

  /// El último PIN se generó desde ESTA sección sin poder
  /// recargar el listado (entrenador): el acceso existe
  /// aunque el caché no lo enseñe.
  bool _recienGenerado = false;

  /// 1.35 (campo nº 14 de Clientes): el cliente nació de
  /// una conversión de invitado cuya confirmación — la que
  /// crea su acceso — aún no ha llegado al servidor. Su
  /// ficha lo dice («pendiente de sincronizar») en vez de
  /// ofrecer un PIN que competiría con el traslado.
  bool _conversionPendiente = false;

  @override
  void initState() {
    super.initState();
    // Solo el dueño puede cargar el listado (RPC solo-dueño);
    // el entrenador con permiso ve la rama «sin verificar».
    // 1.36 H-B1 (136-529): se refresca AL ENTRAR aunque el
    // caché ya esté cargado (antes, con el caché caliente,
    // la sección enseñaba la foto vieja sin re-verificar);
    // el «verificando» visible solo sale si aún no hay
    // caché que pintar.
    if (AuthService().isOwner) {
      _verificando = !AccesoAppCache.instance.cargado;
      unawaited(_cargarCache());
    }
    unawaited(_cargarConversionPendiente());
  }

  Future<void> _cargarConversionPendiente() async {
    try {
      final ids =
          await InvitadosService().clientesConConversionPendiente();
      if (mounted && ids.contains(widget.clienteId)) {
        setState(() => _conversionPendiente = true);
      }
    } catch (_) {}
  }

  Future<void> _cargarCache() async {
    // (Yunque R2-X1) red de seguridad: «Verificando
    // acceso…» baja SIEMPRE. AccesoAppCache.cargar ya
    // devuelve false sin lanzar en sus caminos conocidos;
    // si algo lanzara, el «verificando» quedaba eterno
    // (la clase de la ficha 2026-11-02) — y un fallo de
    // lectura NO es «sin acceso»: se lee como no
    // verificado, con su reintento visible.
    bool ok;
    try {
      ok = await AccesoAppCache.instance.cargar();
    } catch (e) {
      // El error NO se traga: queda en bitácora.
      AppLog.error('ui', 'carga_fallo', d: '$e');
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _verificando = false;
      _sinConexion = !ok && !AccesoAppCache.instance.cargado;
    });
  }

  Future<void> _reintentarCargaAcceso() async {
    if (_verificando) return;
    setState(() => _verificando = true);
    await _cargarCache();
  }

  @override
  Widget build(BuildContext context) {
    final cache = AccesoAppCache.instance;
    final acceso = cache.obtener(widget.clienteId);

    Widget contenido;
    if (acceso == null && _verificando) {
      // A8: estado «verificando» explícito — jamás la rama
      // «sin acceso» mientras no se sabe.
      contenido = const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: AppEspacio.sm),
          Text('Verificando acceso…', style: AppTexto.secundario),
        ],
      );
    } else if (acceso == null && _sinConexion && !cache.cargado) {
      // 1.36 H-B1 (136-525): la rama sin conexión es el
      // AvisoEstado de error de la casa, con su reintento
      // dentro (antes texto pelado + botón suelto).
      contenido = AvisoEstado(
        tipo: TipoAviso.error,
        texto: 'Sin conexión para verificar el acceso.',
        icono: Icons.wifi_off_rounded,
        acciones: [
          OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Reintentar'),
            onPressed: _reintentarCargaAcceso,
          ),
        ],
      );
    } else if (acceso == null && _conversionPendiente) {
      // 1.35 (campo nº 14 de Clientes): la conversión creó
      // al cliente en este teléfono y su acceso se crea al
      // confirmarse en el servidor. Sin botón de PIN: el
      // traslado de la conversión lo trae.
      contenido = const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChipEstado.semantico(
            texto: 'Pendiente de sincronizar',
            significado: SignificadoChip.info,
            icono: Icons.sync_rounded,
          ),
          SizedBox(height: AppEspacio.sm),
          Text(
              'Acceso a la app: pendiente de sincronizar. '
              'Viene de una conversión de invitado: su acceso '
              'se crea cuando la conversión se confirme en '
              'el servidor.',
              style: AppTexto.secundario),
        ],
      );
    } else if (acceso == null && _recienGenerado) {
      contenido = const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChipEstado.semantico(
            texto: 'Activo',
            significado: SignificadoChip.exito,
            icono: Icons.check_circle_rounded,
          ),
          SizedBox(height: AppEspacio.sm),
          Text('PIN recién generado desde esta ficha.',
              style: AppTexto.secundario),
        ],
      );
    } else if (acceso == null) {
      // Sin acceso VERIFICADO (dueño con el caché cargado) o
      // sin posibilidad de verificar (entrenador): el segundo
      // caso pide confirmación antes de generar (ver
      // _generarPinSinAcceso).
      final verificado = cache.cargado;
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              verificado
                  ? 'Este cliente aún no tiene acceso a la app.'
                  : 'No se pudo verificar si ya tiene acceso '
                      '(el listado solo lo ve el dueño).',
              style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          FilledButton.icon(
            icon: const Icon(Icons.key_rounded, size: 18),
            label: const Text('Generar PIN para App'),
            onPressed: _generandoPin
                ? null
                : () => _generarPinSinAcceso(verificado: verificado),
          ),
        ],
      );
    } else if (acceso.estado == 'revocado' ||
        acceso.estado == 'inactivo') {
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChipEstado.semantico(
            texto: acceso.estado == 'revocado' ? 'Revocado' : 'Inactivo',
            // 1.36 H-B1 (136-526): Revocado es un estado
            // DURO (error); Inactivo se queda neutral.
            significado: acceso.estado == 'revocado'
                ? SignificadoChip.error
                : SignificadoChip.neutral,
            icono: Icons.block_rounded,
          ),
          const SizedBox(height: AppEspacio.sm),
          // R5-M2-2: reactivar un revocado/inactivo es solo
          // del dueño: el botón ni se pinta para el resto
          // (la guarda del método manda igualmente).
          if (AuthService().isOwner)
            FilledButton.icon(
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Reactivar / Generar PIN'),
              onPressed:
                  _generandoPin ? null : _confirmarYGenerar,
            ),
        ],
      );
    } else if (acceso.estaBloqueado) {
      // Bloqueado por intentos fallidos.
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ChipEstado.semantico(
            texto: 'Bloqueado',
            significado: SignificadoChip.alerta,
            icono: Icons.lock_rounded,
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
              'Intentos fallidos: ${acceso.intentosFallidos}',
              style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          // R5-M2-2: desbloquear un acceso bloqueado TAMPOCO
          // es «generar un PIN» para un entrenador: solo el
          // dueño (misma guarda que _confirmarYGenerar).
          if (AuthService().isOwner)
            FilledButton.icon(
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: const Text('Desbloquear (Nuevo PIN)'),
              onPressed:
                  _generandoPin ? null : _confirmarYGenerar,
            ),
        ],
      );
    } else {
      // Activo.
      final ultimo = acceso.ultimoAccesoEn == null
          ? 'Nunca ha entrado'
          : 'Último acceso: ${fmtFecha(acceso.ultimoAccesoEn!.toIso8601String())}';
      contenido = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ChipEstado.semantico(
            texto: 'Activo',
            significado: SignificadoChip.exito,
            icono: Icons.check_circle_rounded,
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(ultimo, style: AppTexto.secundario),
          const SizedBox(height: AppEspacio.sm),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('Regenerar PIN'),
                  // 1.29 (D-B1-09): deshabilitado con cualquier
                  // operación en vuelo, como las demás ramas.
                  onPressed: (_generandoPin || _revocando)
                      ? null
                      : () => _confirmarRegenerar(acceso),
                ),
              ),
              // R5-M2-2: «Revocar» solo se pinta al dueño.
              if (AuthService().isOwner) ...[
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.block_rounded,
                        size: 18, color: AppColores.error),
                    label: const Text('Revocar',
                        style: TextStyle(color: AppColores.error)),
                    onPressed: (_generandoPin || _revocando)
                        ? null
                        : () => _confirmarRevocar(acceso),
                  ),
                ),
              ],
            ],
          ),
        ],
      );
    }

    // Etapa 4 · F3: «Vista previa» va DENTRO de la tarjeta, al
    // final y FUERA de las ramas de estado (el RPC no requiere
    // PIN activo).
    return Column(
      children: [
        Tarjeta(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Acceso App', style: AppTexto.titulo),
              // A14: sello honesto cuando lo pintado es la
              // última lista verificada persistida, no una
              // lectura de esta sesión.
              if (cache.esPersistido && cache.verificadoEn != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    // 1.36 H-B1 (136-524): el sello dice
                    // lo que ES — una verificación
                    // GUARDADA — sin afirmar el estado de
                    // la conexión, que esta sección no
                    // mide.
                    'Verificación guardada: '
                    '${tiempoRelativo(cache.verificadoEn!.toIso8601String())}'
                    ' · datos de otra sesión',
                    style: AppTexto.secundario,
                  ),
                ),
              const SizedBox(height: AppEspacio.sm),
              contenido,
              const SizedBox(height: AppEspacio.md),
              const Divider(height: 1),
              const SizedBox(height: AppEspacio.xs),
              // SL-2 G03-3: las tres salidas secundarias
              // (Vista previa · Comunidad · Actividad) ya NO
              // son botones a ancho completo que empujan lo
              // importante: fila compacta de texto, al final
              // de la tarjeta. Sus destinos no cambian:
              // FB-20 (Comunidad, solo dueño) y FICHA-08
              // (actividad en la app, solo dueño).
              Wrap(
                spacing: AppEspacio.xs,
                runSpacing: 0,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.preview_rounded, size: 18),
                    label: const Text('Vista previa App'),
                    onPressed: _abrirVistaPrevia,
                  ),
                  if (AuthService().isOwner)
                    TextButton.icon(
                      icon: const Icon(Icons.groups_rounded, size: 18),
                      label: const Text('Ver en Comunidad'),
                      onPressed: _verEnComunidad,
                    ),
                  if (AuthService().isOwner)
                    TextButton.icon(
                      icon: const Icon(
                          Icons.phone_android_rounded, size: 18),
                      label: const Text('Ver su actividad en la app'),
                      onPressed: _verActividadApp,
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppEspacio.md),
      ],
    );
  }

  /// A8: la primera generación SOLO va directa cuando está
  /// verificado que no hay registro. Sin verificación posible
  /// (entrenador), la confirmación avisa de que un PIN
  /// anterior, si lo hubiera, dejaría de funcionar.
  Future<void> _generarPinSinAcceso({required bool verificado}) async {
    if (!verificado) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Generar PIN'),
          content: const Text(
              'No se pudo verificar si este cliente ya tenía '
              'acceso. Si ya tenía un PIN, dejará de funcionar '
              'y su sesión se cerrará. ¿Continuar?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Generar PIN')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    await _generarPin();
  }

  /// A8: regenerar sobre un acceso EXISTENTE no activo
  /// (revocado/inactivo/bloqueado) también confirma: la RPC
  /// es la misma que regenera y sus efectos también.
  Future<void> _confirmarYGenerar() async {
    // Yunque R5-M2-2: REACTIVAR un acceso que el dueño
    // revocó no es «generar un PIN»: crear un acceso nuevo
    // para quien nunca lo tuvo sigue abierto al permiso de
    // generar (_generarPinSinAcceso), pero deshacer una
    // revocación es solo del dueño.
    if (!AuthService().isOwner) return;
    // 1.31 (Yunque A, Argón 1.30): la bandera se levanta ANTES
    // del diálogo, igual que en _confirmarRegenerar (patrón
    // D-B1-09): un doble toque rápido no abre dos
    // confirmaciones ni llega dos veces a la RPC.
    if (_generandoPin || _revocando) return;
    setState(() => _generandoPin = true);
    var confirmado = false;
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Generar PIN nuevo'),
          content: const Text(
              'Se invalidará el PIN anterior y se cerrará la '
              'sesión del cliente en su app. ¿Continuar?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Generar PIN')),
          ],
        ),
      );
      confirmado = ok == true;
    } finally {
      // Sin confirmación, la bandera cae aquí; con ella, la
      // cae el finally de _generarPinCuerpo al terminar la RPC.
      if (!confirmado && mounted) {
        setState(() => _generandoPin = false);
      }
    }
    if (confirmado && mounted) {
      await _generarPinCuerpo();
    }
  }

  Future<void> _confirmarRegenerar(AccesoCliente acceso) async {
    // 1.29 (D-B1-09): la bandera se levanta ANTES del diálogo
    // (patrón del registro de medidas): un doble toque rápido
    // no abre dos confirmaciones ni llega dos veces a la RPC.
    if (_generandoPin || _revocando) return;
    setState(() => _generandoPin = true);
    var confirmado = false;
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Regenerar PIN'),
          content: const Text(
              'Se invalidará el PIN anterior y se cerrará la sesión del cliente en su app. ¿Continuar?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar')),
            FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Regenerar')),
          ],
        ),
      );
      confirmado = ok == true;
    } finally {
      // Sin confirmación, la bandera cae aquí; con ella, la
      // cae el finally de _generarPinCuerpo al terminar la RPC.
      if (!confirmado && mounted) {
        setState(() => _generandoPin = false);
      }
    }
    if (confirmado && mounted) {
      await _generarPinCuerpo();
    }
  }

  Future<void> _confirmarRevocar(AccesoCliente acceso) async {
    // Yunque R5-M2-2: revocar es SOLO del dueño (el permiso
    // de generar PIN no alcanza): guarda en el método, como
    // el patrón de acciones_acceso.dart — no basta con que
    // el botón no se pinte.
    if (!AuthService().isOwner) return;
    // 1.29 (D-B1-09): bandera de vuelo propia cubriendo
    // diálogo + RPC — antes no había ninguna y el doble toque
    // apilaba diálogos y repetía la revocación.
    if (_revocando || _generandoPin) return;
    setState(() => _revocando = true);
    try {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Revocar acceso'),
          content: Text(
              'Se desactivará el acceso de ${acceso.nombre} a la app y se cerrará su sesión. ¿Continuar?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancelar')),
            FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: AppColores.error),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('Revocar')),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      try {
        await Supabase.instance.client
            .rpc('revocar_acceso_cliente', params: {
              'p_cliente_id': widget.clienteId,
            })
            // 1.24 Bloque 4: timeout de escritura (12 s).
            .timeout(const Duration(seconds: 12));
        // A6: la mutación invalida cualquier carga en vuelo —
        // la recarga posterior lee la foto NUEVA, no se une a
        // un vuelo anterior a la revocación.
        AccesoAppCache.instance.invalidar();
        await AccesoAppCache.instance.cargar();
        if (mounted) {
          setState(() {});
          mostrarSnack(context, 'Acceso revocado',
              significado: SignificadoChip.exito);
        }
      } catch (e) {
        if (mounted) {
          AppLog.error('ficha_acceso_app', 'revocar_fallo', d: '$e');
          mostrarSnack(context, 'Error al revocar: ${mensajeErrorAmable(e)}',
              significado: SignificadoChip.error);
        }
      }
    } finally {
      if (mounted) setState(() => _revocando = false);
    }
  }

  /// Genera (o regenera) el PIN vía RPC y muestra el modal.
  /// La guarda anti-doble-toque vive aquí (1.26): un segundo
  /// toque lanzaba dos RPC y el segundo PIN invalidaba al
  /// primero, pudiendo compartirse el inválido.
  Future<void> _generarPin() async {
    if (_generandoPin) return;
    setState(() => _generandoPin = true);
    await _generarPinCuerpo();
  }

  /// El cuerpo de la generación, con la bandera YA levantada
  /// (la levantan _generarPin o _confirmarRegenerar, que la
  /// marca antes de su diálogo — 1.29 D-B1-09); su finally
  /// siempre la baja.
  Future<void> _generarPinCuerpo() async {
    try {
      final res = await Supabase.instance.client
          .rpc('generar_acceso_cliente', params: {
            'p_cliente_id': widget.clienteId,
            'p_creado_por': AuthService().username,
          })
          // 1.24 Bloque 4: timeout de escritura (12 s).
          .timeout(const Duration(seconds: 12));
      final data = Map<String, dynamic>.from(res as Map);
      // 1.32 (H-RPC-3/B1-H2): la omisión deliberada del
      // servidor (conversión con vale vivo) trae su
      // explicación en `mensaje`: se enseña como aviso y
      // NO se invalida ni se recarga como si se hubiera
      // generado un PIN.
      final omitido = mensajeOmitidoGeneracion(data);
      if (omitido != null) {
        if (mounted) {
          mostrarSnack(context, omitido,
              significado: SignificadoChip.alerta,
              duracion: const Duration(seconds: 6));
        }
        return;
      }
      final pin = '${data['pin_temporal'] ?? ''}';
      if (pin.isEmpty) throw 'El servidor no devolvió el PIN';
      // A6: invalidar antes de recargar (foto post-mutación).
      AccesoAppCache.instance.invalidar();
      await AccesoAppCache.instance.cargar();
      if (mounted) {
        setState(() {
          _sinConexion = false;
          _recienGenerado =
              AccesoAppCache.instance.obtener(widget.clienteId) == null;
        });
        // A8/R3M4-H7: el PIN va al teléfono EFECTIVO (wa.me),
        // no al campo crudo de la ficha.
        mostrarModalPin(
            context, pin, widget.telefonoEfectivoWa, widget.nombreCliente);
      }
    } catch (e) {
      if (mounted) {
        AppLog.error('ficha_acceso_app', 'generar_pin_fallo', d: '$e');
        mostrarSnack(context, 'Error al generar PIN: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _generandoPin = false);
    }
  }

  /// Abre la vista previa de la app del cliente (F6).
  void _abrirVistaPrevia() {
    Navigator.of(context).push(
      RutaIron(
        builder: (_) => VistaPreviaClienteScreen(
          clienteId: widget.clienteId,
          nombreCliente: widget.nombreCliente,
        ),
      ),
    );
  }

  /// FB-20: salta al panel de Comunidad con el buscador
  /// filtrado por el nombre de este cliente.
  /// 1.30 (Oleada 10, FICHA-08): abre la actividad en la
  /// app de ESTE cliente (la sección de Auditoría con el
  /// cliente fijo, sin selector).
  void _verActividadApp() {
    Navigator.of(context).push(
      RutaIron(
        builder: (_) => ActividadAppPorClienteScreen(
          clienteId: widget.clienteId,
          nombreCliente: widget.nombreCliente,
        ),
      ),
    );
  }

  void _verEnComunidad() {
    Navigator.of(context).push(
      RutaIron(
        builder: (_) => ComunidadPanelScreen(
          busquedaInicial: widget.nombreCliente,
        ),
      ),
    );
  }
}
