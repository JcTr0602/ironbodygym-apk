/// 1.25 T84: EL flujo de cierre de turno, en un solo
/// sitio. El hub de turnos lo usa entero (con su diálogo
/// de confirmación); Mi Turno usa la misma ejecución y
/// el mismo texto de error dentro de su hoja de cierre.
/// Antes cada pantalla tenía su copia del preparar →
/// confirmar, y de esa divergencia nació el «cierre de
/// mentira» que T-08 tuvo que cerrar a mano.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../turno_service.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'primitivas.dart';
import 'permisos_ui.dart';
import 'tarjeta_imagen.dart';

/// 1.22 T-08: texto del motivo cuando hay turno abierto
/// pero el cierre no se pudo ejecutar. PURO.
String motivoErrorCierre(Object? error) {
  // Autoauditoría 1.25 ronda 2: el turno que existía al
  // preparar y ya no está al confirmar (reconciliación
  // del turno_id entre ambos pasos).
  if ('$error' == 'turno_no_existe') {
    return 'El turno ya no aparece en este teléfono: '
        'pudo cerrarse desde otro flujo. Actualiza la '
        'pantalla e inténtalo de nuevo.';
  }
  return '$error' == 'sin_turno_abierto'
      ? 'El turno ya no está abierto: pudo cerrarse '
          'desde otro flujo. Actualiza la pantalla e '
          'inténtalo de nuevo.'
      : 'No se pudo preparar el cierre: '
          '${error ?? 'motivo desconocido'}';
}

/// Ejecuta el cierre del turno abierto del usuario:
/// prepararCierre + confirmarCierre. [forzado] manda si
/// viene dado; si no, se deriva de la limpieza que
/// reporta la preparación (hay pendientes = forzado).
/// Devuelve (ok: true) o (ok: false, error: motivo).
Future<({bool ok, String? error})> ejecutarCierreTurno(
    {bool? forzado}) async {
  final abierto = await TurnoService.instance.turnoActual();
  if (abierto == null) {
    return (ok: false, error: 'sin_turno_abierto');
  }
  final prep = await TurnoService.instance.prepararCierre();
  if (prep['ok'] != true) {
    return (ok: false, error: '${prep['error'] ?? 'preparacion'}');
  }
  // Autoauditoría 1.25 ronda 2: el resultado de
  // confirmarCierre SE MIRA (antes se ignoraba y el
  // flujo devolvía éxito siempre: un «cierre de
  // mentira» si el turno se reconciliaba entre
  // preparar y confirmar).
  final conf = await TurnoService.instance.confirmarCierre(
    turnoId: '${prep['turnoId']}',
    forzado: forzado ?? prep['limpio'] != true,
  );
  if (conf['ok'] != true) {
    return (ok: false, error: '${conf['error'] ?? 'confirmacion'}');
  }
  return (ok: true, error: null);
}

/// El flujo completo con diálogo (el del hub): prepara,
/// confirma con el resumen del día y cierra. Avisa por
/// mostrarSnack cuando no hay turno abierto. Devuelve
/// true SOLO si el turno quedó cerrado.
Future<bool> cerrarTurnoConDialogo(BuildContext context) async {
  // 1.25 cierre (autoauditoría ronda 2): la compuerta
  // de gestionar turnos vive TAMBIÉN aquí, para que
  // todo llamador del diálogo la herede (el hub no la
  // aplicaba; Mi Turno y Home aplican la suya).
  if (!await permisoOperativoOkConRefresco(context,
      () => PermisosEntrenador().canGestionarTurnos, 'gestionar turnos')) {
    return false;
  }
  final prep = await TurnoService.instance.prepararCierre();
  if (prep['ok'] != true) {
    if (context.mounted) {
      mostrarSnack(context, 'No hay turno abierto para cerrar.');
    }
    return false;
  }
  if (!context.mounted) return false;
  final limpio = prep['limpio'] == true;
  // 1.32 (O2F2, Pieza 4): cerrar la caja del día ya no se
  // confirma con un toque: el resumen se lee y se DESLIZA
  // (confirmarDeslizando). La ejecución del cierre
  // (confirmarCierre con su mirada al resultado) no
  // cambia ni una línea.
  final ok = await confirmarDeslizando(
    context,
    titulo: 'Cerrar turno',
    mensaje: 'Cobrado del día: ${prep['pagosCount']} pago(s). '
        'Pendientes sin sincronizar: ${prep['pendientesCount']} '
        '(${fmtMonto((prep['pendientesCup'] as num).toDouble())} CUP'
        '${(prep['pendientesUsd'] as num) > 0 ? ' + ${fmtMonto((prep['pendientesUsd'] as num).toDouble())} USD' : ''})'
        '${(prep['revisionCount'] as int) > 0 ? ', ${prep['revisionCount']} en revisión' : ''}.'
        '${limpio ? '' : ' Cerrar de todos modos deja los pendientes guardados en este teléfono.'}',
    textoDeslizar: limpio
        ? 'Desliza para cerrar el turno'
        : 'Desliza para cerrar de todos modos',
    textoConfirmando: 'Cerrando…',
    icono: Icons.lock_rounded,
  );
  if (!ok) return false;
  // Autoauditoría 1.25 ronda 2: éxito solo si el
  // servicio confirma el cierre.
  final conf = await TurnoService.instance.confirmarCierre(
    turnoId: '${prep['turnoId']}',
    forzado: !limpio,
  );
  if (conf['ok'] != true) {
    if (context.mounted) {
      mostrarSnack(context, motivoErrorCierre(conf['error']),
          significado: SignificadoChip.error);
    }
    return false;
  }
  // 1.35 (UX-15): con el turno YA cerrado, su tarjeta de
  // cierre — el resumen con presencia en el lenguaje del
  // recibo (UX-05). Nace DESPUÉS de la confirmación y
  // solo pinta lo que el propio cierre ya calculó al
  // preparar (pagos del turno y pendientes de
  // sincronizar con su monto): el cobrado total y el
  // «pendiente a entregar» NO los calcula el cierre y
  // la tarjeta no los inventa.
  if (context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TarjetaCierreTurnoScreen(prep: prep),
    ));
  }
  return true;
}

/// 1.35 (UX-15): la pantalla-resumen «Así quedó tu
/// turno». Recibe el mapa de `prepararCierre` TAL CUAL
/// (la foto que el cierre calculó) y la compone como
/// tarjeta en el lenguaje del recibo: cabecera grafito
/// de la plantilla, filas de datos y el pie firmado —
/// la misma tarjeta es la que se fotografía para
/// compartirla al dueño.
class TarjetaCierreTurnoScreen extends StatefulWidget {
  final Map<String, dynamic> prep;

  const TarjetaCierreTurnoScreen({super.key, required this.prep});

  @override
  State<TarjetaCierreTurnoScreen> createState() =>
      _TarjetaCierreTurnoScreenState();
}

class _TarjetaCierreTurnoScreenState
    extends State<TarjetaCierreTurnoScreen> {
  final _tarjetaKey = GlobalKey();
  bool _compartiendo = false;

  int get _pagos => (widget.prep['pagosCount'] as num?)?.toInt() ?? 0;
  int get _pendientes =>
      (widget.prep['pendientesCount'] as num?)?.toInt() ?? 0;
  double get _pendientesCup =>
      (widget.prep['pendientesCup'] as num?)?.toDouble() ?? 0;
  double get _pendientesUsd =>
      (widget.prep['pendientesUsd'] as num?)?.toDouble() ?? 0;
  int get _revision =>
      (widget.prep['revisionCount'] as num?)?.toInt() ?? 0;

  String get _turnoEtiqueta {
    final fecha = '${widget.prep['fechaTurno'] ?? ''}';
    final turno = '${widget.prep['turno'] ?? ''}'.trim();
    final apertura = '${widget.prep['horaApertura'] ?? ''}';
    final hora =
        apertura.length >= 16 ? apertura.substring(11, 16) : apertura;
    return [
      if (fecha.isNotEmpty) fecha,
      if (turno.isNotEmpty) turno,
      if (hora.isNotEmpty) 'desde las $hora',
    ].join(' · ');
  }

  String get _textoCompartir {
    final b = StringBuffer('Cierre de turno — Iron Body Gym');
    if (_turnoEtiqueta.isNotEmpty) b.write('\n$_turnoEtiqueta');
    // E3 (C4-01): la cifra es del DÍA (conteoPagosDia), no
    // del turno — el rótulo lo dice, como el diálogo del
    // mismo flujo («Cobrado del día»).
    b.write('\nPagos del día: $_pagos');
    if (_pendientes > 0) {
      b.write('\nPendientes sin sincronizar: $_pendientes '
          '(${fmtMonto(_pendientesCup)} CUP'
          '${_pendientesUsd > 0 ? ' + ${fmtMonto(_pendientesUsd)} USD' : ''})');
    }
    if (_revision > 0) b.write('\nEn revisión: $_revision');
    return b.toString();
  }

  Future<void> _compartir() async {
    if (_compartiendo) return;
    setState(() => _compartiendo = true);
    try {
      final boundary = _tarjetaKey.currentContext!
          .findRenderObject() as RenderRepaintBoundary;
      final imagen = await boundary.toImage(pixelRatio: 3.0);
      final datos =
          await imagen.toByteData(format: ui.ImageByteFormat.png);
      if (datos == null) throw 'sin imagen';
      final dir = await getTemporaryDirectory();
      final f = await File('${dir.path}/cierre_turno.png')
          .writeAsBytes(datos.buffer.asUint8List());
      await Share.shareXFiles([XFile(f.path)],
          text: _textoCompartir);
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo compartir la imagen',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _compartiendo = false);
    }
  }

  Widget _fila(String etiqueta, String valor) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(etiqueta, style: AppTexto.secundario),
          const SizedBox(width: 16),
          Flexible(
            child: Text(
              valor,
              style: AppTexto.cuerpo
                  .copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Cierre de turno'),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppEspacio.xl),
          child: Column(
            children: [
              const SizedBox(height: AppEspacio.lg),
              // La marca de hecho en el anillo de marca,
              // como en el recibo (UX-05).
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: AppColores.naranja.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppColores.naranja, width: 3),
                ),
                child: const Icon(Icons.check_circle_rounded,
                    size: 52, color: AppColores.exito),
              ),
              const SizedBox(height: AppEspacio.lg),
              Text('Así quedó tu turno',
                  style: AppTexto.displayPequeno.copyWith(
                      color: AppColores.texto(context))),
              if (_turnoEtiqueta.isNotEmpty) ...[
                const SizedBox(height: AppEspacio.xs),
                Text(_turnoEtiqueta,
                    style: AppTexto.secundario,
                    textAlign: TextAlign.center),
              ],
              const SizedBox(height: AppEspacio.xl),
              RepaintBoundary(
                key: _tarjetaKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColores.superficie(context),
                    borderRadius:
                        BorderRadius.circular(AppRadio.lg),
                    border:
                        Border.all(color: AppColores.borde(context)),
                  ),
                  child: Column(
                    children: [
                      const CabeceraTarjetaIron(),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            16, 8, 16, 4),
                        child: Column(
                          children: [
                            _fila('Pagos del día', '$_pagos'),
                            // Las filas en cero no
                            // aparecen (regla de Jc).
                            if (_pendientes > 0) ...[
                              const Divider(),
                              _fila(
                                  'Pendientes sin sincronizar',
                                  '$_pendientes · '
                                      '${fmtMonto(_pendientesCup)} CUP'
                                      '${_pendientesUsd > 0 ? ' + ${fmtMonto(_pendientesUsd)} USD' : ''}'),
                            ],
                            if (_revision > 0) ...[
                              const Divider(),
                              _fila('En revisión', '$_revision'),
                            ],
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            16, 8, 16, 12),
                        child: PieTarjetaImagen(
                          colorPrincipal: AppColores.texto(context),
                          colorSuave:
                              AppColores.textoSecundario(context),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppEspacio.xl),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.share_rounded),
                  label: Text(_compartiendo
                      ? 'Compartiendo…'
                      : 'Compartir al dueño'),
                  onPressed: _compartiendo ? null : _compartir,
                ),
              ),
              const SizedBox(height: AppEspacio.sm),
              SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Listo'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
