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
import '../nomina_bonos.dart';
import '../nomina_calc.dart';
import '../nomina_precalc.dart';
import '../perfil.dart';
import '../permisos_entrenador.dart';
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
  // #1 (Argón nómina + decisión Jc): el entrenador SÍ ve sus
  // bonos en su resumen (antes el recibo decía "Sin bonos").
  double _bonosMes = 0;
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
  // T22 (1.20): liquidaciones mías pendientes de confirmar
  // (cada una: mes + foto con desglose si ya bajó) y la
  // última confirmación hecha, para el acuse visible.
  String _miId = '';
  List<Map<String, dynamic>> _porConfirmar = [];
  Map<String, dynamic>? _ultimaConfirmada;
  bool _confirmando = false;

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

  /// Username del entrenador actual (meta usuarios_apk por
  /// telegram_id), o '' si no se resuelve. Es la llave de bonos.
  Future<String> _miUsername() async {
    final tid = AuthService().telegramId;
    if (tid == null) return '';
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          if (LocalDb.normalizarTelegramId(m['telegram_id']) == tid) {
            return '${m['username'] ?? ''}';
          }
        }
      }
    } catch (_) {}
    return '';
  }

  /// Mi clave de entrenador con el MISMO fallback que
  /// NominaScreen y nomina_total: clave del username y, si no
  /// resuelve, clave del nombre (N-4, 1.22: con solo el
  /// username, un entrenador cuyo username no contiene su
  /// nombre veía bonos 0 y deuda falsa en su libro).
  Future<String?> _miClave() async {
    final tid = AuthService().telegramId;
    if (tid == null) return null;
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          if (LocalDb.normalizarTelegramId(m['telegram_id']) == tid) {
            return NominaCalc.claveEntrenador('${m['username'] ?? ''}') ??
                NominaCalc.claveEntrenador('${m['nombre'] ?? ''}');
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Autoauditoría 1.22 #1: TODOS los telegram_id de usuarios_apk
  /// que resuelven a MI clave (el histórico y el actual si el
  /// entrenador cambió de cuenta): las comisiones por mes del
  /// libro deben sumar ambos, como hace el dueño con N-3.
  Future<List<int>> _misTids() async {
    final clave = await _miClave();
    if (clave == null) return const [];
    final out = <int>{};
    try {
      final raw = await LocalDb.instance.getMeta('usuarios_apk');
      if (raw != null && raw.isNotEmpty) {
        for (final u in jsonDecode(raw) as List) {
          final m = Map<String, dynamic>.from(u as Map);
          final c = NominaCalc.claveEntrenador('${m['username'] ?? ''}') ??
              NominaCalc.claveEntrenador('${m['nombre'] ?? ''}');
          final t = LocalDb.normalizarTelegramId(m['telegram_id']);
          if (c == clave && t != null) out.add(t);
        }
      }
    } catch (_) {}
    return out.toList();
  }

  /// Bonos por mes del entrenador actual (llave única), o mapa
  /// vacío si no se resuelve su identidad (sin identidad no se
  /// puede atribuir bono: no se inventa).
  Future<Map<String, double>> _bonosPorMes(
      String desde, String hasta) async {
    final clave = await _miClave();
    if (clave == null) return const {};
    return BonosNominaService.instance.bonosPorMes(clave, desde, hasta);
  }

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final pref = NominaCalc.prefMesActual();
    // #6 (Argón nómina): refrescar el pre-cálculo antes de
    // componer (igual que la pantalla del dueño).
    await NominaPrecalc.instance.asegurar(pref);
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
      final conteoPorMes = <String, int>{};
      var mesCadena = primero;
      while (mesCadena.compareTo(pref) <= 0) {
        final n =
            await NominaCalc.clientesQuePagaronElMes(mesCadena);
        conteoPorMes[mesCadena] = n;
        brutoPorMes[mesCadena] = n * tarifa.toDouble();
        mesCadena = mesSiguiente(mesCadena);
      }
      // Terra lote-4 MEDIO (verificado NO-problema, se documenta):
      // con tid == null, _miIdUsuarioApk() devuelve '' y eventos
      // es [] por construcción, y comision es 0 en esa rama; el
      // libro sale trivialmente en ceros, sin deuda falsa. Si
      // algún día _miIdUsuarioApk dejara de exigir tid, esta rama
      // habría que revisarla: no se puede inventar comisión sin
      // identidad atribuible.
      // Autoauditoría 1.22 #1: por mes se suman TODOS mis tid
      // (histórico + actual), no solo el de la sesión.
      final misTids = tid == null ? const <int>[] : await _misTids();
      final comisionesPorMes = tid == null
          ? {pref: comision}
          : NominaCalc.comisionesPorMesDesdeVentasMulti(
              ventasServicio,
              misTids.isNotEmpty ? misTids : [tid],
              primero,
              pref);
      // #2 (Argón nómina): los bonos suman a la capacidad del
      // mes (misma regla que la pantalla del dueño).
      final bonosPorMes = await _bonosPorMes(primero, pref);
      // N-5 (1.22): los meses ya liquidados mandan por su foto,
      // no por la tarifa viva (ver aplicarFotosLibro).
      await AdelantosService.instance.aplicarFotosLibro(
        brutoPorMes: brutoPorMes,
        comisionesPorMes: comisionesPorMes,
        bonosPorMes: bonosPorMes,
        conteoPorMes: conteoPorMes,
        entrenadorId: miId,
        telegramId: tid,
      );
      final libros = libroAdelantos(
        eventos: eventos,
        brutoPorMes: brutoPorMes,
        comisionesPorMes: comisionesPorMes,
        bonosPorMes: bonosPorMes,
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
    // T22 (1.20): mis liquidaciones y su acuse. Una
    // liquidación es mía si su telegram_id es el mío o su
    // entrenador es mi id/usuario APK.
    var porConfirmar = <Map<String, dynamic>>[];
    Map<String, dynamic>? ultimaConfirmada;
    try {
      final miUser = await _miUsername();
      final svc = AdelantosService.instance;
      final liquidadas =
          await LocalDb.instance.allMirror('nomina_liquidada');
      final mias = liquidadas
          .where((l) =>
              (tid != null &&
                  LocalDb.normalizarTelegramId(
                          l['entrenador_telegram_id']) ==
                      tid) ||
              (miId.isNotEmpty && '${l['entrenador']}' == miId) ||
              (miUser.isNotEmpty &&
                  '${l['entrenador']}' == miUser))
          .toList()
        ..sort((a, b) => '${b['mes']}'.compareTo('${a['mes']}'));
      for (final l in mias) {
        final mesL = '${l['mes']}';
        if (mesL.length != 7) continue;
        final conf = await svc.confirmacionNomina(mesL,
            entrenadorId: miId, telegramId: tid);
        if (conf == null) {
          final snap = await svc.snapshotNomina(mesL,
              entrenadorId: miId, telegramId: tid);
          porConfirmar.add({'mes': mesL, 'snapshot': snap});
        } else if (ultimaConfirmada == null &&
            conf['confirmada_en'] != null) {
          ultimaConfirmada = {
            'mes': mesL,
            'confirmada_en': conf['confirmada_en'],
          };
        }
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _miId = miId;
      _porConfirmar = porConfirmar;
      _ultimaConfirmada = ultimaConfirmada;
      _pref = pref;
      _clientesPagados = clientesPagados;
      _tarifa = tarifa;
      _dosis = dosis;
      _comision = comision;
      _bonosMes = libro?.bonos ?? 0;
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
    final n =
        _base + _comision + _bonosMes - _adelantosMes - _deudaEntrante;
    return n < 0 ? 0 : n;
  }

  /// #1 (Argón nómina): misma regla que NominaScreen (decisión Jc
  /// 2026-10-28) — sin can_ver_cifras no se muestra el conteo
  /// global; el entrenador ve solo su monto base.
  bool get _puedeVerConteo =>
      AuthService().isOwner || PermisosEntrenador().canVerCifras;

  String get _recibo => textoReciboNomina(
        pref: _pref,
        clientesPagados: _clientesPagados,
        tarifa: _tarifa,
        dosis: _dosis,
        comision: _comision,
        bonos: _bonosMes,
        adelantosMes: _adelantosMes,
        deudaEntrante: _deudaEntrante,
        mostrarConteo: _puedeVerConteo,
        sello: kSelloVistaPreviaNomina,
        syncTexto: _syncTexto,
      );

  Future<void> _copiarRecibo() async {
    await Clipboard.setData(ClipboardData(text: _recibo));
    if (!mounted) return;
    mostrarSnack(context, 'Recibo copiado al portapapeles.');
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
      mostrarSnack(context, 'Escribe un monto entero mayor que 0 (máx. 100000).', significado: SignificadoChip.alerta);
      return;
    }
    setState(() => _pidiendo = true);
    try {
      await SolicitudesAdelantoService.instance
          .pedir(monto: monto.toDouble(), motivo: motivoTexto);
      if (!mounted) return;
      mostrarSnack(context, 'Solicitud guardada: sube al sincronizar y el dueño la decidirá.', significado: SignificadoChip.exito);
      await _cargar();
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo enviar: $e', significado: SignificadoChip.error);
    } finally {
      if (mounted) setState(() => _pidiendo = false);
    }
  }

  static const _meses = [
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre',
    'diciembre',
  ];

  /// '2026-10' → 'octubre de 2026' (si no parsea, tal cual).
  String _etiquetaMes(String mes) {
    final m = int.tryParse(mes.length >= 7 ? mes.substring(5, 7) : '');
    if (m == null || m < 1 || m > 12) return mes;
    return '${_meses[m - 1]} de ${mes.substring(0, 4)}';
  }

  /// T22 (1.20): confirmar que recibí la nómina de un mes.
  Future<void> _confirmarRecepcion(Map<String, dynamic> item) async {
    if (_confirmando) return;
    final mes = '${item['mes']}';
    final ok = await DialogoApp.confirmar(
      context,
      titulo: '¿Recibiste tu nómina?',
      mensaje: 'Confirmas que recibiste tu nómina de '
          '${_etiquetaMes(mes)}. El dueño verá tu confirmación '
          'con la fecha y la hora.',
      aceptar: 'Sí, la recibí',
    );
    if (ok != true || !mounted) return;
    setState(() => _confirmando = true);
    try {
      await AdelantosService.instance.confirmarRecepcionNomina(
        mes: mes,
        entrenadorId: _miId,
        entrenadorNombre: AuthService().displayName,
        entrenadorTelegramId: AuthService().telegramId,
      );
      if (!mounted) return;
      mostrarSnack(context, 'Recepción confirmada. ¡Gracias!',
          significado: SignificadoChip.exito);
      await _cargar();
    } catch (e) {
      if (!mounted) return;
      mostrarSnack(context, 'No se pudo confirmar: $e',
          significado: SignificadoChip.error);
    } finally {
      if (mounted) setState(() => _confirmando = false);
    }
  }

  /// T22 (1.20): tarjeta de una liquidación pendiente de mi
  /// acuse, con el desglose de la foto (si ya bajó).
  Widget _tarjetaPorConfirmar(Map<String, dynamic> item) {
    final mes = '${item['mes']}';
    final snap = item['snapshot'] as Map<String, dynamic>?;
    double? v(String k) => (snap?[k] as num?)?.toDouble();
    final neto = v('neto');
    final base = v('base');
    final bonos = v('bonos');
    final comisiones = v('comisiones');
    final adelantos = v('adelantos');
    final deuda = v('deuda_entrante');
    return Padding(
      padding: const EdgeInsets.only(top: AppEspacio.md),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.fact_check_rounded,
                    color: AppColores.naranja, size: 20),
                const SizedBox(width: AppEspacio.sm),
                Expanded(
                  child: Text(
                      'Nómina de ${_etiquetaMes(mes)} liquidada',
                      style: AppTexto.subtitulo),
                ),
              ],
            ),
            const SizedBox(height: AppEspacio.sm),
            if (snap == null)
              const Text(
                  'El dueño marcó tu nómina de este mes como '
                  'pagada. El detalle aún no llega a tu '
                  'teléfono; puedes confirmar igualmente.',
                  style: AppTexto.cuerpo)
            else ...[
              if (base != null)
                Text('Base: ${fmtMonto(base)} CUP',
                    style: AppTexto.cuerpo),
              if (bonos != null && bonos > 0)
                Text('Bonos: ${fmtMonto(bonos)} CUP',
                    style: AppTexto.cuerpo),
              if (comisiones != null && comisiones > 0)
                Text('Comisión por dosis: '
                    '${fmtMonto(comisiones)} CUP',
                    style: AppTexto.cuerpo),
              if (adelantos != null && adelantos > 0)
                Text('Adelantos: −${fmtMonto(adelantos)} CUP',
                    style: AppTexto.cuerpo),
              if (deuda != null && deuda > 0)
                Text('Deuda del mes anterior: '
                    '−${fmtMonto(deuda)} CUP',
                    style: AppTexto.cuerpo),
              if (neto != null)
                Padding(
                  padding:
                      const EdgeInsets.only(top: AppEspacio.xs),
                  child: Text('Neto recibido: '
                      '${fmtMonto(neto)} CUP',
                      style: AppTexto.subtitulo),
                ),
            ],
            const SizedBox(height: AppEspacio.md),
            BotonPrimario(
              texto: 'Confirmar que la recibí',
              icono: Icons.check_rounded,
              cargando: _confirmando,
              onPressed: () => _confirmarRecepcion(item),
            ),
          ],
        ),
      ),
    );
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
                  // N-11 (1.22): fuera el texto obsoleto «Sin
                  // bonos… no entran en esta vista previa»: los
                  // bonos SÍ entran en el resumen desde la 1.19.
                ],
              ),
            ),
            // T22 (1.20): liquidaciones por confirmar y el
            // acuse de la última confirmada.
            for (final item in _porConfirmar)
              _tarjetaPorConfirmar(item),
            if (_porConfirmar.isEmpty && _ultimaConfirmada != null)
              Padding(
                padding: const EdgeInsets.only(top: AppEspacio.md),
                child: Text(
                  '✓ Confirmaste tu nómina de '
                  '${_etiquetaMes('${_ultimaConfirmada!['mes']}')} '
                  'el ${fmtFecha('${_ultimaConfirmada!['confirmada_en']}'.substring(0, 10))}.',
                  style: AppTexto.cuerpo
                      .copyWith(color: AppColores.exito),
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
                    // #1 (Argón nómina): sin permiso de cifras, el
                    // conteo global no se muestra (solo el monto
                    // base propio).
                    _puedeVerConteo
                        ? textoBaseNominaExplicada(
                            _clientesPagados, _tarifa)
                        : 'Tu base este mes: ${fmtMonto(_base)} CUP.',
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
                  _linea('Bonos', '+${fmtMonto(_bonosMes)}'),
                  _linea(
                      'Adelantos del mes', '-${fmtMonto(_adelantosMes)}'),
                  _linea(
                      'Deuda arrastrada', '-${fmtMonto(_deudaEntrante)}'),
                  const Divider(),
                  _linea('NETO ESTIMADO', fmtMonto(_neto),
                      negrita: true),
                  const SizedBox(height: AppEspacio.sm),
                  // N2 (estéticas 1.19): el neto como barra
                  // apilada — verde lo que cobra, rojo claro lo
                  // descontado (adelantos + deuda). Sin base, la
                  // barra queda gris y el texto lo dice.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: Stack(
                      children: [
                        Container(
                          height: 10,
                          color: (_base + _comision + _bonosMes) <= 0
                              ? AppColores.borde(context)
                                  .withValues(alpha: 0.3)
                              : AppColores.error
                                  .withValues(alpha: 0.3),
                        ),
                        FractionallySizedBox(
                          widthFactor:
                              (_base + _comision + _bonosMes) > 0
                                  ? (_neto /
                                          (_base +
                                              _comision +
                                              _bonosMes))
                                      .clamp(0.0, 1.0)
                                  : 0.0,
                          child: Container(
                            height: 10,
                            color: AppColores.exito,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    (_base + _comision + _bonosMes) <= 0
                        ? 'Sin base este mes'
                        : (_adelantosMes + _deudaEntrante) > 0
                            ? 'De ${fmtMonto(_base + _comision + _bonosMes)} brutos, descuentan ${fmtMonto(_adelantosMes + _deudaEntrante)}'
                            : 'Sin descuentos este mes',
                    style: AppTexto.secundario,
                  ),
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
                        // Argón P3#8-parte-motivo: el servidor mete el
                        // motivo en la columna `nota`; `motivo` solo
                        // como respaldo.
                        '${(e['nota'] ?? e['motivo']) != null && '${e['nota'] ?? e['motivo']}'.isNotEmpty ? ' · ${e['nota'] ?? e['motivo']}' : ''}'
                        '${_origenAdelanto(e)}',
                        style: AppTexto.cuerpo,
                      ),
                  const SizedBox(height: AppEspacio.sm),
                  // 19/25: pedidos aún sin subir (op en cola): el
                  // entrenador los ve desde que los toca, no solo
                  // cuando bajan del servidor.
                  if (_solicitudes
                      .where((s) => s.estado == 'por_enviar')
                      .isNotEmpty) ...[
                    const Text('Por enviar (aún no sube al servidor)',
                        style: AppTexto.secundario),
                    for (final s in _solicitudes.where(
                        (s) => s.estado == 'por_enviar'))
                      Text(
                        '· ${fmtMonto(s.monto)} CUP · ${s.motivo}'
                        '${s.creadoEn != null && s.creadoEn!.length >= 10 ? ' · ${s.creadoEn!.substring(0, 10)}' : ''}',
                        style: AppTexto.cuerpo,
                      ),
                    const SizedBox(height: AppEspacio.sm),
                  ],
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
                      .where((s) =>
                          !s.pendiente && s.estado != 'por_enviar')
                      .isNotEmpty) ...[
                    const SizedBox(height: AppEspacio.sm),
                    const Text('Solicitudes resueltas',
                        style: AppTexto.secundario),
                    for (final s in _solicitudes.where((s) =>
                        !s.pendiente && s.estado != 'por_enviar'))
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
                          RutaIron(
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
                          RutaIron(
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
            // N-10 (1.22): sin cliente_id no hay cruce posible
            // con protegidos: el nombre crudo solo lo ve el
            // dueño; el entrenador ve el genérico.
            : (AuthService().isOwner
                ? ('${v['cliente_nombre'] ?? ''}')
                : 'Cliente'));
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
  double bonos = 0,
  required double adelantosMes,
  required double deudaEntrante,
  bool mostrarConteo = true,
  required String sello,
  required String syncTexto,
}) {
  final base = clientesPagados * tarifa.toDouble();
  var neto = base + comision + bonos - adelantosMes - deudaEntrante;
  if (neto < 0) neto = 0;
  final b = StringBuffer();
  b.writeln(sello);
  b.writeln(syncTexto);
  b.writeln('Mes: $pref');
  // #1 (Argón nómina): sin permiso de cifras, la base va sin el
  // conteo global.
  if (mostrarConteo) {
    b.writeln(
        'Base: $clientesPagados clientes × $tarifa = ${fmtMonto(base)} CUP');
  } else {
    b.writeln('Base: ${fmtMonto(base)} CUP');
  }
  b.writeln('Comisión dosis: $dosis dosis = ${fmtMonto(comision)} CUP');
  b.writeln('Bonos: +${fmtMonto(bonos)} CUP');
  b.writeln('Adelantos del mes: -${fmtMonto(adelantosMes)} CUP');
  b.writeln('Deuda arrastrada: -${fmtMonto(deudaEntrante)} CUP');
  b.writeln('NETO ESTIMADO: ${fmtMonto(neto)} CUP');
  b.writeln('El pago se hace el último día del mes.');
  return b.toString();
}
