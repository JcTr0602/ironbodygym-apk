/// 👥 Historial por entrenador (solo dueño).
/// Muestra por cada entrenador: total cobrado en el mes, nº de pagos,
/// nº de inscripciones y pendiente actual por entregar.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'comparativa_entrenadores.dart';
import 'detalle_entrenador.dart';
import 'diseno.dart';
import 'widgets.dart';
import 'skeleton.dart';
import '../app_log.dart';
import '../entrenador_identidad.dart';

/// Yunque 4 (L5-3): agregación «cobrado del mes por
/// entrenador» de esta pantalla, pura para poder fijarla
/// con test. Aplica los dos saltos del detalle
/// (detalle_entrenador): pago anulado (marca en el JSON u
/// anulación viva en cola) y Cuenta a la Casa fuera — la
/// lista y el detalle deben ser la misma cifra.
({Map<String, double> cobrado, Map<String, int> numPagos})
    agregarCobradoPorEntrenador(
  List<Map<String, dynamic>> pagos,
  Set<int> anuladosEnCola,
  Set<int> cuentasCasa,
) {
  final cobrado = <String, double>{};
  final numPagos = <String, int>{};
  for (final p in pagos) {
    if (esPagoAnulado(p, anuladosEnCola)) continue;
    final cidCasa = (p['cliente_id'] as num?)?.toInt();
    if (cidCasa != null && cuentasCasa.contains(cidCasa)) continue;
    final nombre = ('${p['registrado_por_nombre'] ?? ''}'.trim().isEmpty)
        ? '${p['registrado_por'] ?? 'Desconocido'}'
        : '${p['registrado_por_nombre']}'.trim();
    cobrado[nombre] = (cobrado[nombre] ?? 0) +
        ((p['monto'] as num?)?.toDouble() ?? 0);
    numPagos[nombre] = (numPagos[nombre] ?? 0) + 1;
  }
  return (cobrado: cobrado, numPagos: numPagos);
}

/// F02-PB (z14_turnos-2): decisión PURA de publicar un
/// cambio de `_falloCarga`: solo si la generación de ESTA
/// carga sigue siendo la vigente al terminar. Un fallo
/// tardío de otro mes no tapa un mes que cargó bien, ni un
/// éxito tardío limpia el error de un mes que falló.
bool debePublicarFalloCarga({
  required int genEstaCarga,
  required int genVigente,
}) =>
    genEstaCarga == genVigente;

class HistorialEntrenadorScreen extends StatefulWidget {
  const HistorialEntrenadorScreen({super.key});
  @override
  State<HistorialEntrenadorScreen> createState() =>
      _HistorialEntrenadorScreenState();
}

class _HistorialEntrenadorScreenState
    extends State<HistorialEntrenadorScreen> {
  bool _cargando = true;
  // SL-X2 (G12-1, 3ª superficie): la carga falló — la
  // pantalla pinta EstadoError con Reintentar, no el
  // «Sin actividad» de un mes vacío (un fallo no es un
  // dato). Mismo patrón que SL-11 en Mi Turno y el
  // calendario.
  bool _falloCarga = false;
  // Hy4 G#36: generación de carga — una carga vieja que
  // termina después que la del mes nuevo NO publica
  // (enseñaba las cifras del mes anterior bajo el título
  // del nuevo).
  int _genCarga = 0;
  List<Map<String, dynamic>> _datos = [];
  // 1.25 T119 (F3-17): selector de mes (antes solo el mes
  // actual, a diferencia de la Comparativa). El pendiente por
  // entregar es una foto de HOY: solo se mezcla en el mes en
  // curso.
  late DateTime _mesSel = DateTime(
      ahoraHabana().year, ahoraHabana().month);
  // Cobros/inscripciones sin entrenador identificado: se
  // cuentan como aviso de datos, no como una persona más.
  int _sinIdentificarPagos = 0;
  double _sinIdentificarMonto = 0;
  int _sinIdentificarInsc = 0;

  bool get _esMesActual {
    final n = ahoraHabana();
    return _mesSel.year == n.year && _mesSel.month == n.month;
  }

  String get _prefSel =>
      '${_mesSel.year.toString().padLeft(4, '0')}-'
      '${_mesSel.month.toString().padLeft(2, '0')}';

  void _cambiarMes(int delta) {
    setState(() {
      _mesSel = DateTime(_mesSel.year, _mesSel.month + delta);
      _cargando = true;
    });
    _cargar();
  }

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
    // F02-PB (z14_turnos-2): la generación de ESTA carga.
    // _cargarDatos incrementa _genCarga como primer paso
    // síncrono al ser llamado (sin await entre esta captura
    // y esa llamada), así que su generación es la previa + 1;
    // al terminar, solo publica _falloCarga si ninguna carga
    // más nueva la ha superado.
    final genEstaCarga = _genCarga + 1;
    try {
      await _cargarDatos();
      // SL-X2 (G12-1): una recarga buena limpia la bandera
      // (solo si esta carga sigue vigente: F02-PB).
      if (mounted &&
          _falloCarga &&
          debePublicarFalloCarga(
              genEstaCarga: genEstaCarga, genVigente: _genCarga)) {
        setState(() => _falloCarga = false);
      }
    } catch (e) {
      // El error NO se traga: queda en bitácora
      // (la clase nació de fallos mudos).
      AppLog.error('ui', 'carga_fallo', d: '$e');
      // SL-X2 (G12-1): y además se DICE en pantalla con
      // EstadoError — antes _datos quedaba [] y la
      // pantalla pintaba «Sin actividad» como si el mes
      // estuviera vacío de verdad. F02-PB: solo si esta
      // carga sigue vigente.
      if (mounted &&
          debePublicarFalloCarga(
              genEstaCarga: genEstaCarga, genVigente: _genCarga)) {
        setState(() => _falloCarga = true);
      }
    } finally {
      // (1.36 H-B4 136-869) solo la generación vigente baja
      // la bandera.
      if (mounted && _cargando && genEstaCarga == _genCarga) {
        setState(() => _cargando = false);
      }
    }
  }

  Future<void> _cargarDatos() async {
    final gen = ++_genCarga;
    final pref = _prefSel;

    // Pagos del mes agrupados por entrenador (por nombre),
    // con los saltos del detalle (L5-3, ver el helper).
    final anuladosCola =
        await LocalDb.instance.pagosAnuladosEnCola();
    final casas = await LocalDb.instance.idsCuentasCasa();
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    final agg = agregarCobradoPorEntrenador(
        await LocalDb.instance.pagosDelMes(pref), anuladosCola, casas);
    final cobrado = agg.cobrado;
    final numPagos = agg.numPagos;

    // Inscripciones del mes por entrenador.
    final insc = await inscripcionesPorEntrenador(prefMes: pref);
    final inscMap = <String, int>{
      for (final e in insc) '${e['nombre']}': (e['cantidad'] as int)
    };

    // Pendiente por entregar por entrenador: es la foto de
    // HOY — solo tiene sentido en el mes en curso.
    final pendMap = <String, double>{
      if (_esMesActual)
        for (final e in await pendientePorEntrenador())
          '${e['nombre']}': (e['total'] as double)
    };

    // F3-17: «Desconocido» no es una persona: sus cobros e
    // inscripciones se apartan y se cuentan como aviso.
    final sinPagos = numPagos.remove('Desconocido') ?? 0;
    final sinMonto = cobrado.remove('Desconocido') ?? 0.0;
    final sinInsc = inscMap.remove('Desconocido') ?? 0;

    // Unir por nombre.
    final nombres = <String>{
      ...cobrado.keys,
      ...inscMap.keys,
      ...pendMap.keys,
    };
    final datos = nombres.map((nombre) {
      return {
        'nombre': nombre,
        'cobrado': cobrado[nombre] ?? 0.0,
        'pagos': numPagos[nombre] ?? 0,
        'inscripciones': inscMap[nombre] ?? 0,
        'pendiente': pendMap[nombre] ?? 0.0,
      };
    }).toList();
    datos.sort((a, b) =>
        ((b['cobrado'] as double)).compareTo(a['cobrado'] as double));

    // Hy4 G#36: si el mes cambió mientras esta carga
    // leía, su resultado ya no es el de la pantalla.
    if (mounted && gen == _genCarga) {
      setState(() {
        _datos = datos;
        _sinIdentificarPagos = sinPagos;
        _sinIdentificarMonto = sinMonto;
        _sinIdentificarInsc = sinInsc;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Argón P1#8: pantalla solo dueño.
    if (!AuthService().isOwner) {
      return Scaffold(
        appBar: appBarIron(context, 'Historial por entrenador'),
        body: const Center(
          child: Text('Solo el dueño puede ver el historial por entrenador.'),
        ),
      );
    }
    const meses = [
      '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'
    ];
    return Scaffold(
      appBar: appBarIron(
        context,
        'Historial por entrenador',
        acciones: [
          // F7 (1.20): comparativa lado a lado del mes.
          IconButton(
            tooltip: 'Comparativa del mes',
            icon: const Icon(Icons.compare_arrows_rounded),
            onPressed: () => Navigator.push(
              context,
              RutaIron(
                builder: (_) =>
                    const ComparativaEntrenadoresScreen(),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          // F3-17: selector de mes como el de la Comparativa.
          Padding(
            padding: const EdgeInsets.all(AppEspacio.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.chevron_left_rounded),
                  tooltip: 'Mes anterior',
                  onPressed: () => _cambiarMes(-1),
                ),
                Expanded(
                  child: Text(
                    'Resumen de ${meses[_mesSel.month]} ${_mesSel.year}',
                    style: AppTexto.titulo,
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.chevron_right_rounded),
                  tooltip: 'Mes siguiente',
                  onPressed: _esMesActual ? null : () => _cambiarMes(1),
                ),
              ],
            ),
          ),
          if (!_esMesActual)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppEspacio.md, 0, AppEspacio.md, AppEspacio.sm),
              child: Text(
                'Mes pasado: el pendiente por entregar no se muestra '
                '(es una foto de hoy).',
                style: AppTexto.secundario,
                textAlign: TextAlign.center,
              ),
            ),
          Expanded(
            child: _cargando
                // (1.36 H-B4 136-872) esqueleto de lista al cargar.
                ? const SkeletonLista()
                : _falloCarga
                    // SL-X2 (G12-1): el fallo se dice, con
                    // salida — nunca como «Sin actividad».
                    ? EstadoError(
                        titulo: 'No se pudo cargar',
                        detalle:
                            'La lectura del historial falló en este teléfono. Tus datos no se han perdido: reinténtalo.',
                        onReintentar: _cargar,
                      )
                    : _datos.isEmpty && _sinIdentificarPagos == 0 &&
                        _sinIdentificarInsc == 0
                    // F3-26: vacío del sistema (antes texto plano).
                    ? const EstadoVacio(
                        icono: Icons.people_rounded,
                        titulo: 'Sin actividad',
                        subtitulo:
                            'Nadie cobró ni inscribió en este mes.')
                    : _datos.isEmpty
                        // (1.36 H-B4 136-872) el estado sin
                        // identificar también se puede refrescar.
                        ? RefrescoIron(
                            onRefresh: _cargar,
                            child: ListView(children: [
                              _notaSinIdentificar(context),
                            ]),
                          )
                        : RefrescoIron(
                        onRefresh: _cargar,
                        child: ListView.builder(
                          itemCount: _datos.length +
                              ((_sinIdentificarPagos > 0 ||
                                      _sinIdentificarInsc > 0)
                                  ? 1
                                  : 0),
                          itemBuilder: (ctx, i) {
                            if (i == _datos.length) {
                              return _notaSinIdentificar(context);
                            }
                            final d = _datos[i];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppEspacio.md, vertical: 6),
                              child: Tarjeta(
                                padding:
                                    const EdgeInsets.all(AppEspacio.md),
                                onTap: () async {
                                  // (1.36 H-B4 136-870) el
                                  // telegram id viaja al detalle.
                                  final tid =
                                      await telegramIdDeEntrenador(
                                          '${d['nombre']}');
                                  if (!context.mounted) return;
                                  Navigator.of(context).push(
                                    RutaIron(
                                      builder: (_) =>
                                          DetalleEntrenadorScreen(
                                              nombre: '${d['nombre']}',
                                              telegramId: tid),
                                    ),
                                  );
                                },
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${d['nombre']}',
                                      style: AppTexto.titulo,
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        _metrica('Cobrado',
                                            '${fmtMonto(d['cobrado'] as double)} CUP'),
                                        _metrica('Pagos',
                                            '${d['pagos']}'),
                                        _metrica('Inscritos',
                                            '${d['inscripciones']}'),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    if (_esMesActual)
                                    Row(
                                      children: [
                                        Text('Pendiente por entregar: ',
                                            style: AppTexto.secundario
                                                .copyWith(
                                                    color: AppColores
                                                        .textoSecundario(
                                                            context))),
                                        Text(
                                          '${fmtMonto(d['pendiente'] as double)} CUP',
                                          style: AppTexto.metadato.copyWith(color: (d['pendiente']
                                                          as double) >
                                                      0
                                                  ? AppColores.error
                                                  : AppColores.exito, fontWeight: FontWeight.bold),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  /// F3-17: aviso de datos sin entrenador identificado (antes
  /// era una tarjeta-persona «Desconocido» que abría un
  /// detalle vacío).
  Widget _notaSinIdentificar(BuildContext context) {
    final partes = <String>[
      if (_sinIdentificarPagos > 0)
        '$_sinIdentificarPagos cobro${_sinIdentificarPagos == 1 ? '' : 's'} '
            'por ${fmtMonto(_sinIdentificarMonto)} CUP',
      if (_sinIdentificarInsc > 0)
        '$_sinIdentificarInsc inscripci${_sinIdentificarInsc == 1 ? 'ón' : 'ones'}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppEspacio.md, vertical: 6),
      child: Tarjeta(
        color: AppColores.alerta.withValues(alpha: 0.10),
        child: Row(
          children: [
            const Icon(Icons.help_outline_rounded,
                color: AppColores.alertaOscuro),
            const SizedBox(width: AppEspacio.sm),
            Expanded(
              child: Text(
                'Sin entrenador identificado: ${partes.join(' · ')}. '
                'Son registros sin «registrado por», no de una persona.',
                style: AppTexto.secundario,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metrica(String etiqueta, String valor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(etiqueta,
            style: AppTexto.minuscula.copyWith(
                color:
                    AppColores.textoSecundario(context))),
        Text(valor,
            style: AppTexto.cuerpo.copyWith(fontWeight: FontWeight.bold)),
      ],
    );
  }
}
