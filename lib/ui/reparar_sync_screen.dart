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

import '../app_log.dart';
import '../auth.dart';
import '../errores_sync.dart';
import '../reparar_sync.dart';
import 'app_bar.dart';
import 'cola.dart';
import 'componentes.dart';
import 'diseno.dart';

class RepararSyncScreen extends StatefulWidget {
  const RepararSyncScreen({
    super.key,
    this.diagnosticoParaTest,
    this.reparacionParaTest,
  });

  /// Costuras de test (G08-1): sustituyen la foto de
  /// atascos y la reparación reales. En producción son
  /// null y corren [capturarAtascos] / [ejecutarReparacion].
  final Future<FotoAtascos> Function()? diagnosticoParaTest;
  final Future<
      ({
        FotoAtascos antes,
        FotoAtascos despues,
        int divergentesManifiesto,
      })> Function()? reparacionParaTest;

  @override
  State<RepararSyncScreen> createState() => _RepararSyncScreenState();
}

enum _FaseReparar { diagnostico, reparando, resumen, error }

class _RepararSyncScreenState extends State<RepararSyncScreen> {
  _FaseReparar _fase = _FaseReparar.diagnostico;
  bool _cargando = true;
  FotoAtascos? _foto;
  ({
    FotoAtascos antes,
    FotoAtascos despues,
    int divergentesManifiesto,
  })? _resultado;
  // G08-1: el fallo de diagnóstico/reparación tiene fase
  // propia (error visible con salida y reintento); antes
  // una excepción dejaba la pantalla en «reparando» para
  // siempre: círculo sin mensaje, sin salida y sin
  // reintento.
  String? _error;
  bool _falloDiagnostico = false;
  bool _diagnosticando = false;

  @override
  void initState() {
    super.initState();
    _diagnosticar();
  }

  Future<void> _diagnosticar() async {
    // F02-z01_sync_1-3 (r2): sin guarda ni setState previo,
    // el reintento desde el error no mostraba «reintentando»
    // y un doble toque lanzaba diagnósticos solapados.
    if (_diagnosticando) return;
    _diagnosticando = true;
    if (mounted && !_cargando) {
      setState(() {
        _cargando = true;
        _fase = _FaseReparar.diagnostico;
      });
    }
    try {
      final foto = await (widget.diagnosticoParaTest?.call() ??
          capturarAtascos());
      if (!mounted) return;
      setState(() {
        _foto = foto;
        _cargando = false;
        _fase = _FaseReparar.diagnostico;
        _resultado = null;
        _error = null;
      });
    } catch (e) {
      AppLog.error('sync', 'reparar_diagnostico_fallo', d: '$e');
      if (!mounted) return;
      setState(() {
        _cargando = false;
        _fase = _FaseReparar.error;
        _error = mensajeErrorAmable(e);
        _falloDiagnostico = true;
      });
    } finally {
      _diagnosticando = false;
    }
  }

  Future<void> _reparar() async {
    setState(() => _fase = _FaseReparar.reparando);
    try {
      final r = await (widget.reparacionParaTest?.call() ??
          ejecutarReparacion());
      if (!mounted) return;
      setState(() {
        _resultado = r;
        _foto = r.despues;
        _fase = _FaseReparar.resumen;
        _error = null;
      });
    } catch (e) {
      AppLog.error('sync', 'reparar_pantalla_fallo', d: '$e');
      if (!mounted) return;
      setState(() {
        _fase = _FaseReparar.error;
        _error = mensajeErrorAmable(e);
        _falloDiagnostico = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Yunque R4-M3-3: la reparación (comprobación completa
    // del manifiesto + sync forzada) es herramienta del
    // dueño, como la Salud — antes cualquier staff la
    // disparaba desde el banner de error, sin puerta.
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Reparar sincronización'),
          body: const Center(
              child: Text(
                  'La reparación del sync es solo el dueño.')));
    }
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
                _FaseReparar.error => _vistaError(),
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
      if (!foto.fotoCompleta)
        // Yunque R4-M3-1: con lecturas fallidas la foto es
        // parcial — jamás el verde de «todo en orden» sobre
        // ceros que pueden ser errores de lectura.
        AvisoEstado(
          tipo: TipoAviso.error,
          texto: 'La revisión no se pudo completar: '
              '${foto.lecturasFallidas} '
              '${foto.lecturasFallidas == 1 ? 'lectura falló' : 'lecturas fallaron'} '
              'al revisar este teléfono. Lo que se ve abajo '
              'puede estar incompleto; vuelve a revisar y, '
              'si sigue fallando, exporta la bitácora desde '
              'la Salud de la sincronización.',
        ),
      if (hallazgos.isEmpty && foto.fotoCompleta)
        // 1.29 (Oleada 6, D-16): el «todo está bien» de
        // reparar sync también habla el lenguaje de
        // estados de la casa (AvisoEstado), como la Salud.
        const AvisoEstado(
          tipo: TipoAviso.exito,
          texto: 'Todo está en orden: no hay nada atascado.',
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
            RutaIron(builder: (_) => const ColaScreen()),
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

  /// G08-1: el fallo se ve, se puede reintentar y se puede
  /// salir — el giro de «reparando» solo vive mientras la
  /// reparación vive.
  List<Widget> _vistaError() {
    return [
      EstadoError(
        titulo: _falloDiagnostico
            ? 'No se pudo revisar la sincronización'
            : 'La reparación no se pudo completar',
        detalle: _error,
        onReintentar: _falloDiagnostico ? _diagnosticar : _reparar,
      ),
      Center(
        child: TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
          label: const Text('Volver'),
        ),
      ),
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
            // Yunque R4-M3-1: el «se despejaron N» solo es
            // verdad con AMBAS fotos completas; con fallos
            // de lectura la diferencia puede ser un cero
            // fabricado por el error, no una cura.
            Text(
              !(r.antes.fotoCompleta && r.despues.fotoCompleta)
                  ? 'La revisión de antes o de después no se '
                      'pudo leer completa: no se puede asegurar '
                      'cuánto se despejó. Vuelve a revisar.'
                  : arregladoAuto > 0
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
      if (!r.despues.fotoCompleta)
        // Yunque R4-M3-1: sin foto completa no hay «todo
        // quedó en orden» que valga.
        const AvisoEstado(
          tipo: TipoAviso.error,
          texto: 'La revisión final no se pudo completar: '
              'puede quedar algo atascado sin verse. Vuelve '
              'a revisar.',
        ),
      if (quedanAuto.isEmpty &&
          quedanDueno.isEmpty &&
          r.despues.fotoCompleta)
        // D-16: «todo quedó en orden» como AvisoEstado.
        const AvisoEstado(
          tipo: TipoAviso.exito,
          texto: 'Todo quedó en orden.',
        ),
      if ((quedanAuto.isNotEmpty || quedanDueno.isNotEmpty) &&
          r.despues.fotoCompleta)
        // D-16: «quedan cambios» como AvisoEstado. (Con la
        // foto parcial manda el aviso de error de arriba:
        // un «no queda nada listado» no debe leerse como
        // «queda esto y solo esto».)
        const AvisoEstado(
          tipo: TipoAviso.aviso,
          texto: 'Todavía quedan cosas por revisar: están '
              'listadas justo abajo.',
        ),
      _tarjetaHallazgos('Todavía queda (se repara solo)',
          Icons.build_circle_rounded, quedanAuto),
      _tarjetaHallazgos(
          'Queda para el dueño', Icons.person_rounded, quedanDueno,
          esDueno: true),
      if (quedanDueno.isNotEmpty)
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            RutaIron(builder: (_) => const ColaScreen()),
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
