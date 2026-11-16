/// T5 (1.20): bandeja «Diferencias de caja» del dueño —
/// expedientes abiertos por diferencias al liquidar que no
/// eran el arrastre normal, y su resolución.
///
/// El entrenador no entra aquí: ve SUS expedientes en el
/// detalle de su arqueo (transparencia sin castigo; nada
/// se descuenta automáticamente).
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../diferencias_caja.dart';
import '../negocio.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';

/// Diálogo para resolver un expediente: clasificación
/// cerrada + nota (obligatoria para «Otro», el servidor
/// lo vuelve a validar). Devuelve true si se encoló.
Future<bool> mostrarDialogoResolverDiferencia(
  BuildContext context, {
  required Map<String, dynamic> expediente,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => _DialogoResolverDiferencia(
      expediente: expediente,
    ),
  );
  if (ok == true && context.mounted) {
    mostrarSnack(context, 'Diferencia resuelta (se sincronizará)',
        significado: SignificadoChip.exito);
  }
  return ok == true;
}

/// 1.30 (Oleada 7, clase B): el diálogo de resolución como
/// StatefulWidget propio: posee y dispone el controlador de
/// la nota en su `dispose` (antes se creaba en la función y
/// nunca se liberaba; disponerlo tras showDialog reventaba
/// con «used after being disposed», AT-09). Devuelve true
/// si se encoló la resolución.
class _DialogoResolverDiferencia extends StatefulWidget {
  final Map<String, dynamic> expediente;
  const _DialogoResolverDiferencia({required this.expediente});

  @override
  State<_DialogoResolverDiferencia> createState() =>
      _DialogoResolverDiferenciaState();
}

class _DialogoResolverDiferenciaState
    extends State<_DialogoResolverDiferencia> {
  var _resolucion = 'vuelto';
  final _notaCtrl = TextEditingController();
  var _errorNota = false;
  // Yunque R4-M7-2: guarda de vuelo y error visible al
  // resolver (el servicio lanza si ya hay una resolución
  // en curso; sin esto, un doble toque era una excepción
  // asíncrona sin mensaje).
  var _resolviendo = false;
  String? _errorResolver;

  @override
  void dispose() {
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expediente = widget.expediente;
    final notaObligatoria = _resolucion == 'otro';
    return DialogoApp(
          titulo: 'Resolver diferencia',
          iconoTitulo: Icons.task_alt_rounded,
          contenido: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${expediente['entrenador_nombre'] ?? ''}',
                  style: AppTexto.subtitulo,
                ),
                Text(
                  'Faltan ${fmtMonto(expediente['monto'])} '
                  '${expediente['moneda'] ?? 'CUP'} · '
                  '${fmtFecha('${expediente['fecha'] ?? ''}')}',
                  style: AppTexto.secundario,
                ),
                if ('${expediente['explicacion'] ?? ''}'
                    .trim()
                    .isNotEmpty) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text('Explicación: ${expediente['explicacion']}',
                      style: AppTexto.secundario),
                ],
                const SizedBox(height: AppEspacio.lg),
                const Text('¿Qué pasó con ese dinero?',
                    style: AppTexto.etiqueta),
                const SizedBox(height: AppEspacio.sm),
                Wrap(
                  spacing: AppEspacio.sm,
                  runSpacing: AppEspacio.sm,
                  children: [
                    for (final r in kResolucionesDiferencia)
                      ChoiceChip(
                        label: Text(
                            etiquetaResolucionDiferencia(r)),
                        selected: _resolucion == r,
                        onSelected: (_) => setState(() {
                          _resolucion = r;
                          _errorNota = false;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppEspacio.lg),
                CampoTexto(
                  controller: _notaCtrl,
                  etiqueta: notaObligatoria
                      ? 'Nota (obligatoria)'
                      : 'Nota (opcional)',
                  maxLineas: 3,
                  onChanged: (_) {
                    if (_errorNota) {
                      setState(() => _errorNota = false);
                    }
                  },
                ),
                if (_errorNota) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    'Para «Otro» hay que escribir la nota.',
                    // 1.29 (Oleada 2): rol de TEXTO de error
                    // de la Oleada 1 (el rol crudo no llegaba
                    // al contraste sobre el fondo del tema).
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.errorTexto(context)),
                  ),
                ],
                if (_errorResolver != null) ...[
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    _errorResolver!,
                    style: AppTexto.metadato.copyWith(
                        color: AppColores.errorTexto(context)),
                  ),
                ],
              ],
            ),
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: _resolviendo
                  ? null
                  : () async {
                      if (notaObligatoria &&
                          _notaCtrl.text.trim().isEmpty) {
                        setState(() => _errorNota = true);
                        return;
                      }
                      // Yunque R4-M7-2: guarda de vuelo y
                      // error VISIBLE del servicio (su
                      // StateError «ya tiene una resolución
                      // en curso» llegaba como excepción
                      // asíncrona sin cazar).
                      setState(() {
                        _resolviendo = true;
                        _errorResolver = null;
                      });
                      try {
                        await DiferenciasCajaService.instance
                            .resolver(
                          expedienteId: '${expediente['id']}',
                          resolucion: _resolucion,
                          nota: _notaCtrl.text,
                        );
                        if (context.mounted) {
                          Navigator.pop(context, true);
                        }
                      } catch (e) {
                        if (mounted) {
                          setState(() {
                            _resolviendo = false;
                            _errorResolver = '$e'
                                .replaceFirst('Bad state: ', '');
                          });
                        }
                      }
                    },
              child: const Text('Resolver'),
            ),
          ],
        );
  }
}

/// Chip de estado de un expediente (abierto / resuelto con
/// su clasificación), compartido con el historial de
/// liquidaciones del arqueo.
Widget chipExpedienteDiferencia(Map<String, dynamic> exp) {
  final resuelta = '${exp['estado']}' == 'resuelta';
  return ChipEstado.semantico(
    texto: resuelta
        ? 'Expediente resuelto · '
            '${etiquetaResolucionDiferencia('${exp['resolucion'] ?? ''}')}'
        : 'Expediente abierto',
    significado:
        resuelta ? SignificadoChip.exito : SignificadoChip.alerta,
  );
}

class DiferenciasCajaScreen extends StatefulWidget {
  /// 1.29 (Oleada 2, D-A4): con [soloEntrenadorTid], la
  /// pantalla es la vista del PROPIO entrenador sobre SUS
  /// expedientes (solo lectura: sin candado de dueño y
  /// sin botón Resolver). Es el destino del «y N más» de
  /// su tarjeta en el Dashboard: sin filtro, la lista
  /// completa de sus expedientes no existía en su vista
  /// (la tarjeta cortaba a 5 sin salida).
  final int? soloEntrenadorTid;

  const DiferenciasCajaScreen({super.key, this.soloEntrenadorTid});

  @override
  State<DiferenciasCajaScreen> createState() =>
      _DiferenciasCajaScreenState();
}

class _DiferenciasCajaScreenState
    extends State<DiferenciasCajaScreen> {
  bool _cargando = true;
  // SL-5 G07-1: patrón error≠vacío de la familia (ver
  // arqueo.dart): si la lectura falla, NO se afirma «No hay
  // diferencias»: se pinta EstadoError con Reintentar.
  bool _falloCarga = false;
  List<Map<String, dynamic>> _abiertas = [];
  List<Map<String, dynamic>> _resueltas = [];

  bool get _filtrada => widget.soloEntrenadorTid != null;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final tid = widget.soloEntrenadorTid;
      final filas = tid != null
          ? await DiferenciasCajaService.instance.deEntrenador(tid)
          : await DiferenciasCajaService.instance.todas();
      if (mounted) {
        setState(() {
          _abiertas = filas
              .where((r) => '${r['estado']}' == 'abierta')
              .toList();
          _resueltas = filas
              .where((r) => '${r['estado']}' == 'resuelta')
              .take(20)
              .toList();
          _cargando = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _falloCarga = true;
          _cargando = false;
        });
      }
    }
  }

  Widget _fila(Map<String, dynamic> e) {
    final resuelta = '${e['estado']}' == 'resuelta';
    final notaRes = '${e['resolucion_nota'] ?? ''}'.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${e['entrenador_nombre'] ?? ''}',
                      style: AppTexto.subtitulo),
                ),
                chipExpedienteDiferencia(e),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(
              'Faltan ${fmtMonto(e['monto'])} '
              '${e['moneda'] ?? 'CUP'} · liquidación del '
              '${fmtFecha('${e['fecha'] ?? ''}')}',
              style: AppTexto.secundario,
            ),
            if ('${e['explicacion'] ?? ''}'.trim().isNotEmpty)
              Text('Explicación: ${e['explicacion']}',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            if (resuelta && notaRes.isNotEmpty)
              Text('Nota: $notaRes',
                  style: AppTexto.metadato.copyWith(
                      color: AppColores.textoSecundario(context))),
            // 1.29 (D-A4): en la vista filtrada del propio
            // entrenador no hay acción de resolver (eso lo
            // hace el dueño en su bandeja).
            if (!resuelta && !_filtrada) ...[
              const SizedBox(height: AppEspacio.sm),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.task_alt_rounded,
                      size: 18),
                  label: const Text('Resolver'),
                  onPressed: () async {
                    final ok = await mostrarDialogoResolverDiferencia(
                        context,
                        expediente: e);
                    if (ok) _cargar();
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 1.29 (D-A4): la vista filtrada es del propio
    // entrenador sobre sus expedientes: no pasa por el
    // candado de dueño (sus datos ya son los suyos; el
    // servicio filtra por su telegram_id).
    if (!_filtrada && !AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Diferencias de caja'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño lleva las diferencias de caja',
        ),
      );
    }
    return Scaffold(
      appBar: appBarIron(
        context,
        _filtrada ? 'Mis diferencias de caja' : 'Diferencias de caja',
        acciones: [
          IconButton(
            // SL-5 G07-3: este botón SOLO relee lo local;
            // su nombre lo dice (no baja nada del servidor).
            tooltip: 'Releer',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _cargar,
          ),
        ],
      ),
      // 1.23 T7: cruce por tipo de estado (sin estado vacío de
      // pantalla: el «sin abiertas» es una tarjeta de sección).
      body: CruceEstados(
        estado: _cargando ? 'cargando' : 'contenido',
        child: _cargando
            ? const EstadoCargando(texto: 'Cargando diferencias…')
            : _falloCarga
                // SL-5 G07-1: fallo de lectura con salida.
                ? EstadoError(
                    titulo: 'No se pudieron leer las diferencias',
                    detalle: 'Puede que haya expedientes sin '
                        'mostrar. Reintenta.',
                    onReintentar: _cargar,
                  )
                : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  EncabezadoSeccion(
                      titulo: 'Abiertas (${_abiertas.length})'),
                  if (_abiertas.isEmpty)
                    // SL-5 G07-4: en cero NO se pinta una
                    // tarjeta: el vacío va sin marco, como
                    // sección, y la calma solo se afirma con
                    // la lectura hecha (ver _falloCarga).
                    const EstadoVacio(
                      sinMarco: true,
                      icono: Icons.check_circle_outline_rounded,
                      titulo: 'No hay diferencias de caja abiertas',
                    )
                  else
                    for (final e in _abiertas) _fila(e),
                  if (_resueltas.isNotEmpty) ...[
                    const EncabezadoSeccion(titulo: 'Resueltas'),
                    for (final e in _resueltas) _fila(e),
                  ],
                ],
              ),
            ),
        ),
    );
  }
}

/// 1.29 (Oleada 2, D-A4): el resumen de expedientes de la
/// tarjeta «Mis diferencias de caja» del Dashboard del
/// entrenador: pinta como máximo [maxVisibles] filas y,
/// si quedan más, el enlace «y N más» que lleva a la
/// lista completa filtrada por ese entrenador. Antes la
/// tarjeta cortaba la lista a 5 EN SILENCIO: el sexto
/// expediente en adelante no existía en su vista.
class ListaDiferenciasResumen extends StatelessWidget {
  final List<Map<String, dynamic>> expedientes;
  final VoidCallback? onVerMas;
  final int maxVisibles;

  const ListaDiferenciasResumen({
    super.key,
    required this.expedientes,
    this.onVerMas,
    this.maxVisibles = 5,
  });

  @override
  Widget build(BuildContext context) {
    final visibles = expedientes.take(maxVisibles).toList();
    final restantes = expedientes.length - visibles.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in visibles)
          Padding(
            padding: const EdgeInsets.only(bottom: AppEspacio.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Faltan '
                    '${fmtMonto(e['monto'])} '
                    '${e['moneda'] ?? 'CUP'} · '
                    '${fmtFecha('${e['fecha'] ?? ''}')}',
                    style: AppTexto.secundario,
                  ),
                ),
                chipExpedienteDiferencia(e),
              ],
            ),
          ),
        if (restantes > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onVerMas,
              child: Text('y $restantes más'),
            ),
          ),
      ],
    );
  }
}
