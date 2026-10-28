/// Mi nómina (v1.12.0, Bloque 3 — Entrenadores B2–B5, C2, C3, C5,
/// F3, E3). Vista previa EN VIVO con NominaCalc (la misma definición
/// de «pagaron el mes» que la pantalla del dueño): nunca es el
/// cierre del mes, y el sello obligatorio lo dice en cabecera y en
/// el recibo exportable.
///
/// Offline: todo se lee de espejos locales; pedir un adelanto
/// encola la op (sube cuando haya red). Las solicitudes pendientes
/// NO entran en la matemática (solo los adelantos ya aprobados).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../adelantos.dart';
import '../auth.dart';
import '../bloque3.dart';
import '../cliente_protegido.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../nomina_calc.dart';
import '../perfil.dart';
import '../tiempo.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'servicios.dart';
import 'widgets.dart';

class MiNominaScreen extends StatefulWidget {
  const MiNominaScreen({super.key});
  @override
  State<MiNominaScreen> createState() => _MiNominaScreenState();
}

class _MiNominaScreenState extends State<MiNominaScreen> {
  bool _cargando = true;
  String _pref = '';
  int _clientesPagados = 0;
  int _tarifa = 150;
  int _dosis = 0;
  double _comision = 0;
  MesLibroAdelantos? _libro;
  List<Map<String, dynamic>> _eventos = [];
  List<SolicitudAdelanto> _solicitudes = [];
  List<Map<String, dynamic>> _ventas = [];
  Map<int, String> _nombresClientes = {};
  // Cliente protegido (2026-10-26, Protegido 2 H7): ids de
  // clientes protegidos, para ocultar su nombre en _textoVenta.
  Set<int> _protegidos = {};
  double? _horasSinSubir;
  String _syncTexto = '';
  bool _pidiendo = false;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// Id del usuario APK actual (meta usuarios_apk por telegram_id),
  /// la llave que usa `adelantos.entrenador`.
  Future<String> _miIdUsuarioApk() async {
    final tid = AuthService().telegramId;
    if (tid == null) return '';
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          if (LocalDb.normalizarTelegramId(m['telegram_id']) == tid) {
            return '${m['id'] ?? ''}';
          }
        }
      }
    } catch (_) {}
    return '';
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final pref = NominaCalc.prefMesActual();
    final tid = AuthService().telegramId;
    final clientesPagados = await NominaCalc.clientesQuePagaronElMes(pref);
    final tarifa = await PerfilService.instance.getPagoEntrenador();
    var dosis = 0;
    var comision = 0.0;
    List<Map<String, dynamic>> ventasServicio = [];
    if (tid != null) {
      ventasServicio =
          await LocalDb.instance.allMirror('servicio_ventas');
      final c = NominaCalc.comisionDosisDesdeVentas(
          ventasServicio, tid, pref);
      dosis = c.dosis;
      comision = c.total;
    }
    final miId = await _miIdUsuarioApk();
    final eventos = miId.isEmpty
        ? <Map<String, dynamic>>[]
        : await AdelantosService.instance
            .eventosDe(miId, telegramId: tid);
    MesLibroAdelantos? libro;
    try {
      // Argón lote 4 BLOQUEANTE (cadena histórica rota): pasar solo
      // el mes actual convertía todos los adelantos viejos en deuda
      // entrante falsa y hundía el neto a 0. Igual que la pantalla
      // del dueño (ui/nomina.dart): cadena desde el primer mes con
      // eventos, con bruto y comisiones de CADA mes.
      var primero = pref;
      for (final ev in eventos) {
        final mm = '${ev['mes_nomina'] ?? ''}';
        if (mm.length == 7 && mm.compareTo(primero) < 0) {
          primero = mm;
        }
      }
      final brutoPorMes = <String, double>{};
      var mesCadena = primero;
      while (mesCadena.compareTo(pref) <= 0) {
        final n =
            await NominaCalc.clientesQuePagaronElMes(mesCadena);
        brutoPorMes[mesCadena] = n * tarifa.toDouble();
        mesCadena = mesSiguiente(mesCadena);
      }
      final libros = libroAdelantos(
        eventos: eventos,
        brutoPorMes: brutoPorMes,
        // Terra lote-4 MEDIO (verificado NO-problema, se documenta):
        // con tid == null, _miIdUsuarioApk() devuelve '' y eventos
        // es [] por construcción, y comision es 0 en esa rama; el
        // libro sale trivialmente en ceros, sin deuda falsa. Si
        // algún día _miIdUsuarioApk dejara de exigir tid, esta rama
        // habría que revisarla: no se puede inventar comisión sin
        // identidad atribuible.
        comisionesPorMes: tid == null
            ? {pref: comision}
            : NominaCalc.comisionesPorMesDesdeVentas(
                ventasServicio, tid, primero, pref),
        hastaMes: pref,
      );
      for (final m in libros) {
        if (m.mes == pref) libro = m;
      }
    } catch (_) {}
    List<SolicitudAdelanto> solicitudes = [];
    try {
      solicitudes = await SolicitudesAdelantoService.instance.mias();
    } catch (_) {}
    // C5: mis ventas (suplementos por registrado_por; servicios por
    // vendedor_id o registrado_por). Sin vendedor registrado, la
    // fila no se atribuye: no se inventa.
    final ventas = <Map<String, dynamic>>[];
    if (tid != null) {
      for (final v
          in await LocalDb.instance.allMirror('ventas_suplementos')) {
        if (LocalDb.normalizarTelegramId(v['registrado_por']) == tid) {
          ventas.add({'origen': 'suplemento', ...v});
        }
      }
      for (final v in await LocalDb.instance.allMirror('servicio_ventas')) {
        final vend = LocalDb.normalizarTelegramId(v['vendedor_id']) ??
            LocalDb.normalizarTelegramId(v['registrado_por']);
        if (vend == tid) ventas.add({'origen': 'servicio', ...v});
      }
      ventas.sort((a, b) =>
          '${b['fecha'] ?? b['creada_en'] ?? ''}'
              .compareTo('${a['fecha'] ?? a['creada_en'] ?? ''}'));
    }
    final nombres = <int, String>{};
    final protegidos = <int>{};
    for (final c in await LocalDb.instance.allMirror('clientes')) {
      final id = (c['id'] as num?)?.toInt();
      if (id != null && '${c['nombre'] ?? ''}'.isNotEmpty) {
        nombres[id] = '${c['nombre']}';
        if (clienteEstaProtegido(c)) protegidos.add(id);
      }
    }
    double? horasSinSubir;
    try {
      final iso = await LocalDb.instance.isoOpPendienteMasAntigua();
      horasSinSubir = horasSinSubirDesde(iso, ahoraHabana());
    } catch (_) {}
    final syncTexto = await textoUltimaSyncNomina();
    if (!mounted) return;
    setState(() {
      _pref = pref;
      _clientesPagados = clientesPagados;
      _tarifa = tarifa;
      _dosis = dosis;
      _comision = comision;
      _libro = libro;
      _eventos = eventos;
      _solicitudes = solicitudes;
      _ventas = ventas;
      _nombresClientes = nombres;
      _protegidos = protegidos;
      _horasSinSubir = horasSinSubir;
      _syncTexto = syncTexto;
      _cargando = false;
    });
  }

  double get _base => _clientesPagados * _tarifa.toDouble();
  double get _adelantosMes => _libro?.adelantos ?? 0;
  double get _deudaEntrante => _libro?.deudaEntrante ?? 0;
  double get _neto {
    final n = _base + _comision - _adelantosMes - _deudaEntrante;
    return n < 0 ? 0 : n;
  }

  String get _recibo => textoReciboNomina(
        pref: _pref,
        clientesPagados: _clientesPagados,
        tarifa: _tarifa,
        dosis: _dosis,
        comision: _comision,
        adelantosMes: _adelantosMes,
        deudaEntrante: _deudaEntrante,
        sello: kSelloVistaPreviaNomina,
        syncTexto: _syncTexto,
      );

  Future<void> _copiarRecibo() async {
    await Clipboard.setData(ClipboardData(text: _recibo));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Recibo copiado al portapapeles.')));
  }

  Future<void> _pedirAdelanto() async {
    final montoCtrl = TextEditingController();
    final motivoCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Pedir adelanto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: montoCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Monto (CUP, pesos enteros)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            TextField(
              controller: motivoCtrl,
              decoration: const InputDecoration(
                labelText: 'Motivo',
                border: OutlineInputBorder(),
              ),
              maxLength: 120,
            ),
            const SizedBox(height: AppEspacio.sm),
            const Text(
              'La solicitud la decide el dueño. Mientras esté '
              'pendiente NO descuenta de tu nómina.',
              style: AppTexto.secundario,
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
            child: const Text('Enviar solicitud'),
          ),
        ],
      ),
    );
    // Argón lote 4 MEDIO: los controladores nunca hacían dispose.
    // El diálogo ya cerró: se captura el texto y se liberan en
    // ambos caminos (también al cancelar).
    final montoTexto = montoCtrl.text.trim();
    final motivoTexto = motivoCtrl.text.trim();
    montoCtrl.dispose();
    motivoCtrl.dispose();
    if (ok != true || !mounted) return;
    // La etiqueta pide pesos enteros: se parsea entero, no double.
    // Tope 100000 como guarda contra ceros de más (no es un límite
    // de negocio: un adelanto real no llega ahí).
    final monto = int.tryParse(montoTexto);
    if (monto == null || monto <= 0 || monto > 100000) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Escribe un monto entero mayor que 0 (máx. 100000).')));
      return;
    }
    setState(() => _pidiendo = true);
    try {
      await SolicitudesAdelantoService.instance
          .pedir(monto: monto.toDouble(), motivo: motivoTexto);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Solicitud enviada. El dueño la decidirá.')));
      await _cargar();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('No se pudo enviar: $e')));
    } finally {
      if (mounted) setState(() => _pidiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Mi nómina')),
      body: Column(
        children: [
          const SyncBanner(compact: true),
          Expanded(child: _cuerpo()),
        ],
      ),
    );
  }

  Widget _cuerpo() {
    if (_cargando) {
      return const Center(
          child: CircularProgressIndicator(color: AppColores.naranja));
    }
    return FadeEntrada(
      child: RefreshIndicator(
        onRefresh: _cargar,
        child: ListView(
          padding: const EdgeInsets.all(AppEspacio.lg),
          children: [
            // B3: sello obligatorio + frescura, en cabecera.
            Container(
              padding: const EdgeInsets.all(AppEspacio.md),
              decoration: BoxDecoration(
                color: AppColores.naranja.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    kSelloVistaPreviaNomina,
                    style: AppTexto.cuerpo.copyWith(
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(_syncTexto, style: AppTexto.secundario),
                  const SizedBox(height: 4),
                  const Text(
                    'Sin bonos: los gestiona el dueño y no entran '
                    'en esta vista previa.',
                    style: AppTexto.secundario,
                  ),
                ],
              ),
            ),
            // E3: aviso de horas sin subir (no bloquea nada).
            if (_horasSinSubir != null &&
                _horasSinSubir! >= kHorasAvisoSinSubir)
              Container(
                margin: const EdgeInsets.only(top: AppEspacio.md),
                padding: const EdgeInsets.all(AppEspacio.md),
                decoration: BoxDecoration(
                  color: AppColores.alerta.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '⚠ Llevas ${_horasSinSubir!.toStringAsFixed(0)} horas '
                  'sin subir operaciones. Abre la cola y toca '
                  '«Subir ahora» cuando tengas conexión.',
                  style: AppTexto.cuerpo.copyWith(
                      fontWeight: FontWeight.w600),
                ),
              ),
            const SizedBox(height: AppEspacio.md),
            // B2: base explicada.
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Cómo se calcula tu base',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: AppEspacio.sm),
                  Text(
                    textoBaseNominaExplicada(
                        _clientesPagados, _tarifa),
                    style: AppTexto.cuerpo,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            // B3: vista previa en vivo.
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Vista previa — mes $_pref',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: AppEspacio.sm),
                  _linea('Base', fmtMonto(_base)),
                  _linea('Comisión dosis',
                      '$_dosis dosis · ${fmtMonto(_comision)}'),
                  _linea(
                      'Adelantos del mes', '-${fmtMonto(_adelantosMes)}'),
                  _linea(
                      'Deuda arrastrada', '-${fmtMonto(_deudaEntrante)}'),
                  const Divider(),
                  _linea('NETO ESTIMADO', fmtMonto(_neto),
                      negrita: true),
                  const SizedBox(height: AppEspacio.sm),
                  const Text(
                    'El neto nunca baja de 0: si los adelantos '
                    'superan el bruto, el exceso queda como deuda '
                    'para el mes siguiente.',
                    style: AppTexto.secundario,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            // B4: mis adelantos + solicitudes (sin mezclar).
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Mis adelantos',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: AppEspacio.sm),
                  if (_eventos.isEmpty)
                    const Text('Sin adelantos registrados.',
                        style: AppTexto.secundario)
                  else
                    for (final e in _eventos)
                      Text(
                        '· ${fmtMonto((e['monto'] as num?)?.toDouble() ?? 0)} CUP'
                        ' · mes ${e['mes_nomina'] ?? ''}'
                        '${e['motivo'] != null && '${e['motivo']}'.isNotEmpty ? ' · ${e['motivo']}' : ''}'
                        '${_origenAdelanto(e)}',
                        style: AppTexto.cuerpo,
                      ),
                  const SizedBox(height: AppEspacio.sm),
                  const Text('Solicitudes pendientes (no descuentan)',
                      style: AppTexto.secundario),
                  if (_solicitudes
                      .where((s) => s.pendiente)
                      .isEmpty)
                    const Text('Ninguna solicitud pendiente.',
                        style: AppTexto.secundario)
                  else
                    for (final s in _solicitudes.where((s) => s.pendiente))
                      Text(
                        '· ${fmtMonto(s.monto)} CUP · ${s.motivo}'
                        '${s.creadoEn != null ? ' · ${s.creadoEn!.substring(0, 10)}' : ''}',
                        style: AppTexto.cuerpo,
                      ),
                  // v1.12.0 (F3 destino): solicitudes resueltas con
                  // su destino, cuando el dato llega del espejo.
                  if (_solicitudes
                      .where((s) => !s.pendiente)
                      .isNotEmpty) ...[
                    const SizedBox(height: AppEspacio.sm),
                    const Text('Solicitudes resueltas',
                        style: AppTexto.secundario),
                    for (final s in _solicitudes.where((s) => !s.pendiente))
                      Text(
                        '· ${fmtMonto(s.monto)} CUP · ${s.estado}'
                        '${s.destinoEtiqueta != null ? ' · destino: ${s.destinoEtiqueta}' : ''}'
                        '${s.estado == 'rechazado' && (s.motivoResolucion ?? '').isNotEmpty ? ' · «${s.motivoResolucion}»' : ''}',
                        style: AppTexto.cuerpo,
                      ),
                  ],
                  const SizedBox(height: AppEspacio.md),
                  BotonPrimario(
                    texto: 'Pedir adelanto',
                    icono: Icons.request_page_rounded,
                    onPressed: _pidiendo ? null : _pedirAdelanto,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            // B5: recibo exportable (mismo sello dentro).
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Recibo', style: AppTexto.subtitulo),
                  const SizedBox(height: AppEspacio.sm),
                  const Text(
                    'El recibo lleva el mismo sello de vista previa '
                    'y la fecha de la última sincronización.',
                    style: AppTexto.secundario,
                  ),
                  const SizedBox(height: AppEspacio.sm),
                  BotonSecundario(
                    texto: 'Copiar recibo',
                    icono: Icons.copy_rounded,
                    onPressed: _copiarRecibo,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            // C3: venta rápida de dosis (mismo flujo).
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Venta rápida de dosis',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: AppEspacio.sm),
                  Wrap(
                    spacing: AppEspacio.sm,
                    children: [
                      FilledButton.icon(
                        icon: const Icon(Icons.local_drink_rounded,
                            size: 18),
                        label: const Text('Dosis sin agua'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ServiciosScreen(
                                tipoInicial: 'dosis_sin_agua'),
                          ),
                        ),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.water_drop_rounded,
                            size: 18),
                        label: const Text('Dosis con agua'),
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const ServiciosScreen(
                                tipoInicial: 'dosis_con_agua'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppEspacio.md),
            // C5: historial de mis ventas.
            Tarjeta(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Mis ventas', style: AppTexto.subtitulo),
                  const SizedBox(height: AppEspacio.sm),
                  if (_ventas.isEmpty)
                    const Text(
                      'Sin ventas registradas a tu nombre en este '
                      'teléfono.',
                      style: AppTexto.secundario,
                    )
                  else
                    for (final v in _ventas.take(50))
                      Text(
                        _textoVenta(v),
                        style: AppTexto.cuerpo,
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Origen del adelanto en palabras claras, solo cuando el
  /// espejo lo trae (filas viejas no lo tienen: no se inventa).
  String _origenAdelanto(Map<String, dynamic> e) {
    return switch ('${e['origen'] ?? ''}') {
      'fondo_dueno' => ' · nómina',
      'caja_turno' => ' · pendiente a entregar',
      _ => '',
    };
  }

  String _textoVenta(Map<String, dynamic> v) {    final fecha = '${v['fecha'] ?? v['creada_en'] ?? ''}';
    final fechaCorta = fecha.length >= 10 ? fecha.substring(0, 10) : fecha;
    final cid = (v['cliente_id'] as num?)?.toInt();
    // Cliente protegido (2026-10-26, Protegido 2 H7): el nombre se
    // oculta, pero el monto se queda para cuadrar la comisión.
    final cliente = cid != null && _protegidos.contains(cid)
        ? 'Cliente protegido 🔒'
        : (cid != null
            ? (_nombresClientes[cid] ?? 'Cliente #$cid')
            : ('${v['cliente_nombre'] ?? ''}'));
    final tipo = v['origen'] == 'suplemento'
        ? 'suplemento'
        : ('${v['tipo'] ?? 'servicio'}');
    final monto = v['monto'] ?? v['precio'] ?? v['total'];
    final montoTxt =
        monto != null ? ' · ${fmtMonto(monto)} CUP' : '';
    return '· $fechaCorta · $cliente · $tipo$montoTxt';
  }

  Widget _linea(String etiqueta, String valor, {bool negrita = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(etiqueta, style: AppTexto.cuerpo)),
          Text(
            valor,
            style: AppTexto.cuerpo.copyWith(
                fontWeight:
                    negrita ? FontWeight.w700 : FontWeight.w400),
          ),
        ],
      ),
    );
  }
}

/// Texto del recibo de nómina del entrenador (1.14, M5.2): el
/// mismo que la pantalla copiaba al portapapeles, con su sello de
/// vista previa y la línea de última sync. El neto nunca es
/// negativo (el exceso queda como deuda en el libro).
String textoReciboNomina({
  required String pref,
  required int clientesPagados,
  required int tarifa,
  required int dosis,
  required double comision,
  required double adelantosMes,
  required double deudaEntrante,
  required String sello,
  required String syncTexto,
}) {
  final base = clientesPagados * tarifa.toDouble();
  var neto = base + comision - adelantosMes - deudaEntrante;
  if (neto < 0) neto = 0;
  final b = StringBuffer();
  b.writeln(sello);
  b.writeln(syncTexto);
  b.writeln('Mes: $pref');
  b.writeln(
      'Base: $clientesPagados clientes × $tarifa = ${fmtMonto(base)} CUP');
  b.writeln('Comisión dosis: $dosis dosis = ${fmtMonto(comision)} CUP');
  b.writeln('Adelantos del mes: -${fmtMonto(adelantosMes)} CUP');
  b.writeln('Deuda arrastrada: -${fmtMonto(deudaEntrante)} CUP');
  b.writeln('NETO ESTIMADO: ${fmtMonto(neto)} CUP');
  b.writeln(
      'Sin bonos (los gestiona el dueño). El pago se hace el último día del mes.');
  return b.toString();
}
