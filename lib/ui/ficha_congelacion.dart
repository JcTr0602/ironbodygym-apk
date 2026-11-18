/// Sección de congelación en la ficha del cliente
/// (Congelación 0.5, M2 — punto único, cualquier rol).
///
/// - Dueño: lee el espejo local. Si hay una solicitud
///   PENDIENTE, avisa y lleva a la bandeja a resolverla; si
///   hay una APROBADA, muestra el sello «❄️ Congelación
///   aprobada» con su ventana y el botón «Cerrar ahora».
/// - Entrenador: su espejo jamás contiene estas filas (el
///   motivo es privado). Lee la RPC congelacion_vigente_staff,
///   que solo devuelve la VENTANA de la pausa aprobada — sin
///   motivo ni categoría — y ofrece el mismo «Cerrar ahora»
///   (el cierre es de staff: es_staff() en el servidor).
///
/// Sin nada vigente, la sección no ocupa espacio. La lectura
/// remota del staff va DESPUÉS de pintar la ficha (widget con
/// estado propio, como SeccionAccesoAppFicha) y con timeout:
/// un fallo la deja invisible, nunca bloquea la ficha.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../congelaciones_gestion.dart';
import '../errores_sync.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'congelaciones.dart';

/// SL-2 G03-11: mensaje del snack cuando el cierre de la
/// congelación falla. El error del servidor (res['error'])
/// NUNCA se pinta crudo — códigos SQL y claves internas no
/// son texto para el staff —: la rama amable es la misma
/// para todos los fallos del cierre. El detalle técnico lo
/// conserva quien llama si lo registra en bitácora.
String mensajeCierreCongelacionFallido(Object? errorServidor) =>
    'No se pudo cerrar la congelación. Inténtalo de nuevo.';

/// 1.36 H-B1 (136-532): el texto de confirmación del
/// cierre se CALCULA según la vigencia real — futura (se
/// cancela con 0 días) o en curso (días hasta ayer, con
/// los ya materializados dichos) — no un texto fijo que
/// mezclaba ambos casos.
String textoCierreCongelacion({
  required DateTime hoy,
  DateTime? inicio,
  int diasYaAplicados = 0,
}) {
  final h = DateTime(hoy.year, hoy.month, hoy.day);
  if (inicio != null) {
    final i = DateTime(inicio.year, inicio.month, inicio.day);
    if (i.isAfter(h)) {
      return 'La congelación aún no ha empezado: se cancela '
          'con 0 días devueltos. Queda registrado que la '
          'cerraste tú.';
    }
    final dias = h.difference(i).inDays;
    final aplicados = diasYaAplicados > 0
        ? ' De ellos, $diasYaAplicados ya están aplicados '
            'a su vigencia.'
        : '';
    return 'La pausa termina ayer: los $dias días '
        'congelados hasta ayer se le devuelven al '
        'sincronizar y desde hoy su mensualidad corre '
        'normal.$aplicados Queda registrado que la '
        'cerraste tú.';
  }
  return 'La pausa termina ayer: los días congelados '
      'hasta ayer se le devuelven al sincronizar y desde '
      'hoy su mensualidad corre normal. Queda registrado '
      'que la cerraste tú.';
}

String _fmtF(DateTime? d) {
  if (d == null) return '—';
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  return '$dd/$mm/${d.year}';
}

DateTime? _f(Object? v) {
  if (v == null) return null;
  final s = '$v';
  if (s.length < 10) return null;
  return DateTime.tryParse(s.substring(0, 10));
}

class SeccionCongelacionFicha extends StatefulWidget {
  final int clienteId;
  const SeccionCongelacionFicha({super.key, required this.clienteId});
  @override
  State<SeccionCongelacionFicha> createState() =>
      _SeccionCongelacionFichaState();
}

/// 1.36 FICHA (136-227): la cabecera de la sección, una
/// sola para las tres ramas (pendiente / aprobada /
/// staff) — antes cada rama la componía a mano.
Widget _cabeceraCongelacion(String texto) => Row(
      children: [
        const Icon(Icons.ac_unit_rounded, size: 20),
        const SizedBox(width: AppEspacio.sm),
        Expanded(
          child: Text(texto, style: AppTexto.subtitulo),
        ),
      ],
    );

class _SeccionCongelacionFichaState
    extends State<SeccionCongelacionFicha> {
  // 1.36 FICHA (136-196): mientras carga, la sección
  // pinta su estado (alto reservado) en vez de nacer
  // vacía y materializarse empujando la ficha.
  bool _cargandoCongelacion = true;
  CongelacionGestion? _pendiente;
  CongelacionGestion? _aprobada;
  Map<String, dynamic>? _vigenteStaff;
  bool _actuando = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    if (mounted) setState(() => _cargandoCongelacion = true);
    try {
      await _cargarInterno();
    } finally {
      if (mounted) setState(() => _cargandoCongelacion = false);
    }
  }

  Future<void> _cargarInterno() async {
    if (AuthService().isOwner) {
      final filas = await CongelacionesService.instance
          .deCliente(widget.clienteId);
      if (!mounted) return;
      setState(() {
        _pendiente = null;
        _aprobada = null;
        for (final f in filas) {
          if (f.esPendiente && _pendiente == null) _pendiente = f;
          if (f.esAprobada && _aprobada == null) _aprobada = f;
        }
      });
    } else {
      final v = await CongelacionesService.instance
          .vigenteStaff(widget.clienteId);
      if (!mounted) return;
      setState(() => _vigenteStaff = v);
    }
  }

  // 1.36 H-B1 (136-531): el snack lleva su significado.
  void _snack(String texto,
      {SignificadoChip significado = SignificadoChip.info}) {
    if (!mounted) return;
    mostrarSnack(context, texto, significado: significado);
  }

  Future<void> _cerrar(String id,
      {DateTime? inicio, int diasYaAplicados = 0}) async {
    final confirma = await showDialog<bool>(
      context: context,
      builder: (ctx) => DialogoApp(
        titulo: 'Cerrar la congelación ahora',
        iconoTitulo: Icons.ac_unit_rounded,
        contenido: Text(textoCierreCongelacion(
          hoy: ahoraHabana(),
          inicio: inicio,
          diasYaAplicados: diasYaAplicados,
        )),
        acciones: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Volver'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cerrar ahora'),
          ),
        ],
      ),
    );
    if (confirma != true || !mounted) return;
    setState(() => _actuando = true);
    try {
      final res = await CongelacionesService.instance.cerrar(
        id: id,
        cerradoPorNombre: AuthService().displayName,
      );
      if (!mounted) return;
      if (res['ok'] == true) {
        _snack(
            res['ya_cerrada'] == true
                ? 'La congelación ya estaba cerrada.'
                : 'Congelación cerrada.',
            significado: SignificadoChip.exito);
        await _cargar();
      } else {
        // SL-2 G03-11: antes esta rama pintaba res['error']
        // crudo en el snack; ahora pasa por la rama amable,
        // como el catch de abajo.
        _snack(mensajeCierreCongelacionFallido(res['error']),
            significado: SignificadoChip.error);
      }
    } catch (e) {
      _snack('No se pudo cerrar: ${mensajeErrorAmable(e)}',
          significado: SignificadoChip.error);
    } finally {
      if (mounted) setState(() => _actuando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 1.36 H-B2 (136-534): la aparición/cambio de la tarjeta
    // de congelación se anima en altura y fundido (antes la
    // tarjeta saltaba de golpe al resolver la verificación).
    final contenido = _contenido(context);
    return AnimatedSize(
      duration: AppMovimiento.resuelta(context, AppMovimiento.media),
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: AppMovimiento.resuelta(context, AppMovimiento.media),
        child: KeyedSubtree(
          key: ValueKey(_cargandoCongelacion
              ? 'cargando'
              : 'p${_pendiente?.id}-a${_aprobada?.id}-v${_vigenteStaff?['id']}'),
          child: contenido,
        ),
      ),
    );
  }

  Widget _contenido(BuildContext context) {
    final hoy = ahoraHabana();
    if (_cargandoCongelacion &&
        _pendiente == null &&
        _aprobada == null &&
        _vigenteStaff == null) {
      // 136-196: estado pintado desde el primer frame.
      return const Tarjeta(
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: AppEspacio.sm),
            Expanded(child: Text('Congelación: verificando…')),
          ],
        ),
      );
    }
    // Vista del dueño (espejo completo).
    if (AuthService().isOwner) {
      if (_pendiente == null && _aprobada == null) {
        return const SizedBox.shrink();
      }
      // 1.36 FICHA (136-227): la primitiva Tarjeta de la
      // casa (antes Card crudo con Padding 12 y literales).
      return Tarjeta(
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_pendiente != null) ...[
                // 136-531: un solo glifo (el icono de la
                // cabecera); fuera el ❄️ del texto.
                _cabeceraCongelacion(
                    'Solicitud de congelación pendiente'),
                const SizedBox(height: AppEspacio.xs),
                Text(
                  '${_fmtF(_pendiente!.desde)} → '
                  '${_fmtF(_pendiente!.hasta)} · '
                  '${etiquetaCategoriaCongelacion(_pendiente!.motivoCategoria)}',
                ),
                const SizedBox(height: AppEspacio.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: () => Navigator.push(
                      context,
                      // 1.36 FICHA (136-222): ruta de la
                      // casa (token de 220 ms).
                      RutaIron(
                        builder: (_) => const CongelacionesScreen(),
                      ),
                    ).then((_) => _cargar()),
                    child: const Text('Resolver'),
                  ),
                ),
              ],
              if (_aprobada != null) ...[
                if (_pendiente != null) const Divider(),
                _cabeceraCongelacion('Congelación aprobada · '
                    '${_aprobada!.etiquetaEstado(hoy)}'),
                const SizedBox(height: AppEspacio.xs),
                Text(
                  '${_fmtF(_aprobada!.inicioEfectivo ?? _aprobada!.desde)}'
                  ' → ${_fmtF(_aprobada!.finEfectivo)}'
                  '${_aprobada!.materializada ? ' · +${_aprobada!.diasMaterializados} días ya aplicados' : ' · su vigencia se extiende al terminar'}',
                ),
                const SizedBox(height: AppEspacio.sm),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    onPressed: _actuando
                        ? null
                        : () => _cerrar(_aprobada!.id,
                            inicio: _aprobada!.inicioEfectivo ??
                                _aprobada!.desde,
                            diasYaAplicados:
                                _aprobada!.materializada
                                    ? (_aprobada!
                                            .diasMaterializados ??
                                        0)
                                    : 0),
                    // 136-533: mientras actúa, el botón
                    // enseña el progreso.
                    child: _actuando
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2),
                              ),
                              SizedBox(width: AppEspacio.sm),
                              Text('Cerrando…'),
                            ],
                          )
                        : const Text('Cerrar ahora'),
                  ),
                ),
              ],
            ],
          ),
      );
    }
    // Vista del staff (solo la ventana, sin motivo).
    final v = _vigenteStaff;
    if (v == null) return const SizedBox.shrink();
    final inicio = _f(v['inicio_efectivo']) ?? _f(v['desde']);
    final fin = _f(v['hasta_efectivo']) ?? _f(v['hasta']);
    final mat = (v['dias_materializados'] as num?)?.toInt();
    // 136-227: también la vista del staff va en Tarjeta.
    return Tarjeta(
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _cabeceraCongelacion('Congelación aprobada'),
            const SizedBox(height: AppEspacio.xs),
            Text(
              '${_fmtF(inicio)} → ${_fmtF(fin)}'
              '${mat != null ? ' · +$mat días ya aplicados' : ' · su vigencia se extiende al terminar'}',
            ),
            const SizedBox(height: AppEspacio.sm),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: _actuando
                    ? null
                    : () => _cerrar('${v['id']}',
                        inicio: inicio, diasYaAplicados: mat ?? 0),
                // 136-533: progreso mientras actúa.
                child: _actuando
                    ? const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          ),
                          SizedBox(width: AppEspacio.sm),
                          Text('Cerrando…'),
                        ],
                      )
                    : const Text('Cerrar ahora'),
              ),
            ),
          ],
      ),
    );
  }
}
