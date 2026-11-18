/// Pantallas H del Panel (1.11.0): H1, H2, H5.
///
/// - H1: ajustes del gym en un sitio. ENLAZA lo que ya tiene pantalla
///   (C6 precios, D6 especiales) y solo edita métodos aceptados y
///   textos base. Los cambios rigen hacia adelante, nunca reescriben
///   pagos pasados (los cobros guardan su monto congelado).
/// - H2: registro mensual, VISOR de solo lectura + «Copiar resumen en
///   Markdown». La app JAMÁS escribe el archivo maestro.
/// - H4 (retirada en 1.25 T38): su pantalla intermedia de un solo
///   enlace sobraba; el hub de Turnos llega directo al editor único.
/// - H5: copia de seguridad, EXPORTAR solo (sin restauración).
///   Antes de copiar: PRAGMA wal_checkpoint(TRUNCATE). NUNCA VACUUM.
///   Solo el .db, sin fotos personales. Aviso fijo de copia en frío
///   con el contador de ops pendientes visible ANTES de exportar.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

import '../auth.dart';
import '../bloque2_resto.dart';
import '../config.dart';
import '../copia_seguridad.dart';
import '../localdb.dart';
import '../nomina_calc.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'dialogo_pago.dart' show metodosAceptadosEfectivos;
import 'panel_resto_caja.dart';
import 'tarifas_especiales.dart';
import '../app_log.dart';
import '../errores_sync.dart';

void _ir(BuildContext context, Widget pantalla) {
  Navigator.push(context, RutaIron(builder: (_) => pantalla));
}

// ---------------------------------------------------------------------------
// H1
// ---------------------------------------------------------------------------

class AjustesGymScreen extends StatefulWidget {
  const AjustesGymScreen({super.key});
  @override
  State<AjustesGymScreen> createState() => _AjustesGymScreenState();
}

/// 1.25 T106: una fila del editor de textos base
/// (clave + texto), con sus controladores propios.
class _FilaTextoBase {
  final claveCtrl = TextEditingController();
  final textoCtrl = TextEditingController();
  _FilaTextoBase([String clave = '', String texto = '']) {
    claveCtrl.text = clave;
    textoCtrl.text = texto;
  }

  void dispose() {
    claveCtrl.dispose();
    textoCtrl.dispose();
  }
}

class _AjustesGymScreenState extends State<AjustesGymScreen> {
  bool _cargando = true;
  // 1.23 AT-14: candado anti-doble-toque del guardado.
  bool _guardando = false;
  // 1.25 T106: configuración SIN sintaxis — métodos como
  // interruptores y textos base como filas, nada de
  // comas ni JSON en crudo.
  bool _metEfectivo = true;
  bool _metTransferencia = true;
  final List<_FilaTextoBase> _filasTextos = [];

  // 1.26 (auditoría de botones, BAJA): firma de lo cargado
  // para avisar «cambios sin guardar» al salir — T89 lo
  // puso en Horario del Gym e Información pública y aquí
  // faltaba: salir descartaba los cambios en silencio.
  String _firmaCargada = '';

  // La firma se calcula sobre la forma NORMALIZADA (la
  // misma que arma el guardado): una fila vacía, una
  // clave con espacios o una clave repetida no cuentan
  // como cambio, porque guardar no cambiaría nada
  // (autoauditoría 1.26: la firma cruda daba falsos
  // «cambios sin guardar»).
  String get _firmaActual => jsonEncode({
        'e': _metEfectivo,
        't': _metTransferencia,
        'textos': textosBaseDesdeFilas([
          for (final f in _filasTextos)
            (f.claveCtrl.text, f.textoCtrl.text)
        ]),
      });

  bool get _hayCambios =>
      !_cargando &&
      _firmaCargada.isNotEmpty &&
      _firmaActual != _firmaCargada;

  @override
  void dispose() {
    for (final f in _filasTextos) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02;
    // aquí además _hayCambios exige !_cargando, así que
    // una carga muerta se leía como «sin cambios»).
    try {
      await _cargarDatos();
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
    } finally {
      if (mounted && _cargando) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final aj = await LocalDb.instance.getAjustes();
    // Los métodos salen por la MISMA función que los lee
    // en el diálogo de cobro (efectivo/transferencia).
    final metodos = metodosAceptadosEfectivos(aj['metodos_aceptados']);
    _metEfectivo = metodos.efectivo;
    _metTransferencia = metodos.transferencia;
    final textos = aj['textos_base'];
    if (textos is Map) {
      for (final e in textos.entries) {
        _filasTextos
            .add(_FilaTextoBase('${e.key}', '${e.value ?? ''}'));
      }
    }
    _firmaCargada = _firmaActual;
    if (mounted) setState(() => _cargando = false);
  }

  Future<void> _guardar() async {
    // 1.23 AT-14 (auditoría total de Argón): sin candado, un
    // doble toque encolaba la op de configuración dos veces y
    // disparaba dos syncs; el botón además quedaba activo
    // durante la espera. Guarda + botón deshabilitado mientras
    // guarda (patrón _operacionEnCurso del Panel).
    if (_guardando) return;
    setState(() => _guardando = true);
    try {
      // Corrección panel 1.11 (ALTO): el servidor exige lista
      // para metodos_aceptados y mapa para textos_base — las
      // puras de T106 arman exactamente esas formas desde
      // los interruptores y las filas, sin sintaxis.
      final metodos = metodosDesdeInterruptores(
        efectivo: _metEfectivo,
        transferencia: _metTransferencia,
      );
      // Argón lote 4 MEDIO: dejar la lista en [] dejaba la
      // app sin métodos de pago válidos. Se rechaza.
      if (metodos.isEmpty) {
        throw Exception('Debe quedar al menos un método de pago');
      }
      final textos = textosBaseDesdeFilas([
        for (final f in _filasTextos)
          (f.claveCtrl.text, f.textoCtrl.text),
      ]);
      await guardarConfigGym({
        'metodos_aceptados': metodos,
        // Argón lote 4 MEDIO: omitir la clave dejaba el valor
        // VIEJO (sin filas = mapa vacío = limpio, como antes).
        'textos_base': textos,
      });
      // 1.26: lo guardado es la nueva firma (salir ya no
      // pregunta: no hay cambios sin guardar).
      _firmaCargada = _firmaActual;
      if (mounted) {
        mostrarSnack(context, 'Ajustes guardados y sincronizados', significado: SignificadoChip.exito);
      }
    } catch (e) {
      // 1.36 H-B3 (136-820): snack amable; el detalle a la
      // bitácora (antes salía la Exception cruda).
      AppLog.error('ajustes_gym', 'guardar_fallo', d: '$e');
      if (mounted) {
        mostrarSnack(context, mensajeErrorAmable(e),
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Ajustes del gym'),
          body: const Center(
              child: Text('Solo el dueño cambia ajustes.')));
    }
    // 1.26 (BAJA): atrás con cambios sin guardar pregunta,
    // mismo patrón que T89 en Horario del Gym.
    return PopScope(
      canPop: !_hayCambios,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final salir = await DialogoApp.confirmar(
          context,
          titulo: 'Cambios sin guardar',
          mensaje:
              'Tienes cambios en los ajustes del gym que aún no se han guardado.',
          aceptar: 'Salir sin guardar',
          cancelar: 'Seguir editando',
          icono: Icons.warning_amber_rounded,
          peligro: true,
        );
        if (salir && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
      appBar: appBarIron(context, 'Ajustes del gym'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando ajustes…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                const Text(
                  // 1.25 T36: antes decía «una sola pantalla de
                  // precios» y no era cierto (Tipos de pago y
                  // Otros precios también editan montos).
                  'Los precios y períodos NO se editan aquí: viven '
                  'en el módulo de Precios del Panel. Esto enlaza '
                  'las mismas pantallas, no duplica.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                Tarjeta(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.tune_rounded,
                        color: AppColores.textoSecundario(context)),
                    title: const Text('Precios por método',
                        style: AppTexto.cuerpo),
                    trailing:
                        const Icon(Icons.chevron_right_rounded, size: 18),
                    onTap: () => _ir(context, const PreciosMetodoScreen()),
                  ),
                ),
                Tarjeta(
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.local_offer_rounded,
                        color: AppColores.textoSecundario(context)),
                    title: const Text('Tarifas especiales',
                        style: AppTexto.cuerpo),
                    trailing:
                        const Icon(Icons.chevron_right_rounded, size: 18),
                    onTap: () => _ir(context, const TarifasScreen()),
                  ),
                ),
                const SizedBox(height: 12),
                // 1.25 T106: métodos como INTERRUPTORES
                // (los dos únicos que la app reconoce) y
                // textos base como FILAS etiquetadas.
                const Text('Métodos de pago aceptados',
                    style: AppTexto.titulo),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Efectivo'),
                  subtitle: const Text(
                      'El cobro en mano, el de siempre.'),
                  value: _metEfectivo,
                  onChanged: (v) =>
                      setState(() => _metEfectivo = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Transferencia'),
                  subtitle: const Text(
                      'A la tarjeta del gym (precio de '
                      'transferencia).'),
                  value: _metTransferencia,
                  onChanged: (v) =>
                      setState(() => _metTransferencia = v),
                ),
                if (!_metEfectivo && !_metTransferencia)
                  const Text(
                    'Debe quedar al menos un método encendido: '
                    'sin ninguno, la app ofrecería los dos por '
                    'defecto.',
                    style: TextStyle(color: AppColores.error),
                  ),
                const SizedBox(height: 12),
                const Text('Textos base', style: AppTexto.titulo),
                const Text(
                  'Textos reutilizables del gym, por nombre. '
                  'Ejemplo: nombre «saludo», texto «Hola, te '
                  'escribimos de Iron Body Gym». Sin filas, no '
                  'hay textos.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 8),
                for (var i = 0; i < _filasTextos.length; i++)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: AppEspacio.sm),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: CampoTexto(
                            controller: _filasTextos[i].claveCtrl,
                            etiqueta: 'Nombre',
                            hint: 'saludo',
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        const SizedBox(width: AppEspacio.sm),
                        Expanded(
                          flex: 3,
                          child: CampoTexto(
                            controller: _filasTextos[i].textoCtrl,
                            etiqueta: 'Texto',
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded),
                          tooltip: 'Quitar este texto',
                          onPressed: () => setState(() {
                            _filasTextos[i].dispose();
                            _filasTextos.removeAt(i);
                          }),
                        ),
                      ],
                    ),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('Añadir texto'),
                    onPressed: () => setState(
                        () => _filasTextos.add(_FilaTextoBase())),
                  ),
                ),
                const SizedBox(height: 12),
                // La vista previa: así queda lo que se va
                // a guardar, en lenguaje común.
                Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Vista previa',
                          style: AppTexto.titulo),
                      const SizedBox(height: 4),
                      Text(
                        'Al cobrar se ofrecerá: '
                        '${[
                          if (_metEfectivo) 'Efectivo',
                          if (_metTransferencia) 'Transferencia',
                        ].join(' y ')}'
                        '${!_metEfectivo && !_metTransferencia ? '— (sin métodos: la app ofrecerá los dos por defecto)' : ''}',
                        style: AppTexto.cuerpo,
                      ),
                      for (final f in _filasTextos)
                        if (f.claveCtrl.text.trim().isNotEmpty)
                          Text(
                            'Texto «${f.claveCtrl.text.trim()}»: '
                            '${f.textoCtrl.text}',
                            style: AppTexto.cuerpo,
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 1.36 H-B3 (136-820): con CERO métodos
                // activos, Guardar nace deshabilitado y el
                // motivo va debajo — no se descubre en el
                // snack de error al tocar.
                BotonPrimario(
                  texto: 'Guardar y sincronizar',
                  onPressed: (_guardando ||
                          (!_metEfectivo && !_metTransferencia))
                      ? null
                      : _guardar,
                  cargando: _guardando,
                  expandido: false,
                ),
                if (!_metEfectivo && !_metTransferencia)
                  const Padding(
                    padding: EdgeInsets.only(top: AppEspacio.xs),
                    child: Text(
                      'Activa al menos un método de pago para guardar.',
                      style: AppTexto.secundario,
                    ),
                  ),
                const SizedBox(height: 8),
                const Text(
                  'Los cambios rigen hacia adelante: ningún cobro ya '
                  'hecho cambia su monto.',
                  style: AppTexto.secundario,
                ),
              ],
            ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// H2
// ---------------------------------------------------------------------------

class RegistroMensualScreen extends StatefulWidget {
  const RegistroMensualScreen({super.key});
  @override
  State<RegistroMensualScreen> createState() =>
      _RegistroMensualScreenState();
}

class _RegistroMensualScreenState extends State<RegistroMensualScreen> {
  bool _cargando = true;
  // (136-802) triestado de carga con EstadoError y reintento.
  String? _errorCarga;
  ResumenIngresos? _resumen;
  int _pagaron = 0;
  String _mes = '';

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // Argón lote 4 MEDIO: el visor muestra todos los ingresos brutos;
    // sin gate, un entrenador por ruta lo veía. Dueño en build y aquí.
    if (!AuthService().isOwner) return;
    final mes = mesHabanaActual();
    try {
      final desde = '$mes-01';
      final hasta = hoyHabanaIso();
      // 1.29 (Oleada 2, D-A2): misma migración que
      // «Ingresos del período» — consultas de rango en
      // vez de los cuatro espejos enteros en memoria.
      final filas = await filasIngresoPeriodo(desde, hasta);
      final resumen = resumenIngresos(filas, desde, hasta);
      final pagaron = await NominaCalc.clientesQuePagaronElMes(mes);
      if (mounted) {
        setState(() {
          _mes = mes;
          _resumen = resumen;
          _pagaron = pagaron;
          _errorCarga = null;
          _cargando = false;
        });
      }
    } catch (e) {
      // (136-802) antes el catch mudo pintaba el registro en
      // cero como si fuera un mes sin ingresos.
      if (mounted) {
        setState(() {
          _errorCarga = '$e';
          _cargando = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Registro mensual'),
          body: const Center(
              child: Text('Solo el dueño ve el registro mensual.')));
    }
    final r = _resumen;
    final md = r == null
        ? ''
        : resumenMensualMarkdown(mes: _mes, ingresos: r, pagaron: _pagaron);
    return Scaffold(
      appBar: appBarIron(context, 'Registro mensual'),
      body: _cargando
          ? const EstadoCargando(texto: 'Cargando ajustes…')
          : _errorCarga != null
              ? EstadoError(
                  titulo: 'No se pudo cargar el registro mensual',
                  detalle: _errorCarga,
                  onReintentar: () {
                    setState(() {
                      _errorCarga = null;
                      _cargando = true;
                    });
                    _cargar();
                  },
                )
              : ListView(
                  padding: const EdgeInsets.all(AppEspacio.lg),
                  children: [
                    const Text(
                      'Visor de solo lectura. La copia maestra sigue siendo '
                  'el archivo Markdown que el dueño dicta: la app no '
                  'lo escribe ni lo modifica.',
                  style: AppTexto.secundario,
                ),
                const SizedBox(height: 12),
                if (r != null) ...[
                  Text('Mes: $_mes', style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  Text('Efectivo: ${r.efectivo.toStringAsFixed(0)} CUP',
                      style: AppTexto.cuerpo),
                  Text(
                      'Transferencia: ${r.transferencia.toStringAsFixed(0)} CUP',
                      style: AppTexto.cuerpo),
                  Text('Total: ${r.total.toStringAsFixed(0)} CUP',
                      style: AppTexto.titulo),
                  const SizedBox(height: 8),
                  for (final c in kConceptosC5)
                    Text(
                        '${c[0].toUpperCase()}${c.substring(1)}: '
                        '${(r.porConcepto[c] ?? 0).toStringAsFixed(0)} CUP',
                        style: AppTexto.cuerpo),
                  const SizedBox(height: 8),
                  Text('Pagaron el mes: $_pagaron',
                      style: AppTexto.cuerpo),
                  const Text(
                    'Altas/bajas: se dictan en el archivo maestro (la '
                    'app no guarda fecha de alta en el espejo y no '
                    'inventa el número).',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: 16),
                  BotonPrimario(
                    texto: 'Copiar resumen en Markdown',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: md));
                      if (context.mounted) {
                        mostrarSnack(context, 'Resumen copiado. Pégalo en tu archivo.');
                      }
                    },
                    expandido: false,
                  ),
                ] else
                  // 1.25 T107: vacío con el estándar.
                  const EstadoVacio(
                    icono: Icons.book_rounded,
                    titulo: 'Sin datos del mes',
                    subtitulo:
                        'El registro se arma con los cobros y '
                        'gastos del mes: aún no hay ninguno.',
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// H5
// ---------------------------------------------------------------------------

class CopiaSeguridadScreen extends StatefulWidget {
  const CopiaSeguridadScreen({super.key});
  @override
  State<CopiaSeguridadScreen> createState() => _CopiaSeguridadScreenState();
}

class _CopiaSeguridadScreenState extends State<CopiaSeguridadScreen> {
  int _pendientes = -1;
  bool _exportando = false;
  bool _verificando = false;

  /// Módulo 6 (1.19): trazabilidad de copias. Registro local (meta
  /// `copias_seguridad`, últimas 10): fecha, tamaño, versión,
  /// alcance y verificación. La copia en sí se comparte fuera; aquí
  /// queda el registro, no el archivo.
  List<Map<String, dynamic>> _registro = [];

  /// Copia recién exportada en esta sesión, si sigue en disco:
  /// es la única verificable (abrirla y contar registros).
  File? _ultimaCopia;
  Map<String, int>? _ultimaVerificacion;

  /// Entrada del registro que corresponde a [_ultimaCopia] (panel
  /// Terra: la verificación marca ESTA entrada, no _registro[0],
  /// para no atribuirla a otra copia exportada entretanto).
  Map<String, dynamic>? _entradaVerificando;

  static const _tablasVerificar = [
    'clientes',
    'pagos',
    'pagos_diarios',
    'ventas_suplementos',
    'servicio_ventas',
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    try {
      final p = await LocalDb.instance.countPendingOps();
      if (mounted) setState(() => _pendientes = p);
    } catch (_) {}
    try {
      final raw = await LocalDb.instance.getMeta('copias_seguridad');
      if (raw != null && raw.isNotEmpty && mounted) {
        setState(() {
          _registro = (jsonDecode(raw) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _guardarRegistro() async {
    try {
      await LocalDb.instance
          .setMeta('copias_seguridad', jsonEncode(_registro));
    } catch (_) {}
  }

  String _tamano(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  bool _esVieja(String? fechaIso) {
    if (fechaIso == null || fechaIso.length < 10) return true;
    try {
      final f = DateTime.parse(fechaIso.substring(0, 10));
      // Panel Terra (baja): nunca DateTime.now() crudo en lógica.
      return ahoraHabana().difference(f).inDays > 30;
    } catch (_) {
      return true;
    }
  }

  Future<void> _exportar() async {
    setState(() => _exportando = true);
    try {
      // 1.14 (M6.30): la copia en frío vive en exportarCopiaFria.
      final destino = await exportarCopiaFria();
      final tamano = await destino.length();
      await registrarAccionMantenimiento(
          'f5_exportar_copia', {'pendientes_al_exportar': _pendientes});
      // Módulo 6 (1.19): registrar la copia para trazabilidad.
      final entrada = <String, dynamic>{
        'fecha': isoHabana(ahoraHabana()),
        'tamano_bytes': tamano,
        'version': AppConfig.appVersion,
        'alcance': 'BD sin fotos',
        'verificada': false,
      };
      if (mounted) {
        setState(() {
          _registro = [entrada, ..._registro].take(10).toList();
          _ultimaCopia = destino;
          _ultimaVerificacion = null;
          _entradaVerificando = entrada;
        });
      }
      // W6 (1.20): la copia se VERIFICA al exportarla,
      // antes de compartirla — abrirla y contar sus tablas.
      // Si la verificación falla, el dueño decide si la
      // comparte de todos modos; el fallo queda registrado.
      var compartir = true;
      try {
        final conteos = await _conteosDeCopia(destino);
        entrada['verificada'] = true;
        entrada['registros'] = conteos;
        if (mounted) {
          setState(() => _ultimaVerificacion = conteos);
        }
      } catch (e) {
        entrada['verificacion_error'] = '$e';
        if (mounted) {
          compartir = await DialogoApp.confirmar(
            context,
            titulo: 'Copia sin verificar',
            mensaje: 'La copia se creó, pero no se pudo '
                'verificar: $e\n\n¿Compartirla de todos modos?',
            aceptar: 'Compartir igual',
            cancelar: 'No compartir',
            icono: Icons.warning_amber_rounded,
            peligro: true,
          );
        }
      }
      await _guardarRegistro();
      if (compartir) {
        await Share.shareXFiles([XFile(destino.path)],
            text:
                'Copia de seguridad Iron Body Gym (solo BD, sin fotos).');
      } else if (mounted) {
        mostrarSnack(context,
            'Copia guardada en el teléfono, sin compartir.',
            significado: SignificadoChip.alerta);
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo exportar: $e', significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _exportando = false);
    }
  }

  /// Módulo 6 (1.19): verificar que la copia abre y cuántos
  /// registros trae en las tablas principales. Solo en sesión: la
  /// copia compartida fuera ya no está en este teléfono.
  /// Panel Terra (alta): la copia que se verifica es la RECIÉN
  /// creada (las 5 tablas existen en el esquema actual), así que
  /// cualquier tabla que no se pueda contar es FALLO, no «tabla
  /// ausente»: una verificación con cero tablas contadas nunca se
  /// marca como verificada.
  /// W6 (1.20): núcleo de la verificación de una copia —
  /// la abre en solo lectura y cuenta las tablas
  /// principales. Devuelve los conteos o lanza StateError
  /// con el motivo. Lo comparten la verificación manual y
  /// la automática al exportar.
  Future<Map<String, int>> _conteosDeCopia(File copia) async {
    if (!await copia.exists()) {
      throw StateError('La copia ya no está en este teléfono');
    }
    final db = await openDatabase(copia.path, readOnly: true);
    final conteos = <String, int>{};
    final fallos = <String>[];
    try {
      for (final t in _tablasVerificar) {
        try {
          final r =
              await db.rawQuery('SELECT COUNT(*) AS n FROM $t');
          conteos[t] = (r.first['n'] as num?)?.toInt() ?? 0;
        } catch (_) {
          fallos.add(t);
        }
      }
    } finally {
      await db.close();
    }
    if (fallos.isNotEmpty) {
      throw StateError(
          'No se pudieron contar: ${fallos.join(', ')}');
    }
    if (conteos.isEmpty) {
      throw StateError('La copia no trajo registros contables');
    }
    return conteos;
  }

  Future<void> _verificar() async {
    final copia = _ultimaCopia;
    if (copia == null) return;
    setState(() => _verificando = true);
    try {
      final conteos = await _conteosDeCopia(copia);
      await registrarAccionMantenimiento(
          'f5_verificar_copia', {'registros': conteos});
      if (mounted) {
        setState(() {
          _ultimaVerificacion = conteos;
          final entrada = _entradaVerificando;
          if (entrada != null) {
            entrada['verificada'] = true;
            entrada['registros'] = conteos;
          }
        });
      }
      await _guardarRegistro();
    } catch (e) {
      if (mounted) {
        mostrarSnack(context, 'No se pudo verificar: $e', significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _verificando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      return Scaffold(
          appBar: appBarIron(context, 'Copia de seguridad'),
          body: const Center(
              child: Text('Exportar la BD es solo el dueño.')));
    }
    return Scaffold(
      appBar: appBarIron(context, 'Copia de seguridad'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          Tarjeta(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(kAvisoCopiaFria, style: AppTexto.cuerpo),
                const SizedBox(height: 8),
                Text(
                  'Operaciones pendientes de subir ahora: '
                  '${_pendientes < 0 ? '—' : _pendientes}',
                  style: AppTexto.cuerpo,
                ),
                const SizedBox(height: 4),
                const Text(
                  'La copia incluye solo la base de datos, sin fotos '
                  'personales (las fotos ya viven en el servidor). No '
                  'hay botón de restaurar en esta versión.',
                  style: AppTexto.secundario,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed:
                (_exportando || _verificando) ? null : _exportar,
            child: Text(_exportando ? 'Exportando…' : 'Exportar copia'),
          ),
          if (_ultimaCopia != null) ...[
            const SizedBox(height: 12),
            ElevatedButton(
              // Panel Terra (media): exportar y verificar no se
              // solapan (la verificación no debe marcar otra copia).
              onPressed:
                  (_verificando || _exportando) ? null : _verificar,
              child: Text(_verificando
                  ? 'Verificando…'
                  : 'Verificar esta copia (abre y cuenta registros)'),
            ),
          ],
          if (_ultimaVerificacion != null) ...[
            const SizedBox(height: 12),
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Copia verificada: abre y trae',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 4),
                  for (final e in _ultimaVerificacion!.entries)
                    Text('${e.key}: ${e.value} registros',
                        style: AppTexto.cuerpo),
                ],
              ),
            ),
          ],
          if (_registro.isNotEmpty) ...[
            const SizedBox(height: 16),
            const Text('Copias anteriores (registro, no archivo)',
                style: AppTexto.subtitulo),
            const SizedBox(height: 8),
            for (final r in _registro)
              Padding(
                padding: const EdgeInsets.only(bottom: AppEspacio.sm),
                child: Tarjeta(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${'${r['fecha'] ?? ''}'.length >= 10 ? '${r['fecha']}'.substring(0, 10) : '${r['fecha'] ?? ''}'} · '
                        '${_tamano((r['tamano_bytes'] as num?)?.toInt() ?? 0)} · '
                        '${r['version'] ?? ''}',
                        style: AppTexto.cuerpo,
                      ),
                      Text(
                        '${r['alcance'] ?? ''}'
                        '${_esVieja('${r['fecha'] ?? ''}') ? ' · Copia vieja (+30 días)' : ''}',
                        style: AppTexto.secundario,
                      ),
                      const SizedBox(height: AppEspacio.xs),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ChipEstado.semantico(
                          texto: r['verificada'] == true
                              ? 'Verificada'
                              : r['verificacion_error'] != null
                                  ? 'Verificación fallida'
                                  : 'Sin verificar',
                          significado: r['verificada'] == true
                              ? SignificadoChip.exito
                              : r['verificacion_error'] != null
                                  ? SignificadoChip.error
                                  : SignificadoChip.neutral,
                        ),
                      ),
                      if (r['registros'] is Map)
                        Text(
                          'Registros: ${(r['registros'] as Map).entries.map((e) => '${e.key} ${e.value}').join(' · ')}',
                          style: AppTexto.secundario,
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
