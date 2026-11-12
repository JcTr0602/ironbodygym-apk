/// Pantalla «Salud de la sincronización» (1.28, M1-C3).
///
/// Reúne en UN sitio lo que antes vivía repartido entre el
/// Diagnóstico, los teléfonos y las metas sueltas: el
/// estado de la autocura (manifiesto), la copia automática
/// semanal, los teléfonos del staff y el semáforo de las
/// 39 tablas espejo. El Diagnóstico técnico de siempre
/// queda enlazado al final, sin cambios.
///
/// Solo el dueño: enseña conteos de todas las tablas y el
/// estado de otros teléfonos (misma guarda que el
/// Diagnóstico).
library;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_log.dart';
import '../auth.dart';
import '../salud_sync.dart';
import '../sync.dart';
import '../tiempo.dart';
import '../ultimo_sync.dart';
import 'admin_secciones.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'reparar_sync_screen.dart';

/// 1.29 (Oleada 6, D-16): el aviso de estado general de
/// la pantalla, en el lenguaje de estados de la casa
/// (AvisoEstado: fondo sólido + icono + palabra, nunca
/// solo color). PURO: el estado sale de estadoSaludSync
/// y el texto lo nombra sin rodeos.
({TipoAviso tipo, String texto}) avisoSaludSyncDe(SaludSyncDatos d) {
  final estado = estadoSaludSync(
    pendientes: d.pendientes,
    fallidas: d.fallidas,
    hayTablasEnRojo:
        d.tablas.any((t) => t.estado == SemaforoTabla.rojo),
  );
  switch (estado) {
    case EstadoSaludSync.todoSubio:
      return (
        tipo: TipoAviso.exito,
        texto: 'Todo subió: este teléfono está al día.',
      );
    case EstadoSaludSync.quedanCambios:
      return (
        tipo: TipoAviso.aviso,
        texto: 'Quedan cambios por subir: ${d.pendientes} '
            '${d.pendientes == 1 ? 'operación' : 'operaciones'} '
            'en la cola de este teléfono.',
      );
    case EstadoSaludSync.fallo:
      final partes = <String>[
        if (d.fallidas > 0)
          '${d.fallidas} '
              '${d.fallidas == 1 ? 'operación falló' : 'operaciones fallaron'} '
              'o esperan decisión',
        if (d.tablas.any((t) => t.estado == SemaforoTabla.rojo))
          'hay tablas en rojo en el semáforo',
      ];
      return (
        tipo: TipoAviso.error,
        texto: 'Falló la sincronización: ${partes.join(' y ')}. '
            'Revisa la cola y el semáforo de abajo.',
      );
  }
}

class SaludSyncScreen extends StatefulWidget {
  const SaludSyncScreen({super.key});

  @override
  State<SaludSyncScreen> createState() => _SaludSyncScreenState();
}

class _SaludSyncScreenState extends State<SaludSyncScreen> {
  bool _cargando = true;
  bool _comprobando = false;
  SaludSyncDatos? _datos;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final d = await cargarSaludSync();
    if (!mounted) return;
    setState(() {
      _datos = d;
      _cargando = false;
    });
  }

  String _fmtFechaHora(DateTime? dt) {
    if (dt == null) return 'nunca';
    final h = aHabana(dt);
    String d2(int n) => n.toString().padLeft(2, '0');
    return '${fmtFechaHabana(dt)} ${d2(h.hour)}:${d2(h.minute)}';
  }

  Future<void> _comprobarAhora() async {
    setState(() => _comprobando = true);
    var divergentes = -1;
    try {
      divergentes = await SyncEngine.instance.comprobarManifiestoAhora();
    } catch (_) {}
    // Si hay tablas desfasadas, la sincronización consume
    // las banderas y las re-descarga ahora mismo.
    if (divergentes > 0) {
      try {
        await SyncEngine.instance.run(forzar: true);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _comprobando = false);
    mostrarSnack(
      context,
      divergentes < 0
          ? 'La comprobación no pudo completarse (¿sin conexión?)'
          : divergentes == 0
              ? 'Comprobación completa: todo coincide'
              : 'Se re-descargaron $divergentes '
                  '${divergentes == 1 ? 'tabla desfasada' : 'tablas desfasadas'}',
      significado:
          divergentes < 0 ? SignificadoChip.error : SignificadoChip.exito,
    );
    await _cargar();
  }

  Future<void> _exportarBitacora() async {
    try {
      final (path, _) = await AppLog.exportar();
      await Share.shareXFiles([XFile(path)],
          text: 'Bitácora Iron Body Gym');
    } catch (_) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo exportar la bitácora',
            significado: SignificadoChip.error);
      }
    }
  }

  Color _colorSemaforo(SemaforoTabla s) {
    switch (s) {
      case SemaforoTabla.verde:
        return AppColores.exito;
      case SemaforoTabla.ambar:
        return AppColores.alerta;
      case SemaforoTabla.rojo:
        return AppColores.error;
      case SemaforoTabla.gris:
        return AppColores.textoSecundario(context);
    }
  }

  String _textoTelefono(EstadoSyncTelefono e) {
    switch (e) {
      case EstadoSyncTelefono.alDia:
        return 'Al día';
      case EstadoSyncTelefono.atrasado:
        return 'ATRASADO en turno';
      case EstadoSyncTelefono.inactivo:
        return 'Más de 24 h sin sincronizar';
      case EstadoSyncTelefono.sinRegistro:
        return 'Nunca sincronizó';
      case EstadoSyncTelefono.sinVerificar:
        return 'Sin verificar';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Salud de la sincronización'),
          body: const Center(
              child: Text('La salud del sync es solo el dueño.')));
    }
    final d = _datos;
    return Scaffold(
      appBar: appBarIron(context, 'Salud de la sincronización'),
      body: _cargando || d == null
          ? const EstadoCargando(texto: 'Leyendo la salud del sync…')
          : RefreshIndicator(
              onRefresh: _cargar,
              child: ListView(
                padding: const EdgeInsets.all(AppEspacio.lg),
                children: [
                  // D-16: el estado general, dicho en el
                  // lenguaje de estados de la casa antes
                  // que el detalle por secciones.
                  Builder(builder: (context) {
                    final aviso = avisoSaludSyncDe(d);
                    return AvisoEstado(
                        tipo: aviso.tipo, texto: aviso.texto);
                  }),
                  const SizedBox(height: AppEspacio.lg),
                  seccionAdmin(
                      context, Icons.fact_check_rounded, 'Autocura', [
                    filaAdmin(context, null, 'Última comprobación',
                        _fmtFechaHora(d.chequeoEn)),
                    filaAdmin(context, null, 'Última completa',
                        _fmtFechaHora(d.completaEn)),
                    filaAdmin(context, null, 'Tablas divergentes',
                        '${d.divergentes}', negrita: d.divergentes > 0),
                    filaAdmin(context, null, 'Sin verificar',
                        '${d.sinVerificar.length}',
                        negrita: d.sinVerificar.isNotEmpty),
                    const SizedBox(height: AppEspacio.xs),
                    Wrap(
                      spacing: AppEspacio.sm,
                      runSpacing: AppEspacio.sm,
                      children: [
                        FilledButton.icon(
                          onPressed:
                              _comprobando ? null : _comprobarAhora,
                          icon: _comprobando
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.fact_check_rounded),
                          label: const Text('Comprobar ahora'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Navigator.of(context)
                              .push(MaterialPageRoute(
                                  builder: (_) =>
                                      const RepararSyncScreen()))
                              .then((_) => _cargar()),
                          icon: const Icon(Icons.build_rounded),
                          label: const Text('Reparar'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _exportarBitacora,
                          icon: const Icon(Icons.share_rounded),
                          label: const Text('Exportar bitácora'),
                        ),
                      ],
                    ),
                  ]),
                  seccionAdmin(
                      context, Icons.backup_rounded, 'Copia automática', [
                    filaAdmin(context, null, 'Última copia',
                        _fmtFechaHora(d.copiaUltima)),
                    if (d.copiaError.isNotEmpty)
                      Text(
                        'La última copia automática falló: '
                        '${d.copiaError}',
                        style: AppTexto.secundario
                            .copyWith(color: AppColores.error),
                      )
                    else
                      const Text(
                        'Se hace sola cada semana tras una '
                        'sincronización buena.',
                        style: AppTexto.secundario,
                      ),
                  ]),
                  if (d.telefonos.isNotEmpty)
                    seccionAdmin(context, Icons.phone_android_rounded,
                        'Teléfonos', [
                      for (final t in d.telefonos)
                        filaAdmin(
                          context,
                          null,
                          '${t.fila?['nombre'] ?? 'Teléfono ${t.telegramId ?? ''}'}'
                          '${t.enTurno ? ' (en turno)' : ''}',
                          _textoTelefono(t.estado),
                          negrita: t.estado ==
                                  EstadoSyncTelefono.atrasado ||
                              t.estado ==
                                  EstadoSyncTelefono.sinRegistro,
                        ),
                    ]),
                  seccionAdmin(context, Icons.table_chart_rounded,
                      'Tablas (${d.tablas.length})', [
                    for (final t in d.tablas)
                      Padding(
                        padding: const EdgeInsets.only(
                            bottom: AppEspacio.sm),
                        // 1.33 (coherencia de sync, §7.6): la
                        // fila pasa a DOS PISOS — el nombre a
                        // ancho completo en su línea y la nota
                        // debajo, a ancho completo. El Row
                        // anterior (nombre en Expanded + nota
                        // sin Flexible al lado) dejaba el
                        // nombre a 0,0 px en cuanto la nota
                        // era larga (el wm_err crudo): un
                        // carácter por línea, como en la
                        // captura de Jc. Solo cambia la
                        // estructura: punto, estilos y colores
                        // son los mismos.
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 12,
                                  height: 12,
                                  decoration: BoxDecoration(
                                    color: _colorSemaforo(t.estado),
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(
                                    width: AppEspacio.sm),
                                Expanded(
                                  child: Text(t.nombre,
                                      style: AppTexto.cuerpo),
                                ),
                              ],
                            ),
                            Padding(
                              padding: const EdgeInsets.only(
                                  left: 12 + AppEspacio.sm,
                                  top: 2),
                              child: Text(t.nota,
                                  style: AppTexto.metadato),
                            ),
                          ],
                        ),
                      ),
                  ]),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) =>
                              const SeccionDiagnosticoScreen()),
                    ),
                    icon: const Icon(Icons.analytics_rounded),
                    label: const Text('Diagnóstico técnico'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
