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
import '../errores_sync.dart';
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
    trabajoFueraCola: d.trabajoFueraCola,
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
    case EstadoSaludSync.sinVerificar:
      // SYNC-12 (1.35): la cola no se pudo leer — el aviso
      // lo declara en vez del «Todo subió» que el catch
      // componía con 0/0 fingidos.
      return (
        tipo: TipoAviso.aviso,
        texto: 'Sin verificar: no se pudo leer la cola de '
            'sincronización de este teléfono. Revisa el '
            'semáforo de abajo.',
      );
    case EstadoSaludSync.fallo:
      final partes = <String>[
        if ((d.fallidas ?? 0) > 0)
          '${d.fallidas} '
              '${d.fallidas == 1 ? 'operación falló' : 'operaciones fallaron'} '
              'o esperan decisión',
        if ((d.trabajoFueraCola ?? 0) > 0)
          'quedan ${d.trabajoFueraCola} '
              '${d.trabajoFueraCola == 1 ? 'elemento' : 'elementos'} '
              'por atender fuera de la cola de subida',
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

/// Yunque Exhaustivo 1.35 (S-02): el veredicto de
/// «Comprobar ahora», PURO. La re-descarga de las tablas
/// desfasadas SOLO se afirma si la corrida que debía
/// hacerla corrió de verdad y no terminó en error (la
/// misma exigencia que el Centro aplica con `res.corrio`):
/// si no corrió, fue cortada o falló, el mensaje dice la
/// verdad — hay tablas desfasadas y la re-descarga NO se
/// completó — y el chip no es de éxito.
({String texto, SignificadoChip significado}) mensajeComprobacionSalud({
  required int divergentes,
  SyncResultado? redescarga,
}) {
  if (divergentes < 0) {
    return (
      texto: 'La comprobación no pudo completarse '
          '(¿sin conexión?)',
      significado: SignificadoChip.error,
    );
  }
  if (divergentes == 0) {
    return (
      texto: 'Comprobación completa: todo coincide',
      significado: SignificadoChip.exito,
    );
  }
  final sustantivo = divergentes == 1
      ? 'tabla desfasada'
      : 'tablas desfasadas';
  final errorRedescarga = redescarga?.error;
  final redescargo = redescarga != null &&
      redescarga.corrio &&
      !redescarga.cortadoPorLock &&
      (errorRedescarga == null || errorRedescarga.isEmpty);
  if (redescargo) {
    return (
      texto: 'Se re-descargaron $divergentes $sustantivo',
      significado: SignificadoChip.exito,
    );
  }
  return (
    texto: 'Hay $divergentes $sustantivo, pero la '
        're-descarga no se completó: la sincronización '
        'lo reintentará sola',
    significado: SignificadoChip.alerta,
  );
}

class SaludSyncScreen extends StatefulWidget {
  const SaludSyncScreen({super.key});

  @override
  State<SaludSyncScreen> createState() => _SaludSyncScreenState();
}

class _SaludSyncScreenState extends State<SaludSyncScreen> {
  bool _cargando = true;
  bool _comprobando = false;
  bool _errorCarga = false;
  SaludSyncDatos? _datos;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // 1.36 (136-897): la lectura de salud puede FALLAR (BD
    // cerrada a mitad de arranque, meta ilegible): sin este
    // try/catch la excepción se perdía y la pantalla se
    // quedaba en «Leyendo la salud del sync…» para siempre,
    // sin error ni salida. Ahora el fallo se pinta como
    // error con reintento, como manda el patrón de la casa.
    try {
      final d = await cargarSaludSync();
      if (!mounted) return;
      setState(() {
        _datos = d;
        _errorCarga = false;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorCarga = true;
        _cargando = false;
      });
    }
  }

  // S-03: delega en la pura de salud_sync — con la
  // lectura fallida dice «sin verificar», no «nunca».
  String _fmtFechaHora(DateTime? dt, {bool sinLeer = false}) =>
      textoFechaSaludSync(dt, sinLeer: sinLeer);

  Future<void> _comprobarAhora() async {
    setState(() => _comprobando = true);
    var divergentes = -1;
    try {
      divergentes = await SyncEngine.instance.comprobarManifiestoAhora();
    } catch (_) {}
    // Si hay tablas desfasadas, la sincronización consume
    // las banderas y las re-descarga ahora mismo.
    // S-02: el resultado de esa corrida se CAPTURA — sin
    // él no se puede afirmar que la re-descarga ocurrió.
    SyncResultado? redescarga;
    if (divergentes > 0) {
      try {
        redescarga = await SyncEngine.instance.run(forzar: true);
      } catch (_) {
        redescarga = null;
      }
    }
    if (!mounted) return;
    setState(() => _comprobando = false);
    final veredicto = mensajeComprobacionSalud(
        divergentes: divergentes, redescarga: redescarga);
    mostrarSnack(
      context,
      veredicto.texto,
      significado: veredicto.significado,
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
      case SemaforoTabla.sinLeer:
        // SYNC-12: la familia gris de los «no se sabe», con
        // su nota propia («No se pudo leer…») que lo
        // distingue del gris «nunca bajó».
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
      body: _cargando
          ? const EstadoCargando(texto: 'Leyendo la salud del sync…')
          : _errorCarga || d == null
              ? EstadoError(
                  titulo: 'No se pudo leer la salud del sync',
                  detalle: 'La lectura local falló. La '
                      'sincronización no se ha tocado: vuelve a '
                      'intentarlo.',
                  onReintentar: () {
                    setState(() => _cargando = true);
                    _cargar();
                  },
                )
              : RefrescoIron(
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
                        _fmtFechaHora(d.chequeoEn,
                            sinLeer: d.manifiestoSinLeer)),
                    filaAdmin(context, null, 'Última completa',
                        _fmtFechaHora(d.completaEn,
                            sinLeer: d.manifiestoSinLeer)),
                    filaAdmin(context, null, 'Tablas divergentes',
                        '${d.divergentes}', negrita: d.divergentes > 0),
                    // 1.36 (136-142, C-3): el estado de la
                    // autocura dicho en una línea HONESTA:
                    // «divergente» (hay tablas que no cuadran)
                    // es lo único que se pinta en rojo; el
                    // ESTALE («sin verificar desde hace
                    // mucho», con su fecha) va en alerta, no
                    // en rojo — el campo lo veía todo rojo
                    // con 0 tablas divergentes.
                    Builder(builder: (context) {
                      final estAutocura = estadoAutocura(
                          completaEn: d.completaEn,
                          divergentes: d.divergentes,
                          ahora: ahoraHabana(),
                          sinLeer: d.manifiestoSinLeer);
                      return Text(
                        textoEstadoAutocura(
                            completaEn: d.completaEn,
                            divergentes: d.divergentes,
                            ahora: ahoraHabana(),
                            sinLeer: d.manifiestoSinLeer),
                        style: AppTexto.secundario.copyWith(
                            color: estAutocura ==
                                    EstadoAutocura.divergente
                                ? AppColores.error
                                : estAutocura == EstadoAutocura.estale
                                    ? AppColores.alertaOscuro
                                    : AppColores.textoSecundario(
                                        context)),
                      );
                    }),
                    filaAdmin(context, null, 'Sin verificar',
                        d.manifiestoSinLeer
                            ? 'sin verificar'
                            : '${d.sinVerificar.length}',
                        negrita: d.manifiestoSinLeer ||
                            d.sinVerificar.isNotEmpty),
                    // Yunque 3 (K1-4): el modo de diario
                    // efectivo de la BD (meta que LocalDb deja
                    // en cada apertura) por fin tiene lector:
                    // se pinta como dato de la foto y, si no es
                    // 'wal', como aviso con su consecuencia.
                    filaAdmin(context, null, 'Modo de diario (BD)',
                        d.modoDiarioSinLeer
                            ? 'sin verificar'
                            : d.modoDiarioEfectivo.isEmpty
                                ? '—'
                                : d.modoDiarioEfectivo,
                        negrita:
                            modoDiarioAnomalo(d.modoDiarioEfectivo)),
                    if (avisoModoDiario(d.modoDiarioEfectivo)
                        case final avisoDiario?)
                      Text(
                        avisoDiario,
                        style: AppTexto.secundario
                            .copyWith(color: AppColores.error),
                      ),
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
                              .push(RutaIron(
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
                        _fmtFechaHora(d.copiaUltima,
                            sinLeer: d.copiaSinLeer)),
                    if (d.copiaSinLeer)
                      Text(
                        'Sin verificar: no se pudo leer el '
                        'estado de la copia automática.',
                        style: AppTexto.secundario
                            .copyWith(color: AppColores.alerta),
                      )
                    else if (d.copiaError.isNotEmpty)
                      Text(
                        // Fase 1 (SYNC-10): el error guardado
                        // de la copia es la excepción cruda;
                        // pasa por el traductor de diagnóstico
                        // de la casa, como las notas de tabla
                        // de esta misma pantalla.
                        'La última copia automática falló: '
                        '${resumenErrorDiagnostico(d.copiaError)}',
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
                  // S-03: con la lectura fallida la sección
                  // no desaparece: pinta «Sin verificar».
                  if (mostrarSeccionTelefonosSalud(
                      cantidadTelefonos: d.telefonos.length,
                      telefonosSinLeer: d.telefonosSinLeer))
                    seccionAdmin(context, Icons.phone_android_rounded,
                        'Teléfonos', [
                      if (d.telefonosSinLeer)
                        filaAdmin(context, null,
                            'Estado de los teléfonos',
                            'Sin verificar',
                            negrita: true),
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
                      RutaIron(
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
