import 'package:flutter/material.dart';

import '../auth.dart';
import '../cierre_mes.dart';
import '../diagnostico_espejo.dart' show textoUltimaSyncOk;
import 'ajustes.dart';
import 'app_bar.dart';
import 'arqueo.dart';
import 'cola.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'primitivas.dart';
import 'liquidaciones_historial.dart';
import 'nomina.dart';
import 'skeleton.dart';
import 'pendiente.dart';

/// 1.23 (W2): pantalla del cierre de mes guiado. Una lista de
/// pasos con su estado EN VIVO (los automáticos se leen de los
/// datos; los manuales se confirman con un toque) y el botón
/// «Ir» de cada paso a su pantalla de siempre. Al estar todo
/// verificado, el dueño marca el mes como cerrado. El
/// progreso vive en la meta del mes (lib/cierre_mes.dart):
/// salir y volver deja la ruta como estaba.
class CierreMesScreen extends StatefulWidget {
  const CierreMesScreen({super.key});

  @override
  State<CierreMesScreen> createState() => _CierreMesScreenState();
}

class _CierreMesScreenState extends State<CierreMesScreen> {
  late String _pref;
  EstadoCierreMes? _estado;
  bool _cargando = true;
  // Corrección A1-D2: si la evaluación falla (dato corrupto,
  // BD…), la pantalla enseña el error con reintento en vez de
  // quedarse en «cargando» para siempre.
  bool _errorCarga = false;
  // (136-776) guarda anti doble toque de las acciones del cierre.
  bool _operando = false;

  static const _meses = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre',
    'diciembre',
  ];

  @override
  void initState() {
    super.initState();
    _pref = prefMesAnterior();
    _cargar();
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _errorCarga = false;
      // 1.36 H-B3 (136-808): el estado anterior se LIMPIA
      // al cargar/cambiar de mes — si la evaluación falla,
      // la pantalla enseña el error con reintento, no la
      // foto del mes anterior como si fuera la vigente.
      _estado = null;
    });
    try {
      final e = await evaluarCierreMes(_pref);
      if (!mounted) return;
      setState(() {
        _estado = e;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _errorCarga = true;
      });
    }
  }

  String get _nombreMes {
    final p = _pref.split('-');
    final m = int.tryParse(p[1]) ?? 1;
    return '${_meses[m - 1]} de ${p[0]}';
  }

  void _moverMes(int delta) {
    final p = _pref.split('-');
    final d = DateTime(int.parse(p[0]), int.parse(p[1]) + delta);
    _pref =
        '${d.year}-${d.month.toString().padLeft(2, '0')}';
    _cargar();
  }

  /// 1.36 H-B3 (136-815): selector directo de mes en
  /// formato YYYY-MM (para cerrar un mes atrasado sin
  /// caminar flecha a flecha).
  Future<void> _elegirMesDirecto() async {
    final ctrl = TextEditingController(text: _pref);
    final elegido = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ir a un mes'),
        content: CampoTexto(
          controller: ctrl,
          etiqueta: 'Mes (AAAA-MM)',
          hint: '2026-09',
          teclado: TextInputType.datetime,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Ir'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (elegido == null || !mounted) return;
    if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(elegido)) {
      mostrarSnack(context,
          'Escribe el mes como AAAA-MM (p. ej. 2026-09).',
          significado: SignificadoChip.alerta);
      return;
    }
    setState(() => _pref = elegido);
    _cargar();
  }

  Future<void> _ir(Widget pantalla) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => pantalla),
    );
    if (!mounted) return;
    // Al volver, los pasos automáticos se re-evalúan: lo que
    // se haya resuelto en la pantalla destino se ve al momento.
    _cargar();
  }

  Widget _destinoDe(PasoCierreMes paso) =>
      // 1.36 H-B3 (136-815/809): la ruta sale del modelo
      // (destinoId) y «liquidaciones» tiene la suya propia.
      switch (paso.destinoId ?? paso.id) {
        'sync' => const ColaScreen(),
        'nomina' => const NominaScreen(),
        'liquidaciones' => const LiquidacionesHistorialScreen(),
        'arqueo' => const ArqueoScreen(),
        'entrega' => const PendienteScreen(),
        _ => const AjustesScreen(),
      };

  Future<void> _confirmarManual(PasoCierreMes paso) async {
    // (136-776) guarda síncrona antes del primer await.
    if (_operando) return;
    _operando = true;
    try {
      await confirmarPasoCierreMes(_pref, paso.id);
      if (!mounted) return;
      _cargar();
    } finally {
      _operando = false;
    }
  }

  Future<void> _cerrarMes() async {
    // 1.32 (O2F2, Pieza 4): el sello del mes se pone
    // DESLIZANDO, no con un toque (confirmarDeslizando);
    // la reevaluación de marcarMesCerrado no cambia.
    final ok = await confirmarDeslizando(
      context,
      titulo: 'Cerrar ${_nombreMes}',
      mensaje: 'Todos los pasos están verificados. Marcar el '
          'mes como cerrado deja constancia de que el cierre '
          'se hizo completo; no bloquea nada: podrás seguir '
          'operando y corrigiendo como siempre.',
      textoDeslizar: 'Desliza para marcar cerrado',
      textoConfirmando: 'Cerrando…',
      icono: Icons.event_available_rounded,
    );
    if (ok != true) return;
    // Delta del panel: marcarMesCerrado REEVALÚA — si algo
    // dejó de estar en verde desde que se pintó la pantalla,
    // el cierre se rechaza y se muestra el estado nuevo.
    final hecho = await marcarMesCerrado(_pref);
    if (!mounted) return;
    if (!hecho) {
      // 1.24 Bloque 5 (C-06): por el helper de la casa, no una
      // barra cruda — la cruda quedaba flotando sobre la
      // pantalla siguiente.
      mostrarSnack(
          context,
          'Algún paso dejó de estar verificado: '
          'revisa la lista actualizada antes de cerrar.',
          significado: SignificadoChip.alerta);
    }
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    // Delta del panel: la pantalla se protege a sí misma
    // (la puerta en Nómina no es la única barrera).
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Cierre de mes'),
          body: const Center(
              child: Text('El cierre de mes es solo del dueño.')));
    }
    final e = _estado;
    return Scaffold(
      appBar: appBarIron(context, 'Cierre de mes'),
      body: _cargando
          // 1.30 (Oleada D6, UI130-22): esqueleto de
          // lista en vez del spinner pelado.
          ? const SkeletonLista()
          : e == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _errorCarga
                              ? 'No se pudo evaluar el cierre de este mes.'
                              : 'Sin datos del cierre.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: AppEspacio.md),
                        FilledButton(
                          onPressed: _cargar,
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefrescoIron(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  Row(
                    children: [
                      IconButton(
                        // 1.36 H-B3 (136-812): tooltip en las
                        // flechas de mes.
                        tooltip: 'Mes anterior',
                        onPressed: () => _moverMes(-1),
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        // 1.36 H-B3 (136-815): tocar el mes
                        // abre el selector directo YYYY-MM.
                        child: InkWell(
                          onTap: _elegirMesDirecto,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: AppEspacio.sm),
                            child: Text(
                              'Cierre de ${_nombreMes}',
                              style: AppTexto.titulo,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Mes siguiente',
                        onPressed: () => _moverMes(1),
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppEspacio.xs),
                  Text(
                    e.cerradoEn != null
                        ? 'Mes cerrado el '
                            '${textoUltimaSyncOk(e.cerradoEn)}. '
                            'Esta es la constancia del cierre.'
                        : e.constanciaInvalida
                            // 1.36 H-C2 (136-813): hay
                            // constancia pero su fecha no
                            // se puede leer: se dice, no se
                            // ofrece cerrar otra vez.
                            ? 'Este mes tiene una constancia '
                                'de cierre guardada, pero su '
                                'fecha no se puede leer. No se '
                                'ofrece cerrarlo otra vez.'
                            : '${e.verificados} de ${e.pasos.length} '
                                'pasos verificados. La ruta guía y '
                                'comprueba; cada paso lo confirmas tú '
                                'en su pantalla.',
                    style: AppTexto.secundario,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppEspacio.lg),
                  for (var i = 0; i < e.pasos.length; i++)
                    _tarjetaPaso(i, e.pasos[i]),
                  if (e.listo && e.cerradoEn == null) ...[
                    const SizedBox(height: AppEspacio.md),
                    FilledButton.icon(
                      onPressed: _cerrarMes,
                      icon: const Icon(Icons.lock_rounded),
                      label: const Text('Marcar mes como cerrado'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _tarjetaPaso(int indice, PasoCierreMes paso) {
    final color = paso.verificado
        ? AppColores.exito
        : AppColores.textoSecundario(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  paso.verificado
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: color,
                ),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                    '${indice + 1}. ${paso.titulo}',
                    style: AppTexto.titulo,
                  ),
                ),
                // 1.36 H-B3 (136-815): el estado del paso
                // con el chip semántico de la casa según el
                // enum del modelo.
                ChipEstado.semantico(
                  significado: switch (paso.estadoPaso) {
                    EstadoPasoCierre.verificado =>
                      SignificadoChip.exito,
                    EstadoPasoCierre.noVerificable =>
                      SignificadoChip.alerta,
                    EstadoPasoCierre.bloqueado =>
                      SignificadoChip.error,
                    EstadoPasoCierre.pendiente =>
                      SignificadoChip.info,
                  },
                  texto: switch (paso.estadoPaso) {
                    EstadoPasoCierre.verificado => 'Verificado',
                    EstadoPasoCierre.noVerificable =>
                      'No verificable',
                    EstadoPasoCierre.bloqueado => 'Bloqueado',
                    EstadoPasoCierre.pendiente =>
                      'Confirmación manual',
                  },
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(paso.detalle, style: AppTexto.cuerpo),
            // 1.36 H-B3 (136-815): la checklist COMPLETA de
            // bloqueos (el detalle solo resume) y la hora de
            // confirmación de los pasos manuales.
            if (paso.bloqueos.length > 1) ...[
              const SizedBox(height: AppEspacio.sm),
              for (final b in paso.bloqueos)
                Padding(
                  padding:
                      const EdgeInsets.only(bottom: AppEspacio.xs),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.block_rounded,
                          size: 15,
                          color: AppColores.alertaTexto(context)),
                      const SizedBox(width: AppEspacio.xs),
                      Expanded(
                          child: Text(b, style: AppTexto.cuerpo)),
                    ],
                  ),
                ),
            ],
            if (paso.confirmadoEn != null) ...[
              const SizedBox(height: AppEspacio.sm),
              Text(
                'Confirmado el ${textoUltimaSyncOk(paso.confirmadoEn)}',
                style: AppTexto.secundario,
              ),
            ],
            const SizedBox(height: AppEspacio.md),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _ir(_destinoDe(paso)),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(switch (paso.destinoId ?? paso.id) {
                    'sync' => 'Ir a la cola',
                    'nomina' => 'Ir a Nómina',
                    // 1.36 H-B3 (136-809): liquidaciones a
                    // SU pantalla, con su rótulo.
                    'liquidaciones' => 'Ir a liquidaciones',
                    'arqueo' => 'Ir a Arqueo',
                    'entrega' => 'Ir a Pendientes',
                    _ => 'Ir a Ajustes',
                  }),
                ),
                // 1.36 H-C2 (136-813): con el mes ya
                // cerrado no se confirman pasos: la
                // constancia no se reescribe a posteriori.
                if (paso.esManual &&
                    !paso.verificado &&
                    _estado?.cerradoEn == null)
                  FilledButton(
                    onPressed: () => _confirmarManual(paso),
                    child: Text(paso.id == 'nomina'
                        ? 'Ya la revisé'
                        : 'Ya lo exporté'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
