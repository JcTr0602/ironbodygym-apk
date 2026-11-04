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
import 'nomina.dart';
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
    setState(() => _cargando = true);
    final e = await evaluarCierreMes(_pref);
    if (!mounted) return;
    setState(() {
      _estado = e;
      _cargando = false;
    });
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

  Future<void> _ir(Widget pantalla) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => pantalla),
    );
    if (!mounted) return;
    // Al volver, los pasos automáticos se re-evalúan: lo que
    // se haya resuelto en la pantalla destino se ve al momento.
    _cargar();
  }

  Widget _destinoDe(PasoCierreMes paso) => switch (paso.id) {
        'sync' => const ColaScreen(),
        'nomina' || 'liquidaciones' => const NominaScreen(),
        'arqueo' => const ArqueoScreen(),
        'entrega' => const PendienteScreen(),
        _ => const AjustesScreen(),
      };

  Future<void> _confirmarManual(PasoCierreMes paso) async {
    await confirmarPasoCierreMes(_pref, paso.id);
    if (!mounted) return;
    _cargar();
  }

  Future<void> _cerrarMes() async {
    final ok = await DialogoApp.confirmar(
      context,
      titulo: 'Cerrar ${_nombreMes}',
      mensaje: 'Todos los pasos están verificados. Marcar el '
          'mes como cerrado deja constancia de que el cierre '
          'se hizo completo; no bloquea nada: podrás seguir '
          'operando y corrigiendo como siempre.',
      aceptar: 'Marcar cerrado',
    );
    if (ok != true) return;
    // Delta del panel: marcarMesCerrado REEVALÚA — si algo
    // dejó de estar en verde desde que se pintó la pantalla,
    // el cierre se rechaza y se muestra el estado nuevo.
    final hecho = await marcarMesCerrado(_pref);
    if (!mounted) return;
    if (!hecho) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Algún paso dejó de estar verificado: '
            'revisa la lista actualizada antes de cerrar.'),
      ));
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
      body: _cargando || e == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => _moverMes(-1),
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        child: Text(
                          'Cierre de ${_nombreMes}',
                          style: AppTexto.titulo,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      IconButton(
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
                    style: AppTexto.titulo.copyWith(fontSize: 16),
                  ),
                ),
                if (paso.esManual)
                  Text('Confirmación manual',
                      style: AppTexto.secundario),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            Text(paso.detalle, style: AppTexto.cuerpo),
            const SizedBox(height: AppEspacio.md),
            Wrap(
              spacing: AppEspacio.sm,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _ir(_destinoDe(paso)),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: Text(switch (paso.id) {
                    'sync' => 'Ir a la cola',
                    'nomina' || 'liquidaciones' => 'Ir a Nómina',
                    'arqueo' => 'Ir a Arqueo',
                    'entrega' => 'Ir a Pendientes',
                    _ => 'Ir a Ajustes',
                  }),
                ),
                if (paso.esManual && !paso.verificado)
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
