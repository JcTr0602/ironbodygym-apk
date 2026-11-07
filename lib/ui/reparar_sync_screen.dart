/// Pantalla «Reparar sincronización» (1.28, M1-B4).
///
/// El flujo guiado de [reparar_sync.dart] en tres pasos:
/// diagnóstico en lenguaje llano → un botón «Reparar» →
/// resumen de qué se arregló y qué queda (lo del dueño,
/// apartado y explicado; nunca se toca desde aquí).
///
/// Se entra desde el banner de error («Ver qué quedó») y
/// desde la Salud de la sincronización.
library;

import 'package:flutter/material.dart';

import '../reparar_sync.dart';
import 'app_bar.dart';
import 'cola.dart';
import 'componentes.dart';
import 'diseno.dart';

class RepararSyncScreen extends StatefulWidget {
  const RepararSyncScreen({super.key});

  @override
  State<RepararSyncScreen> createState() => _RepararSyncScreenState();
}

enum _FaseReparar { diagnostico, reparando, resumen }

class _RepararSyncScreenState extends State<RepararSyncScreen> {
  _FaseReparar _fase = _FaseReparar.diagnostico;
  bool _cargando = true;
  FotoAtascos? _foto;
  ({
    FotoAtascos antes,
    FotoAtascos despues,
    int divergentesManifiesto,
  })? _resultado;

  @override
  void initState() {
    super.initState();
    _diagnosticar();
  }

  Future<void> _diagnosticar() async {
    final foto = await capturarAtascos();
    if (!mounted) return;
    setState(() {
      _foto = foto;
      _cargando = false;
      _fase = _FaseReparar.diagnostico;
      _resultado = null;
    });
  }

  Future<void> _reparar() async {
    setState(() => _fase = _FaseReparar.reparando);
    final r = await ejecutarReparacion();
    if (!mounted) return;
    setState(() {
      _resultado = r;
      _foto = r.despues;
      _fase = _FaseReparar.resumen;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Reparar sincronización'),
      body: _cargando
          ? const EstadoCargando(texto: 'Revisando la sincronización…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: switch (_fase) {
                _FaseReparar.diagnostico => _vistaDiagnostico(),
                _FaseReparar.reparando => _vistaReparando(),
                _FaseReparar.resumen => _vistaResumen(),
              },
            ),
    );
  }

  Widget _tarjetaHallazgos(
      String titulo, IconData icono, List<HallazgoReparacion> hs,
      {bool esDueno = false}) {
    if (hs.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.md),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icono,
                    size: 20,
                    color: esDueno
                        ? AppColores.alerta
                        : AppColores.naranja),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                    child: Text(titulo, style: AppTexto.subtitulo)),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            for (final h in hs) ...[
              Text(h.titulo, style: AppTexto.cuerpo),
              const SizedBox(height: 2),
              Text(h.detalle, style: AppTexto.secundario),
              const SizedBox(height: AppEspacio.sm),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _vistaDiagnostico() {
    final foto = _foto!;
    final hallazgos = clasificarHallazgos(foto);
    final auto =
        hallazgos.where((h) => h.clase == ClaseHallazgo.auto).toList();
    final dueno =
        hallazgos.where((h) => h.clase == ClaseHallazgo.dueno).toList();
    return [
      const Text(
        'Esto es lo que la revisión encontró en este teléfono:',
        style: AppTexto.secundario,
      ),
      const SizedBox(height: AppEspacio.md),
      if (hallazgos.isEmpty)
        const Tarjeta(
          child: Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  color: AppColores.exito),
              SizedBox(width: AppEspacio.sm),
              Expanded(
                child: Text(
                    'Todo está en orden: no hay nada atascado.'),
              ),
            ],
          ),
        ),
      _tarjetaHallazgos(
          'Se repara solo', Icons.build_circle_rounded, auto),
      _tarjetaHallazgos('Lo decide el dueño', Icons.person_rounded,
          dueno,
          esDueno: true),
      if (auto.isNotEmpty) ...[
        const SizedBox(height: AppEspacio.sm),
        FilledButton.icon(
          onPressed: _reparar,
          icon: const Icon(Icons.build_rounded),
          label: const Text('Reparar'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
          ),
        ),
        const SizedBox(height: AppEspacio.sm),
        const Text(
          'Reparar comprueba todas las tablas contra el '
          'servidor, vuelve a descargar las desfasadas y '
          'reintenta lo que falló. No borra nada tuyo.',
          style: AppTexto.secundario,
        ),
      ],
      if (dueno.isNotEmpty) ...[
        const SizedBox(height: AppEspacio.sm),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ColaScreen()),
          ),
          icon: const Icon(Icons.list_alt_rounded),
          label: const Text('Ver la cola'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      ],
    ];
  }

  List<Widget> _vistaReparando() {
    return const [
      SizedBox(height: 48),
      Center(child: CircularProgressIndicator()),
      SizedBox(height: AppEspacio.lg),
      Center(
        child: Text(
          'Comprobando tablas y sincronizando…\n'
          'Puede tardar un poco si hay tablas que re-descargar.',
          textAlign: TextAlign.center,
          style: AppTexto.secundario,
        ),
      ),
    ];
  }

  List<Widget> _vistaResumen() {
    final r = _resultado!;
    final quedan = clasificarHallazgos(r.despues);
    final quedanAuto =
        quedan.where((h) => h.clase == ClaseHallazgo.auto).toList();
    final quedanDueno =
        quedan.where((h) => h.clase == ClaseHallazgo.dueno).toList();
    final arregladoAuto = r.antes.reparablesAuto - r.despues.reparablesAuto;
    return [
      Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                    r.despues.reparablesAuto == 0 &&
                            r.despues.deDueno == 0
                        ? Icons.check_circle_rounded
                        : Icons.info_rounded,
                    color: r.despues.reparablesAuto == 0 &&
                            r.despues.deDueno == 0
                        ? AppColores.exito
                        : AppColores.alerta),
                const SizedBox(width: AppEspacio.sm),
                const Expanded(
                    child:
                        Text('Resumen', style: AppTexto.subtitulo)),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            if (r.divergentesManifiesto > 0)
              Text(
                'La comprobación encontró ${r.divergentesManifiesto} '
                '${r.divergentesManifiesto == 1 ? 'tabla desfasada' : 'tablas desfasadas'} '
                'y se mandaron a re-descargar.',
                style: AppTexto.cuerpo,
              ),
            if (r.divergentesManifiesto == 0)
              const Text(
                'La comprobación no encontró tablas desfasadas.',
                style: AppTexto.cuerpo,
              ),
            if (r.divergentesManifiesto < 0)
              const Text(
                'La comprobación no pudo completarse (¿sin '
                'conexión?). La sincronización se ejecutó igual.',
                style: AppTexto.cuerpo,
              ),
            const SizedBox(height: AppEspacio.xs),
            Text(
              arregladoAuto > 0
                  ? 'Se despejaron $arregladoAuto '
                      '${arregladoAuto == 1 ? 'cosa atascada' : 'cosas atascadas'}.'
                  : 'No quedó nada pendiente de despejar por la '
                      'reparación.',
              style: AppTexto.cuerpo,
            ),
          ],
        ),
      ),
      const SizedBox(height: AppEspacio.md),
      if (quedanAuto.isEmpty && quedanDueno.isEmpty)
        const Tarjeta(
          child: Row(
            children: [
              Icon(Icons.check_circle_rounded,
                  color: AppColores.exito),
              SizedBox(width: AppEspacio.sm),
              Expanded(
                  child: Text('Todo quedó en orden.')),
            ],
          ),
        ),
      _tarjetaHallazgos('Todavía queda (se repara solo)',
          Icons.build_circle_rounded, quedanAuto),
      _tarjetaHallazgos(
          'Queda para el dueño', Icons.person_rounded, quedanDueno,
          esDueno: true),
      if (quedanDueno.isNotEmpty)
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ColaScreen()),
          ),
          icon: const Icon(Icons.list_alt_rounded),
          label: const Text('Ver la cola'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
      const SizedBox(height: AppEspacio.sm),
      TextButton.icon(
        onPressed: _diagnosticar,
        icon: const Icon(Icons.refresh_rounded),
        label: const Text('Volver a revisar'),
      ),
    ];
  }
}
