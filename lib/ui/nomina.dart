import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../auth.dart';
import '../localdb.dart';
import '../adelantos.dart';
import '../negocio.dart';
import '../nomina_bonos.dart';
import '../nomina_calc.dart';
import '../nomina_foto.dart';
import '../nomina_precalc.dart';
import '../perfil.dart';
import '../permisos_entrenador.dart';
import '../sync.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'cierre_mes.dart';
import 'cierre_nomina_imagen.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'mi_nomina.dart';
import 'skeleton.dart';

/// v1.3.7 (Fase A, 6.1): pre-cálculo de nómina mensual.
/// v1.3.9 Sprint 3 (#8): + bono manual editable por el dueño.
/// Fórmula (Jc): (clientes que pagaron el mes) × 150 CUP + bono manual.
/// El dueño ve todo; el entrenador ve su tarjeta en el Home.
class NominaScreen extends StatefulWidget {
  const NominaScreen({super.key});

  @override
  State<NominaScreen> createState() => _NominaScreenState();
}

class _NominaScreenState extends State<NominaScreen> {
  bool _cargando = true;
  // Pasada 2 de Argón (1.20): candado de las acciones de
  // dinero de esta pantalla (bono, tarifa) contra doble toque.
  bool _operando = false;
  int _clientesPagados = 0;
  // v1.4.0: sello del pre-cálculo ("Actualizado: ...").
  String _actualizadoEtiqueta = '';
  String _mesEtiqueta = '';
  // v1.3.9: lista de bonos por entrenador [{id, entrenador, monto, nota}]
  List<Map<String, dynamic>> _bonos = [];
  final _bonoMontoCtrl = TextEditingController();
  final _bonoNotaCtrl = TextEditingController();
  String _bonoEntrenador = 'ambos'; // 'duany', 'gabriel', 'ambos'
  final _tarifaCtrl = TextEditingController();
  double _tarifa = 150;
  // v1.8.0: comisión por dosis del mes por entrenador (clave
  // 'duany'/'gabriel'; el entrenador además la ve bajo 'mi').
  Map<String, ({int dosis, double total})> _comisionDosis = {};

  // v1.8.0: adelantos — personas (username -> identidad APK),
  // libro del mes en curso por entrenador, eventos completos y
  // si la nómina del mes ya está liquidada para cada uno.
  Map<String, ({String id, int? telegramId, String nombre})>
      _personasAdelantos = {};
  Map<String, MesLibroAdelantos> _libroMes = {};
  Map<String, List<Map<String, dynamic>>> _eventosAdelantos = {};
  Map<String, bool> _nominaLiquidadaMes = {};
  // T22 (1.20): confirmación de recepción por entrenador
  // (espejo u op local), para mostrar el acuse al dueño.
  Map<String, Map<String, dynamic>?> _confirmacionMes = {};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void dispose() {
    _bonoMontoCtrl.dispose();
    _bonoNotaCtrl.dispose();
    _tarifaCtrl.dispose();
    super.dispose();
  }

  // (M2-A A4) generación de carga: dos _cargar solapados (p.
  // ej. pull-to-refresh + retorno de un diálogo) podían
  // terminar fuera de orden y la foto VIEJA pisaba la fresca;
  // solo chequeaba mounted.
  int _genCarga = 0;

  Future<void> _cargar() async {
    final gen = ++_genCarga;
    setState(() => _cargando = true);
    final ahora = ahoraHabana();
    final pref = hoyHabanaIso().substring(0, 7); // YYYY-MM
    _mesEtiqueta = _nombreMes(ahora.month);
    // Misma fuente que "Pagos realizados": clientes únicos con pago
    // este mes. v1.4.0: cálculo compartido en NominaCalc (lo usan
    // también el home y el pre-cálculo; no pueden divergir).
    // Primero se sirve la caché del pre-cálculo (apertura instantánea);
    // si su huella quedó vieja, se recalcula en segundo plano y la
    // pantalla se refresca sola cuando termina.
    final cache = await NominaPrecalc.instance.leer(pref);
    final desdeCache = cache != null && cache.fresco;
    // Solo se compone dinero con una base FRESCA: si la caché está
    // vieja se espera el recálculo (asegurar) en vez de mostrar una
    // nómina provisional calculada con la cifra anterior
    // (auditoría del código, terra). Con caché fresca la apertura
    // sigue siendo instantánea, que es el objetivo del pre-cálculo.
    final clientesPagados = desdeCache
        ? cache.clientes
        : await NominaPrecalc.instance.asegurar(pref);
    if (mounted) {
      // La pantalla pudo cerrarse durante los awaits que
      // siguen: la guarda previa al setState está más abajo
      // (auditoría, terra).
      // Fase A 2026-10-25 (A4) + 1.23 (B3 Paso 3, delta del
      // panel): la migración de bonos legados desde prefs y la
      // lectura del mes viven en nomina_foto.dart
      // (leerBonosMesConMigracion), compartidas con el Panel
      // del dueño — el panel leía los bonos SIN migrar y su
      // neto podía omitir un bono legado que esta pantalla sí
      // incorporaba al abrirla.
      final bonos = await leerBonosMesConMigracion(pref);
      // 1.23 (B3 Paso 3b): el ensamblado de componentes del
      // mes (tarifa, comisiones, personas, libro de adelantos,
      // liquidadas y confirmaciones) vive en nomina_foto.dart,
      // compartido con la tarjeta de nómina del Panel del
      // dueño: una sola foto, dos pantallas. Aquí quedan el
      // conteo del pre-cálculo y el estado de la UI; los bonos
      // llegan de leerBonosMesConMigracion (arriba).
      final foto = await fotoNominaMes(pref);
      // #7 (Argón nómina): el doble chequeo era redundante.
      // (M2-A A4) y si una carga más nueva ya arrancó, esta
      // foto vieja no pisa su estado.
      if (!mounted || gen != _genCarga) return;
      setState(() {
        _comisionDosis = foto.comisionDosis;
        _personasAdelantos = foto.personas;
        _libroMes = foto.libroMes;
        _eventosAdelantos = foto.eventosPorEnt;
        _nominaLiquidadaMes = foto.liquidadas;
        _confirmacionMes = foto.confirmaciones;
        _clientesPagados = clientesPagados;
        _bonos = bonos;
        _tarifa = foto.tarifa.toDouble();
        _tarifaCtrl.text = foto.tarifa.toString();
        _actualizadoEtiqueta = _etiquetaActualizado(desdeCache
            ? cache.calculadoEn
            : ahoraHabana().toIso8601String());
        _cargando = false;
      });
    }
  }

  /// 1.28 (M3-C3): la foto del cierre de mes como imagen con
  /// marca. Las filas salen del MISMO estado que pinta la
  /// pantalla (la foto única por entrenador: base, bono,
  /// comisión, adelantos, deuda y neto por totalVivo), así
  /// que la imagen nunca discrepa de lo que el dueño está
  /// viendo. Se captura con RepaintBoundary y se comparte
  /// como PNG.
  Future<void> _mostrarFotoCierre() async {
    final base = _clientesPagados * _tarifa;
    final filas = <FilaCierreNomina>[];
    for (final ent in ['duany', 'gabriel']) {
      final persona = _personasAdelantos[ent];
      if (persona == null) continue;
      final bono = _bonoPara(ent);
      final comision = _comisionDosis[ent]?.total ?? 0;
      final libro = _libroMes[ent];
      final adelantos = libro?.adelantos ?? 0;
      final deuda = libro?.deudaEntrante ?? 0;
      filas.add(FilaCierreNomina(
        nombre: persona.nombre,
        base: base,
        bono: bono,
        comision: comision,
        adelantos: adelantos,
        deuda: deuda,
        neto: NominaCalc.totalVivo(
          base: base,
          bono: bono,
          comision: comision,
          adelantos: adelantos,
          deudaEntrante: deuda,
        ),
        liquidada: _nominaLiquidadaMes[ent] ?? false,
      ));
    }
    if (filas.isEmpty) {
      mostrarSnack(context, 'Aún no hay nómina que fotografiar.');
      return;
    }
    final ahora = ahoraHabana();
    final mesEtiqueta = '${_nombreMes(ahora.month)} de ${ahora.year}';
    final boundaryKey = GlobalKey();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Foto del cierre de mes'),
        content: SingleChildScrollView(
          child: RepaintBoundary(
            key: boundaryKey,
            child: ImagenCierreNomina(
              mesEtiqueta: mesEtiqueta,
              filas: filas,
              generadoEtiqueta: 'Generada el ${ahora.day} de '
                  '${_nombreMes(ahora.month).toLowerCase()} de '
                  '${ahora.year} · Iron Body Gym',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cerrar'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.share_rounded, size: 18),
            label: const Text('Compartir imagen'),
            onPressed: () async {
              try {
                final boundary = boundaryKey.currentContext!
                    .findRenderObject() as RenderRepaintBoundary;
                final imagen =
                    await boundary.toImage(pixelRatio: 3.0);
                final datos = await imagen.toByteData(
                    format: ui.ImageByteFormat.png);
                if (datos == null) return;
                final dir = await getTemporaryDirectory();
                final f = await File(
                        '${dir.path}/cierre_nomina_'
                        '${hoyHabanaIso().substring(0, 7)}.png')
                    .writeAsBytes(datos.buffer.asUint8List());
                await Share.shareXFiles([XFile(f.path)],
                    text: 'Cierre de nómina · $mesEtiqueta · '
                        'Iron Body Gym');
              } catch (_) {
                if (mounted) {
                  mostrarSnack(context,
                      'No se pudo compartir la imagen',
                      significado: SignificadoChip.error);
                }
              }
            },
          ),
        ],
      ),
    );
  }

  /// "20 de octubre, 12:40" a partir de un ISO guardado por el
  /// pre-cálculo. Si el ISO no parsea, devuelve el texto tal cual.
  String _etiquetaActualizado(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '${d.day} de ${_nombreMes(d.month).toLowerCase()}, $hh:$mm';
  }

  /// Suma solo los bonos generales ('ambos'), contados una vez.
  /// Respaldo defensivo cuando no se puede identificar al entrenador.
  double _bonoSoloAmbos() => NominaCalc.bonoSoloAmbos(_bonos);

  /// Suma de bonos aplicables a un entrenador ('duany' o 'gabriel').
  double _bonoPara(String entrenador) =>
      NominaCalc.bonosPara(_bonos, entrenador);

  Future<void> _agregarBono() async {
    // Ronda 17 M4-H1: agregar bonos es solo del dueño
    // (la UI ya oculta el botón; esto cubre pantalla abierta
    // con cambio de sesión).
    if (!AuthService().isOwner) return;
    if (_operando) return;
    final texto =
        _bonoMontoCtrl.text.trim().replaceAll(',', '.');
    // Autoauditoría 1.22 #1: montoTolerante (N-2) en vez del
    // tryParse crudo: un 'Infinity'/'NaN' pegado en el campo
    // pasaba el filtro (≠0) y reventaba al encolar el bono
    // (JSON no codifica infinitos) sin aviso al dueño.
    final monto = NominaCalc.montoTolerante(texto) ?? 0;
    if (monto == 0) {
      mostrarSnack(context, 'Ingresa un monto válido', significado: SignificadoChip.alerta);
      return;
    }
    // Pasada 2 de Argón (1.20): capturar la nota y LIMPIAR los
    // controladores sincrónicamente, antes del primer await;
    // con la limpieza tras el await, un doble toque insertaba
    // el bono dos veces.
    final notaBono = _bonoNotaCtrl.text.trim();
    _bonoMontoCtrl.clear();
    _bonoNotaCtrl.clear();
    _operando = true;
    // Panel Zen pieza 1 (MEDIO): la guarda se libera en
    // finally: si agregar o la relectura lanzan (BD/encolado),
    // _operando no puede quedar pegado bloqueando la pantalla.
    try {
      // Fase A 2026-10-25 (A4): el bono se guarda sincronizado
      // (espejo + op), no en SharedPreferences.
      final pref = hoyHabanaIso().substring(0, 7);
      // N-6 (1.22): un mes ya liquidado no admite bonos: el bono
      // descuadraría la foto de liquidación y el Dashboard.
      final objetivosBono = _bonoEntrenador == 'ambos'
          ? const ['duany', 'gabriel']
          : [_bonoEntrenador];
      if (objetivosBono.any((c) => _nominaLiquidadaMes[c] == true)) {
        mostrarSnack(context,
            'La nómina de este mes ya está liquidada: no se pueden agregar bonos',
            significado: SignificadoChip.alerta);
        return;
      }
      await BonosNominaService.instance.agregar(
        mes: pref,
        entrenador: _bonoEntrenador,
        monto: monto,
        nota: notaBono,
      );
      final actualizados =
          await BonosNominaService.instance.leerBonos(pref);
      if (!mounted) return;
      setState(() {
        _bonos = actualizados;
        _bonoMontoCtrl.clear();
        _bonoNotaCtrl.clear();
      });
      if (mounted) {
        mostrarSnack(context, 'Bono agregado', significado: SignificadoChip.exito);
      }
    } finally {
      _operando = false;
    }
  }

  Future<void> _eliminarBono(String id) async {
    // Ronda 17 M4-H1: eliminar bonos es solo del dueño.
    if (!AuthService().isOwner) return;
    // N-7 (1.22): guarda anti-doble toque (no la tenía).
    if (_operando) return;
    // N-6 (1.22): tampoco se eliminan bonos de un mes ya
    // liquidado (misma foto que no se debe reescribir).
    final fila = _bonos.where((b) => '${b['id']}' == id).firstOrNull;
    final entBono = '${fila?['entrenador'] ?? 'ambos'}';
    final objetivosBono =
        entBono == 'ambos' ? const ['duany', 'gabriel'] : [entBono];
    if (objetivosBono.any((c) => _nominaLiquidadaMes[c] == true)) {
      mostrarSnack(context,
          'La nómina de este mes ya está liquidada: no se pueden eliminar bonos',
          significado: SignificadoChip.alerta);
      return;
    }
    _operando = true;
    // Panel Zen pieza 1 (MEDIO): guarda liberada en finally.
    try {
      // Fase A 2026-10-25 (A4): encola la eliminación; la
      // lectura fusionada lo oculta al instante.
      await BonosNominaService.instance.eliminar(id);
      final pref = hoyHabanaIso().substring(0, 7);
      final actualizados =
          await BonosNominaService.instance.leerBonos(pref);
      if (!mounted) return;
      setState(() => _bonos = actualizados);
      if (mounted) {
        mostrarSnack(context, 'Bono eliminado', significado: SignificadoChip.exito);
      }
    } finally {
      _operando = false;
    }
  }

  String _nombreMes(int m) {
    const meses = [
      '',
      'enero',
      'febrero',
      'marzo',
      'abril',
      'mayo',
      'junio',
      'julio',
      'agosto',
      'septiembre',
      'octubre',
      'noviembre',
      'diciembre'
    ];
    return (m >= 1 && m <= 12) ? meses[m] : '';
  }

  /// Filas por entrenador con su total (base + sus bonos).
  List<Widget> _buildFilasEntrenadores(
      BuildContext context, double base) {
    final esDueno = AuthService().isOwner;
    // El dueño ve las dos filas. El entrenador ve solo la suya: SÍ se
    // puede identificar por AuthService().username ('duany'/'gabriel').
    // (Ajuste Argón, revisión Paso 1: antes la vista 'mi' sumaba los
    // bonos de ambos y duplicaba los bonos marcados 'ambos', además de
    // mezclar los bonos individuales del otro entrenador.)
    final yo = AuthService().username;
    final entrenadores = esDueno
        ? ['duany', 'gabriel']
        : [
            if (yo == 'duany' || yo == 'gabriel') yo else 'mi',
          ];
    return entrenadores.map((ent) {
      final nombre = ent == 'duany'
          ? 'Duany'
          : ent == 'gabriel'
              ? 'Gabriel'
              : 'Pago por entrenador';
      // 'mi' solo como respaldo si el username no es de un entrenador
      // conocido: en ese caso únicamente los bonos generales ('ambos'),
      // contados UNA sola vez.
      final bono = ent == 'mi' ? _bonoSoloAmbos() : _bonoPara(ent);
      // v1.8.0: la comisión por dosis se suma a la nómina del mes.
      final comision = _comisionDosis[ent] ?? (dosis: 0, total: 0.0);
      // v1.8.0: los adelantos del mes (por mes_nomina) y la deuda
      // arrastrada DESCUENTAN; el total mostrado es el neto a
      // pagar (nunca negativo: el exceso queda como deuda).
      final libro = _libroMes[ent];
      final adelantosMes = libro?.adelantos ?? 0;
      final deudaEntrante = libro?.deudaEntrante ?? 0;
      // 1.14 (M5.1): la fórmula vive en NominaCalc.totalVivo.
      final total = NominaCalc.totalVivo(
        base: base,
        bono: bono,
        comision: comision.total,
        adelantos: adelantosMes,
        deudaEntrante: deudaEntrante,
      );
      final liquidada = _nominaLiquidadaMes[ent] ?? false;
      return Padding(
        padding: const EdgeInsets.only(bottom: AppEspacio.sm),
        // 1.25 T25: bajo las cifras, la barra de composición
        // (la misma de Mi Nómina): el «por qué» del neto de
        // un vistazo, no solo cuatro numeritos.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
          children: [
            Expanded(
              child: Text(
                nombre,
                style: AppTexto.cuerpo.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${fmtMonto(total)} CUP',
                  style: AppTexto.tituloPagina.copyWith(
                      color: colorCifraNomina(total)),
                ),
                if (bono != 0)
                  Text(
                    '${bono > 0 ? '+' : ''}${fmtMonto(bono)} bono',
                    style: AppTexto.metadato.copyWith(
                        color: colorCifraNomina(bono)),
                  ),
                if (comision.total != 0)
                  Text(
                    '${comision.total > 0 ? '+' : ''}'
                    '${fmtMonto(comision.total)} comisión dosis '
                    '(${comision.dosis})',
                    style: AppTexto.metadato.copyWith(
                        color: colorCifraNomina(comision.total)),
                  ),
                if (adelantosMes != 0)
                  Text(
                    '−${fmtMonto(adelantosMes)} adelantos',
                    style: AppTexto.metadato.copyWith(color: AppColores.error),
                  ),
                if (deudaEntrante > 0)
                  Text(
                    '−${fmtMonto(deudaEntrante)} deuda anterior',
                    style: AppTexto.metadato.copyWith(color: AppColores.error),
                  ),
                if (liquidada)
                  Text(
                    '✓ nómina pagada',
                    style: AppTexto.metadato.copyWith(color: AppColores.exito),
                  ),
              ],
            ),
          ],
        ),
            const SizedBox(height: AppEspacio.sm),
            BarraComposicionNomina(
              bruto: base + bono + comision.total,
              neto: total,
              descuentos: adelantosMes + deudaEntrante,
            ),
          ],
        ),
      );
    }).toList();
  }

  /// Nombre legible del destino del bono.
  String _nombreDestino(String d) {
    if (d == 'duany') return 'Duany';
    if (d == 'gabriel') return 'Gabriel';
    return 'Ambos';
  }

  /// Fila de bono con nota y botón eliminar.
  Widget _buildFilaBono(
      BuildContext context, Map<String, dynamic> b) {
    final monto = (b['monto'] as num?)?.toDouble() ?? 0;
    final nota = '${b['nota'] ?? ''}';
    final destino = _nombreDestino('${b['entrenador'] ?? 'ambos'}');
    // 1.28 (M3-A4): un bono rechazado por el servidor se sigue
    // MOSTRANDO (no se pierde en silencio) con su aviso, y no
    // suma en ningún total (NominaCalc lo salta).
    final rechazado = b['rechazado'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: ListTile(
        leading: Icon(
          monto >= 0 ? Icons.add_circle_rounded : Icons.remove_circle_rounded,
          color: colorCifraNomina(monto),
        ),
        title: Text(
          '${monto > 0 ? '+' : ''}${fmtMonto(monto)} CUP — $destino',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: (nota.isEmpty && !rechazado)
            ? null
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (nota.isNotEmpty) Text(nota),
                  if (rechazado)
                    Text(
                      'Rechazado por el servidor: no cuenta en la nómina.',
                      style: AppTexto.metadato
                          .copyWith(color: AppColores.error),
                    ),
                ],
              ),
        trailing: IconButton(
          icon: const Icon(Icons.delete_rounded, color: AppColores.error),
          tooltip: 'Eliminar bono',
          onPressed: () => _eliminarBono('${b['id']}'),
        ),
      ),
    );
  }

  Future<void> _guardarTarifa() async {
    // Ronda 17 M4-H1: cambiar la tarifa es solo del dueño.
    if (!AuthService().isOwner) return;
    if (_operando) return;
    _operando = true;
    final texto = _tarifaCtrl.text.trim().replaceAll(',', '.');
    // Autoauditoría 1.22 #1: montoTolerante (N-2): 'Infinity'/
    // 'NaN' pegados pasaban el filtro (<=0 es falso para ambos)
    // y tarifa.toInt() lanzaba sin guardar ni avisar.
    final tarifa = NominaCalc.montoTolerante(texto) ?? 150;
    if (tarifa <= 0) {
      _operando = false;
      mostrarSnack(context, 'Ingresa una tarifa válida', significado: SignificadoChip.alerta);
      return;
    }
    // Autoauditoría 1.22 #1: la guarda se libera en finally,
    // como en los cinco métodos que corrigió el panel en la
    // pieza 1 (este quedó fuera): si setPagoEntrenador lanzaba
    // (BD/prefs), _operando quedaba pegado y TODAS las acciones
    // de dinero de la pantalla morían hasta recrearla.
    try {
      await PerfilService.instance.setPagoEntrenador(tarifa.toInt());
      // Argón Acceso #9: que el cambio viaje ya, no en el próximo
      // evento de sync.
      SyncEngine.instance.push();
      setState(() => _tarifa = tarifa);
      if (mounted) {
        mostrarSnack(context, 'Tarifa actualizada', significado: SignificadoChip.exito);
      }
    } finally {
      _operando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // v1.3.9: el entrenador también puede ver su nómina.
    // El dueño ve el desglose completo + bonos por entrenador.
    final pagoPorCliente = _tarifa;
    final base = _clientesPagados * pagoPorCliente;
    final ahora = ahoraHabana();
    final proyeccion =
        'Proyección al día ${ahora.day.toString().padLeft(2, '0')}/'
        '${ahora.month.toString().padLeft(2, '0')}';
    final esDueno = AuthService().isOwner;
    return Scaffold(
      appBar: appBarIron(
        context,
        'Nómina del mes',
        acciones: [
          // 1.28 (M3-C3): la foto del cierre como imagen con
          // marca, lista para compartir (solo dueño).
          if (esDueno && !_cargando)
            IconButton(
              icon: const Icon(Icons.image_rounded),
              tooltip: 'Foto del cierre',
              onPressed: _mostrarFotoCierre,
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Actualizar',
            onPressed: _cargar,
          ),
        ],
      ),
      body: _cargando
          // 1.28 (M3-C6): esqueleto espejo de la pantalla.
          ? const SkeletonNomina()
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // 1.23 (W2): la puerta del cierre de mes guiado
                // vive aquí (solo dueño): es la pantalla desde
                // la que naturalmente se cierra el mes.
                if (esDueno) ...[
                  Tarjeta(
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const CierreMesScreen()),
                      );
                      if (!mounted) return;
                      _cargar();
                    },
                    child: Row(
                      children: [
                        IconoModuloBadge.verde(
                            Icons.event_available_rounded),
                        const SizedBox(width: AppEspacio.md),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text('Cierre de mes guiado',
                                  style: AppTexto.subtitulo),
                              Text(
                                'La ruta completa: sync, nómina, '
                                'arqueo, entregas y respaldo, paso '
                                'a paso con verificación.',
                                style: AppTexto.secundario,
                              ),
                            ],
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppEspacio.lg),
                ],
                Tarjeta(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          IconoModuloBadge.naranja(
                              Icons.payments_rounded),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              esDueno
                                  ? 'Nómina por entrenador'
                                  : 'Mi nómina',
                              style: AppTexto.titulo,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Ronda 17 M4-H1 (decisión Jc 2026-10-28):
                      // sin can_ver_cifras no se muestra el conteo
                      // global; el entrenador ve solo su monto base.
                      if (esDueno ||
                          PermisosEntrenador().canVerCifras)
                        Text(
                          '$_clientesPagados clientes pagados en $_mesEtiqueta '
                          '× ${fmtMonto(pagoPorCliente)} CUP',
                          style: AppTexto.cuerpo.copyWith(
                            color: AppColores.textoSecundario(
                                context),
                          ),
                        ),
                      const SizedBox(height: 4),
                      // v1.4.0: sello del pre-cálculo automático.
                      Text(
                        'Actualizado: $_actualizadoEtiqueta',
                        style: AppTexto.etiqueta.copyWith(
                          color: AppColores.textoSecundario(
                              context),
                        ),
                      ),
                      const SizedBox(height: 12),
                      // Desglose por entrenador
                      ..._buildFilasEntrenadores(
                          context, base),
                      // v1.8.0: adelantos del mes por entrenador.
                      ..._buildSeccionesAdelantos(context),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppEspacio.md, vertical: AppEspacio.sm),
                        decoration: BoxDecoration(
                          color: AppColores.naranja
                              .withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(
                              AppRadio.md),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                                Icons.info_outline_rounded,
                                size: 16,
                                color: AppColores.info),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                '$proyeccion — no es la cifra final. '
                                'El pago se hace el último día del mes.',
                                style: AppTexto.etiqueta.copyWith(
                                  color: AppColores
                                      .textoSecundario(context),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // v1.3.9: bonos por entrenador (solo dueño)
                if (esDueno) ...[
                  const SizedBox(height: 16),
                  Tarjeta(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Bonos del mes',
                          style: AppTexto.titulo,
                        ),
                        const SizedBox(height: 8),
                        if (_bonos.isEmpty)
                          Text(
                            'Sin bonos este mes.',
                            style: AppTexto.cuerpo.copyWith(
                              color: AppColores
                                  .textoSecundario(context),
                            ),
                          ),
                        for (final b in _bonos)
                          _buildFilaBono(context, b),
                        const Divider(height: 24),
                        Text(
                          'Agregar bono',
                          style: AppTexto.cuerpo
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        // Selector de entrenador
                        DropdownButtonFormField<String>(
                          value: _bonoEntrenador,
                          decoration: const InputDecoration(
                            labelText: 'Para',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                                value: 'ambos',
                                child: Text('Ambos')),
                            DropdownMenuItem(
                                value: 'duany',
                                child: Text('Duany')),
                            DropdownMenuItem(
                                value: 'gabriel',
                                child: Text('Gabriel')),
                          ],
                          onChanged: (v) => setState(
                              () => _bonoEntrenador =
                                  v ?? 'ambos'),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              // N1 (estéticas 1.19): campo del
                              // sistema; el 'CUP' va en el hint
                              // (CampoTexto no tiene afijos).
                              child: CampoTexto(
                                controller:
                                    _bonoMontoCtrl,
                                teclado: const TextInputType
                                    .numberWithOptions(
                                        decimal: true,
                                        signed: true),
                                hint: 'Monto en CUP '
                                    '(Ej: 2000 o -500)',
                                icono: Icons.payments_rounded,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        CampoTexto(
                          controller: _bonoNotaCtrl,
                          hint: 'Nota: por qué se otorga...',
                          icono: Icons.note_rounded,
                          maxLineas: 2,
                        ),
                        const SizedBox(height: 8),
                        BotonPrimario(
                          texto: 'Agregar bono',
                          icono: Icons.add_rounded,
                          onPressed: _agregarBono,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Tarifa por cliente (movido desde Administración)
                  Tarjeta(
                    padding: const EdgeInsets.all(AppEspacio.lg),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Tarifa por cliente',
                          style: AppTexto.cuerpo
                              .copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                'CUP por cada cliente que pagó:',
                                style: AppTexto.cuerpo,
                              ),
                            ),
                            SizedBox(
                              width: 100,
                              // N1 (estéticas 1.19): campo del
                              // sistema (la etiqueta vive en el
                              // texto de la fila).
                              child: CampoTexto(
                                controller:
                                    _tarifaCtrl,
                                teclado:
                                    TextInputType.number,
                              ),
                            ),
                            const SizedBox(width: 8),
                            BotonPrimario(
                              texto: 'Guardar',
                              onPressed: _guardarTarifa,
                              expandido: false,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }

  // ----------------------------------------------------------------
  // v1.8.0: Adelantos — sección por entrenador (lista del mes,
  // registrar/anular solo dueño, marcar nómina como pagada).
  // ----------------------------------------------------------------

  List<Widget> _buildSeccionesAdelantos(BuildContext context) {
    final esDueno = AuthService().isOwner;
    final yo = AuthService().username;
    final claves = esDueno
        ? ['duany', 'gabriel']
        : [
            if (yo == 'duany' || yo == 'gabriel') yo,
          ];
    return [
      for (final ent in claves)
        if (_personasAdelantos.containsKey(ent))
          _seccionAdelantos(context, ent),
    ];
  }

  /// T22 (1.20): línea de acuse de la nómina liquidada: si
  /// el entrenador ya confirmó (espejo), su fecha; si no,
  /// que sigue pendiente de su confirmación.
  Widget _lineaAcuseNomina(
      BuildContext context, String ent, String nombre) {
    final conf = _confirmacionMes[ent];
    final fechaConf = '${conf?['confirmada_en'] ?? ''}';
    if (conf != null && fechaConf.length >= 10) {
      return Padding(
        padding: const EdgeInsets.only(top: AppEspacio.xs),
        child: Text(
          '✓ $nombre confirmó que recibió su nómina el '
          '${fmtFecha(fechaConf.substring(0, 10))}.',
          style:
              AppTexto.cuerpo.copyWith(color: AppColores.exito),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.xs),
      child: Text(
        'Nómina liquidada · $nombre aún no confirma la '
        'recepción.',
        style: AppTexto.secundario,
      ),
    );
  }

  Widget _seccionAdelantos(BuildContext context, String ent) {
    final persona = _personasAdelantos[ent]!;
    final libro = _libroMes[ent];
    final pref = AdelantosService.mesActual();
    final items = (libro?.items ?? const [])
        .where((e) => '${e['mes_nomina']}' == pref)
        .toList();
    final todos = _eventosAdelantos[ent] ?? const [];
    final anulados = <int>{
      for (final e in todos)
        if (e['reverso_de'] != null)
          (e['reverso_de'] as num).toInt(),
    };
    final esDueno = AuthService().isOwner;
    final liquidada = _nominaLiquidadaMes[ent] ?? false;
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),
          Row(
            children: [
              Icon(Icons.payments_rounded,
                  size: 18, color: AppColores.textoSecundario(context)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Adelantos de ${persona.nombre}',
                    style: AppTexto.subtitulo),
              ),
              if (esDueno)
                TextButton.icon(
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Registrar'),
                  onPressed: () =>
                      _dialogoRegistrarAdelanto(context, ent),
                ),
            ],
          ),
          if (items.isEmpty)
            // 1.28 (M3-C6): el vacío con su salida al lado
            // (registrar el primer adelanto sin subir a la
            // cabecera de la sección).
            Row(
              children: [
                const Text('Sin adelantos este mes.',
                    style: AppTexto.cuerpo),
                if (esDueno && !liquidada)
                  TextButton(
                    onPressed: () =>
                        _dialogoRegistrarAdelanto(context, ent),
                    child: const Text('Registrar adelanto'),
                  ),
              ],
            )
          else
            for (final e in items)
              _filaAdelanto(context, e, anulados, esDueno,
                  liquidada: liquidada,
                  entrenadorId: persona.id,
                  mesNomina: pref),
          if (libro != null && libro.deudaSaliente > 0)
            Padding(
              padding: const EdgeInsets.only(top: AppEspacio.xs),
              child: Text(
                'Queda una deuda de ${fmtMonto(libro.deudaSaliente)} '
                'CUP para el mes que viene.',
                style: AppTexto.metadato.copyWith(color: AppColores.error),
              ),
            ),
          // T22 (1.20): acuse del entrenador (solo lectura
          // para el dueño; el entrenador confirma en su
          // pantalla «Mi nómina»).
          if (liquidada) _lineaAcuseNomina(context, ent, persona.nombre),
          if (esDueno && !liquidada)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.fact_check_rounded, size: 18),
                label: const Text('Marcar nómina del mes como pagada'),
                onPressed: () async {
                  // N-7 (1.22): guarda anti-doble toque en la
                  // liquidación (un doble toque encolaba dos
                  // liquidaciones del mismo mes).
                  if (_operando) return;
                  _operando = true;
                  try {
                    // T22 (1.20): el resumen se calcula ANTES
                    // del diálogo: lo que el dueño ve al
                    // confirmar es exactamente la foto que
                    // viaja con la liquidación.
                    final libroLiq = _libroMes[ent];
                    final baseLiq = _clientesPagados * _tarifa;
                    final bonoLiq = ent == 'mi'
                        ? _bonoSoloAmbos()
                        : _bonoPara(ent);
                    final comisionLiq =
                        _comisionDosis[ent]?.total ?? 0;
                    final adelantosLiq = libroLiq?.adelantos ?? 0;
                    final deudaLiq = libroLiq?.deudaEntrante ?? 0;
                    final netoLiq = NominaCalc.totalVivo(
                      base: baseLiq,
                      bono: bonoLiq,
                      comision: comisionLiq,
                      adelantos: adelantosLiq,
                      deudaEntrante: deudaLiq,
                    );
                    if (!context.mounted) return;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('¿Nómina pagada?'),
                        content: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Resumen de ${persona.nombre}:',
                                style: AppTexto.subtitulo),
                            const SizedBox(height: AppEspacio.sm),
                            Text('Clientes que pagaron: '
                                '$_clientesPagados × '
                                '${fmtMonto(_tarifa)} CUP'),
                            Text('Base: ${fmtMonto(baseLiq)} CUP'),
                            if (bonoLiq > 0)
                              Text('Bono: ${fmtMonto(bonoLiq)} CUP'),
                            if (comisionLiq > 0)
                              Text('Comisión por dosis: '
                                  '${fmtMonto(comisionLiq)} CUP'),
                            if (adelantosLiq > 0)
                              Text('Adelantos: '
                                  '−${fmtMonto(adelantosLiq)} CUP'),
                            if (deudaLiq > 0)
                              Text('Deuda del mes anterior: '
                                  '−${fmtMonto(deudaLiq)} CUP'),
                            const Divider(),
                            Text('Neto a pagar: '
                                '${fmtMonto(netoLiq)} CUP',
                                style: AppTexto.subtitulo),
                            const SizedBox(height: AppEspacio.sm),
                            const Text(
                                'Se marca la nómina de este mes '
                                'como PAGADA. Desde ese momento, '
                                'los adelantos que se registren '
                                'con fecha de este mes caerán en '
                                'la nómina del mes siguiente (el '
                                'mes pagado no se reescribe). El '
                                'entrenador verá este resumen y '
                                'podrá confirmar que la recibió.'),
                          ],
                        ),
                        actions: [
                          TextButton(
                            onPressed: () =>
                                Navigator.of(ctx).pop(false),
                            child: const Text('Cancelar'),
                          ),
                          FilledButton(
                            onPressed: () =>
                                Navigator.of(ctx).pop(true),
                            child: const Text('Sí, pagada'),
                          ),
                        ],
                      ),
                    );
                    if (ok != true) return;
                    // 1.28 (M3-A4): lo que se LIQUIDA se
                    // recalcula FRESCO tras el «Sí, pagada». El
                    // diálogo mostró la foto de pantalla (es lo
                    // que el dueño leyó), pero entre la carga
                    // de la pantalla y la confirmación pudo
                    // entrar un sync, un adelanto o un bono: la
                    // liquidación congelaba entonces una foto
                    // VIEJA como si fuera la del momento de
                    // pagar. Se rearma desde la foto compartida
                    // (con su guardia de huella) + el conteo
                    // asegurado del precálculo + los bonos por
                    // el camino con migración. Si la persona ya
                    // no está en la foto fresca, no se liquida
                    // nada y se avisa: jamás liquidar a ciegas.
                    final fotoF = await fotoNominaMes(pref);
                    final personaF = fotoF.personas[ent];
                    final libroF = fotoF.libroMes[ent];
                    if (personaF == null) {
                      if (mounted) {
                        mostrarSnack(context,
                            'No se pudo recalcular la nómina '
                            'de ${persona.nombre}: inténtalo de nuevo',
                            significado: SignificadoChip.error);
                      }
                      return;
                    }
                    final pagaronF =
                        await NominaPrecalc.instance.asegurar(pref);
                    final bonosF =
                        await leerBonosMesConMigracion(pref);
                    final bonoF = ent == 'mi'
                        ? NominaCalc.bonoSoloAmbos(bonosF)
                        : NominaCalc.bonosPara(bonosF, ent);
                    final comisionF =
                        fotoF.comisionDosis[ent]?.total ?? 0;
                    final baseF =
                        pagaronF * fotoF.tarifa.toDouble();
                    final adelantosF = libroF?.adelantos ?? 0;
                    final deudaF = libroF?.deudaEntrante ?? 0;
                    final netoF = NominaCalc.totalVivo(
                      base: baseF,
                      bono: bonoF,
                      comision: comisionF,
                      adelantos: adelantosF,
                      deudaEntrante: deudaF,
                    );
                    await AdelantosService.instance.liquidarNomina(
                      mes: pref,
                      entrenadorId: personaF.id,
                      entrenadorNombre: personaF.nombre,
                      entrenadorTelegramId: personaF.telegramId,
                      tarifaPorCliente: fotoF.tarifa.toDouble(),
                      neto: netoF,
                      base: baseF,
                      bonos: bonoF,
                      comisiones: comisionF,
                      adelantos: adelantosF,
                      deudaEntrante: deudaF,
                    );
                    if (mounted) {
                      // 1.28 (M3-B1): el resumen LISTO PARA
                      // ENVIAR, armado con las cifras FRESCAS
                      // que se acaban de liquidar (las mismas
                      // que entraron en liquidarNomina): el
                      // dueño lo comparte al entrenador sin
                      // reescribir ni una cifra. La deuda
                      // saliente se deriva de esas mismas
                      // cifras (el exceso de adelantos + deuda
                      // sobre el bruto, la semántica del libro).
                      final brutoF = baseF + bonoF + comisionF;
                      final deudaSalienteF =
                          (adelantosF + deudaF) > brutoF
                              ? (adelantosF + deudaF) - brutoF
                              : 0.0;
                      final textoResumen = textoResumenNominaWhatsApp(
                        nombre: personaF.nombre,
                        mesEtiqueta:
                            '${_nombreMes(int.parse(pref.substring(5, 7)))} '
                            'de ${pref.substring(0, 4)}',
                        clientesPagados: pagaronF,
                        tarifa: fotoF.tarifa.toDouble(),
                        base: baseF,
                        bono: bonoF,
                        comision: comisionF,
                        adelantos: adelantosF,
                        deudaEntrante: deudaF,
                        deudaSaliente: deudaSalienteF,
                        neto: netoF,
                      );
                      await showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Nómina pagada ✓'),
                          content: SingleChildScrollView(
                            child: SelectableText(textoResumen),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.of(ctx).pop(),
                              child: const Text('Cerrar'),
                            ),
                            FilledButton.icon(
                              icon: const Icon(Icons.share_rounded,
                                  size: 18),
                              label: const Text('Compartir resumen'),
                              onPressed: () =>
                                  Share.share(textoResumen),
                            ),
                          ],
                        ),
                      );
                      if (mounted) _cargar();
                    }
                  } finally {
                    _operando = false;
                  }
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _filaAdelanto(BuildContext context, Map<String, dynamic> e,
      Set<int> anulados, bool esDueno,
      {bool liquidada = false,
      String? entrenadorId,
      String? mesNomina}) {
    final id = (e['id'] as num?)?.toInt();
    final esReverso = e['reverso_de'] != null;
    final estaAnulado = id != null && anulados.contains(id);
    final pendiente = e['pendiente'] == 1;
    final anulacionPendiente = e['anulacion_pendiente'] == 1;
    final correccionPendiente =
        e['origen_corregido_pendiente'] == 1;
    final monto = (e['monto'] as num?)?.toDouble() ?? 0;
    final origen = '${e['origen'] ?? ''}' == 'fondo_dueno'
        ? 'del bolsillo de Jc'
        : 'de la caja del turno';
    final metodo = '${e['metodo'] ?? 'efectivo'}';
    final nota = '${e['nota'] ?? ''}';
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 86,
            child: Text('${e['fecha'] ?? ''}',
                style: AppTexto.metadato),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  esReverso
                      ? 'Anulación de adelanto'
                      : 'Adelanto ($metodo, $origen)',
                  style: AppTexto.secundario.copyWith(
                    decoration: estaAnulado
                        ? TextDecoration.lineThrough
                        : null,
                  ),
                ),
                if (nota.isNotEmpty)
                  Text(nota,
                      style: AppTexto.metadato),
                if (estaAnulado)
                  Text('anulado',
                      style: AppTexto.metadato.copyWith(color: AppColores.error)),
                if (anulacionPendiente)
                  const Text('anulación en curso…',
                      style: AppTexto.metadato),
                if (correccionPendiente)
                  const Text('corrección de origen en curso…',
                      style: AppTexto.metadato),
                if (pendiente)
                  const Text('pendiente de sincronizar',
                      style: AppTexto.metadato),
              ],
            ),
          ),
          Text(
            '${monto >= 0 ? '' : '+'}${fmtMonto(monto.abs())} CUP',
            style: AppTexto.secundario.copyWith(color: esReverso ? AppColores.exito : AppColores.error, fontWeight: FontWeight.w700),
          ),
          if (esDueno &&
              !liquidada &&
              !esReverso &&
              !estaAnulado &&
              !anulacionPendiente &&
              id != null)
            IconButton(
              icon: const Icon(Icons.undo_rounded, size: 18),
              tooltip: 'Anular adelanto',
              onPressed: () async {
                // N-7 (1.22): guarda anti-doble toque.
                if (_operando) return;
                _operando = true;
                try {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('¿Anular este adelanto?'),
                      content: const Text(
                          'Se crea el apunte contrario (nunca se '
                          'borra). Si la caja de ese día ya se '
                          'liquidó, la anulación queda marcada como '
                          'fuera de cierre y no toca arqueos '
                          'cerrados.'),
                      actions: [
                        TextButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(false),
                          child: const Text('Cancelar'),
                        ),
                        FilledButton(
                          onPressed: () =>
                              Navigator.of(ctx).pop(true),
                          child: const Text('Anular'),
                        ),
                      ],
                    ),
                  );
                  if (ok != true) return;
                  try {
                    await AdelantosService.instance.anular(id,
                        entrenadorId: entrenadorId,
                        mesNomina: mesNomina);
                  } catch (err) {
                    // M1: mes liquidado (u otro rechazo): se avisa
                    // y no se recarga como si hubiera funcionado.
                    if (mounted) {
                      mostrarSnack(context, '$err', significado: SignificadoChip.error);
                    }
                    return;
                  }
                  if (mounted) _cargar();
                } finally {
                  _operando = false;
                }
              },
            ),
          // W3 (1.20): corregir el origen (solo dueño, mes sin
          // liquidar; mismas guardas que anular). Sin sentido
          // si ya es fondo_dueno por transferencia: no hay a
          // dónde moverlo.
          if (esDueno &&
              !liquidada &&
              !esReverso &&
              !estaAnulado &&
              !anulacionPendiente &&
              !correccionPendiente &&
              id != null &&
              ('${e['origen'] ?? 'caja_turno'}' == 'caja_turno' ||
                  metodo == 'efectivo'))
            IconButton(
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              tooltip: 'Corregir origen',
              onPressed: () => _dialogoCorregirOrigen(context, e,
                  entrenadorId: entrenadorId, mesNomina: mesNomina),
            ),
        ],
      ),
    );
  }

  /// W3 (1.20): diálogo de corrección de origen de un adelanto.
  /// Explica el efecto en simple por dirección; la op la
  /// valida el servidor (guarda de mes liquidado incluida).
  ///
  /// Autoauditoría 1.22 #1 (2026-11-03): era la única acción
  /// de dinero de la pantalla sin la guarda _operando de N-7:
  /// un doble toque abría dos diálogos y podía encolar dos
  /// correcciones del mismo adelanto. La guarda vive en este
  /// envoltorio; el cuerpo no cambia.
  Future<void> _dialogoCorregirOrigen(
      BuildContext context, Map<String, dynamic> e,
      {String? entrenadorId, String? mesNomina}) async {
    if (_operando) return;
    _operando = true;
    try {
      await _dialogoCorregirOrigenReal(context, e,
          entrenadorId: entrenadorId, mesNomina: mesNomina);
    } finally {
      _operando = false;
    }
  }

  Future<void> _dialogoCorregirOrigenReal(
      BuildContext context, Map<String, dynamic> e,
      {String? entrenadorId, String? mesNomina}) async {
    final id = (e['id'] as num?)?.toInt();
    if (id == null) return;
    final origenActual = '${e['origen'] ?? 'caja_turno'}';
    final metodo = '${e['metodo'] ?? 'efectivo'}';
    var destino =
        origenActual == 'caja_turno' ? 'fondo_dueno' : 'caja_turno';
    // (M2-A A4) UNA sola foto de personas para todo el flujo:
    // _personasAdelantos puede recargarse con el diálogo
    // abierto y leer nombre/gaveta de dos fotos distintas
    // mezclaba el payload.
    final fotoPersonas = _personasAdelantos;
    // Gaveta inicial: la actual si se reconoce; si no, la del
    // propio adelanto.
    final gavetaActual = LocalDb.normalizarTelegramId(e['descuenta_a']);
    var gaveta = entrenadorId ?? 'duany';
    for (final entry in fotoPersonas.entries) {
      if (entry.value.telegramId != null &&
          entry.value.telegramId == gavetaActual) {
        gaveta = entry.key;
        break;
      }
    }
    final nombreEntrenador =
        fotoPersonas[entrenadorId]?.nombre ?? 'el entrenador';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Corregir origen del adelanto'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                origenActual == 'caja_turno'
                    ? 'Hoy este adelanto cuenta como que salió de '
                        'la caja del turno (está en el «pendiente '
                        'a entregar» de un entrenador).'
                    : 'Hoy este adelanto cuenta como que salió de '
                        'tu bolsillo (no está en el «pendiente a '
                        'entregar» de nadie).',
                style: AppTexto.secundario,
              ),
              const SizedBox(height: 12),
              Text('¿De dónde salió en realidad?',
                  style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Mi bolsillo'),
                    selected: destino == 'fondo_dueno',
                    onSelected: (_) =>
                        setLocal(() => destino = 'fondo_dueno'),
                  ),
                  if (metodo == 'efectivo')
                    ChoiceChip(
                      label: const Text('Caja del turno'),
                      selected: destino == 'caja_turno',
                      onSelected: (_) =>
                          setLocal(() => destino = 'caja_turno'),
                    ),
                ],
              ),
              if (destino == 'caja_turno') ...[
                const SizedBox(height: 8),
                const Text('Sale de la gaveta de:',
                    style: AppTexto.metadato),
                DropdownButton<String>(
                  value: fotoPersonas.containsKey(gaveta)
                      ? gaveta
                      : (fotoPersonas.keys.isNotEmpty
                          ? fotoPersonas.keys.first
                          : gaveta),
                  isExpanded: true,
                  items: [
                    for (final entry in fotoPersonas.entries)
                      DropdownMenuItem(
                          value: entry.key,
                          child: Text(entry.value.nombre)),
                  ],
                  onChanged: (v) =>
                      setLocal(() => gaveta = v ?? gaveta),
                ),
                Text(
                  'Pasará a contar en el «pendiente a entregar» '
                  'de ese entrenador y seguirá descontando de la '
                  'nómina de $nombreEntrenador.',
                  style: AppTexto.metadato,
                ),
              ] else
                Text(
                  'Dejará de contar como pendiente a entregar de '
                  'cualquier entrenador. Seguirá descontando de '
                  'la nómina de $nombreEntrenador.',
                  style: AppTexto.metadato,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Corregir'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await AdelantosService.instance.corregirOrigen(id,
          nuevoOrigen: destino,
          descuentaA: destino == 'caja_turno'
              ? fotoPersonas[gaveta]?.telegramId
              : null,
          entrenadorId: entrenadorId,
          mesNomina: mesNomina);
    } catch (err) {
      if (mounted) {
        mostrarSnack(context, '$err',
            significado: SignificadoChip.error);
      }
      return;
    }
    if (mounted) {
      mostrarSnack(context,
          'Origen corregido (se sincronizará)',
          significado: SignificadoChip.exito);
      _cargar();
    }
  }

  Future<void> _dialogoRegistrarAdelanto(
      BuildContext context, String ent) async {
    // Ronda 17 M4-H1: registrar adelantos es solo del dueño.
    if (!AuthService().isOwner) return;
    // N-7 (1.22): guarda anti-doble toque.
    if (_operando) return;
    _operando = true;
    try {
      // (M2-A A4) UNA sola foto de personas: persona y
      // gavetaPersona salen de la MISMA lectura (antes la
      // gaveta se re-leía tras el diálogo y una recarga
      // intermedia mezclaba dos fotos en el payload).
      final fotoPersonas = _personasAdelantos;
      final persona = fotoPersonas[ent]!;
      // 1.27: sin identificador sincronizado ni se abre
      // el diálogo — la op nacería con entrenador='' y
      // el servidor la rechazaría tras anunciar
      // «registrado» en falso (caso del puente
      // 2026-10-26). El servicio trae la misma guarda
      // como última palabra (registrar()).
      if (persona.id.trim().isEmpty) {
        mostrarSnack(context,
            'Aún no se sincronizó el identificador de '
            '${persona.nombre}: sincroniza y vuelve a '
            'intentarlo.',
            significado: SignificadoChip.alerta);
        return;
      }
      // 1.25 T118 (F2-23): el diálogo es un StatefulWidget
      // propio con DialogoApp (antes AlertDialog +
      // StatefulBuilder en línea); posee y dispone sus
      // controladores y devuelve los datos en un record. Las
      // gavetas salen de las personas conocidas de la foto
      // (antes 'duany'/'gabriel' escritos a mano: tercer
      // sitio de la misma lista, F2-14).
      final gavetas = <({String username, String nombre})>[
        for (final e in fotoPersonas.entries)
          (username: e.key, nombre: e.value.nombre),
      ];
      if (!gavetas.any((g) => g.username == ent)) {
        gavetas.add((username: ent, nombre: persona.nombre));
      }
      final datos = await showDialog<
          ({
            int monto,
            DateTime fecha,
            String nota,
            String metodo,
            String origen,
            String gaveta
          })>(
        context: context,
        builder: (ctx) => _DialogoRegistrarAdelanto(
          nombreEntrenador: persona.nombre,
          gavetaInicial: ent,
          gavetas: gavetas,
        ),
      );
      if (datos == null) return;
      final gavetaPersona = fotoPersonas[datos.gaveta];
      // 1.27: si el servicio corta el registro (sin id o
      // sin gaveta para el efectivo de caja), se muestra
      // SU motivo y jamás el «registrado» de éxito.
      try {
        await AdelantosService.instance.registrar(
          entrenadorId: persona.id,
          entrenadorNombre: persona.nombre,
          entrenadorTelegramId: persona.telegramId,
          monto: datos.monto,
          fecha: datos.fecha,
          nota: datos.nota,
          metodo: datos.metodo,
          origen: datos.origen,
          descuentaA: gavetaPersona?.telegramId,
        );
      } catch (err) {
        if (mounted) {
          mostrarSnack(
              context,
              err is StateError ? err.message : '$err',
              significado: SignificadoChip.error);
        }
        return;
      }
      if (mounted) {
        mostrarSnack(context, 'Adelanto registrado (se sincronizará)', significado: SignificadoChip.exito);
        _cargar();
      }
    } finally {
      _operando = false;
    }
  }
}

/// Tarjeta compacta para el Home del entrenador (v1.3.9 #8).
class TarjetaNominaEntrenador extends StatelessWidget {
  const TarjetaNominaEntrenador({super.key});

  @override
  Widget build(BuildContext context) {
    return Tarjeta(
      padding: const EdgeInsets.all(AppEspacio.lg),
      child: InkWell(
        onTap: () {
          // #1 (Argón nómina + decisión Jc): la tarjeta del
          // entrenador abre SU resumen (MiNominaScreen, con sus
          // bonos), no la pantalla del dueño.
          Navigator.push(
            context,
            RutaIron(
                builder: (_) => const MiNominaScreen()),
          );
        },
        child: Row(
          children: [
            IconoModuloBadge.naranja(
                Icons.payments_rounded),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Mi nómina (estimado)',
                style: AppTexto.cuerpo,
              ),
            ),
            const Icon(Icons.chevron_right_rounded),
          ],
        ),
      ),
    );
  }
}

/// 1.25 T118 (F2-23): diálogo «Registrar adelanto» como
/// StatefulWidget propio con DialogoApp: posee y dispone sus
/// controladores, la validación del monto va inline (B6) y la
/// fecha se muestra con fmtFecha. Devuelve los datos en un
/// record o null si se cancela.
class _DialogoRegistrarAdelanto extends StatefulWidget {
  final String nombreEntrenador;
  final String gavetaInicial;
  final List<({String username, String nombre})> gavetas;
  const _DialogoRegistrarAdelanto({
    required this.nombreEntrenador,
    required this.gavetaInicial,
    required this.gavetas,
  });

  @override
  State<_DialogoRegistrarAdelanto> createState() =>
      _DialogoRegistrarAdelantoState();
}

class _DialogoRegistrarAdelantoState
    extends State<_DialogoRegistrarAdelanto> {
  final _montoCtrl = TextEditingController();
  final _notaCtrl = TextEditingController();
  late DateTime _fecha = ahoraHabana();
  String _metodo = 'efectivo';
  String _origen = 'caja_turno';
  late String _gaveta = widget.gavetaInicial;
  String? _errorMonto;

  @override
  void dispose() {
    _montoCtrl.dispose();
    _notaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DialogoApp(
      titulo: 'Adelanto a ${widget.nombreEntrenador}',
      iconoTitulo: Icons.payments_rounded,
      contenido: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _montoCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                  labelText: 'Monto (CUP entero)'),
            ),
            if (_errorMonto != null) ...[
              const SizedBox(height: 8),
              ErrorInline(_errorMonto!),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Fecha: '),
                TextButton(
                  onPressed: () async {
                    final f = await showDatePicker(
                      context: context,
                      initialDate: _fecha,
                      firstDate: DateTime(_fecha.year - 1, 1, 1),
                      lastDate: ahoraHabana(),
                    );
                    if (f != null) {
                      setState(() => _fecha = f);
                    }
                  },
                  child: Text(fmtFecha(_fecha.toIso8601String())),
                ),
              ],
            ),
            Text('Método',
                style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Efectivo'),
                  selected: _metodo == 'efectivo',
                  onSelected: (_) =>
                      setState(() => _metodo = 'efectivo'),
                ),
                ChoiceChip(
                  label: const Text('Transferencia'),
                  selected: _metodo == 'transferencia',
                  onSelected: (_) =>
                      setState(() => _metodo = 'transferencia'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text('¿De dónde sale?',
                style: AppTexto.metadato.copyWith(fontWeight: FontWeight.w700)),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Caja del turno'),
                  selected: _origen == 'caja_turno',
                  onSelected: (_) =>
                      setState(() => _origen = 'caja_turno'),
                ),
                ChoiceChip(
                  label: const Text('Mi bolsillo'),
                  selected: _origen == 'fondo_dueno',
                  onSelected: (_) =>
                      setState(() => _origen = 'fondo_dueno'),
                ),
              ],
            ),
            if (_origen == 'caja_turno' && _metodo == 'efectivo') ...[
              const SizedBox(height: 8),
              const Text('Sale de la gaveta de:',
                  style: AppTexto.metadato),
              DropdownButton<String>(
                value: _gaveta,
                isExpanded: true,
                items: [
                  for (final g in widget.gavetas)
                    DropdownMenuItem(
                        value: g.username, child: Text(g.nombre)),
                ],
                onChanged: (v) =>
                    setState(() => _gaveta = v ?? widget.gavetaInicial),
              ),
              const Text(
                'Ese dinero ya no estará en su «pendiente a '
                'entregar»: cuadra con su arqueo.',
                style: AppTexto.metadato,
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _notaCtrl,
              maxLength: 80,
              decoration: const InputDecoration(
                  labelText: 'Nota (opcional)'),
            ),
          ],
        ),
      ),
      acciones: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: () {
            final monto = int.tryParse(_montoCtrl.text.trim());
            if (monto == null || monto <= 0) {
              setState(() => _errorMonto =
                  'Monto inválido: entero mayor que 0');
              return;
            }
            Navigator.of(context).pop((
              monto: monto,
              fecha: _fecha,
              nota: _notaCtrl.text,
              metodo: _metodo,
              origen: _origen,
              gaveta: _gaveta,
            ));
          },
          child: const Text('Registrar'),
        ),
      ],
    );
  }
}
