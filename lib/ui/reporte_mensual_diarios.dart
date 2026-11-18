/// v1.3.2: resumen mensual de pagos diarios.
/// Por turno (mañana/tarde) y por entrenador, con selector de mes.
/// Solo pagos diarios: las mensualidades tienen sus propios reportes.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import '../app_log.dart';

class ReporteMensualDiariosScreen extends StatefulWidget {
  const ReporteMensualDiariosScreen({super.key});

  @override
  State<ReporteMensualDiariosScreen> createState() =>
      _ReporteMensualDiariosScreenState();
}

class _ReporteMensualDiariosScreenState
    extends State<ReporteMensualDiariosScreen> {
  bool _cargando = true;

  /// 1.25 T72: día tocado en el gráfico diario (null =
  /// se muestra el mejor día).
  int? _diaSel;
  // Argón stats MEDIO: DateTime.now() local en vez de hora Habana
  // (el último día del mes después de las 7-8 PM abría el mes
  // siguiente en teléfonos con zona distinta).
  DateTime _mes = DateTime(
      ahoraHabana().year, ahoraHabana().month);
  Map<String, dynamic> _datos = {};

  static const _meses = [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
    'Diciembre',
  ];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    // (Yunque R2-X1) red de seguridad: la bandera baja
    // SIEMPRE (y el fallo queda en bitácora), también si una lectura local lanza a mitad
    // (spinner eterno: la clase de la ficha 2026-11-02).
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
    setState(() => _cargando = true);
    // Argón stats MENOR: la pantalla la abre también el entrenador
    // desde Pago diario. El dueño ve todo; el entrenador, solo lo
    // suyo (resumenMensualDiarios ya soporta soloTelegramId; -1 si
    // no hay id, para no mostrar nada en vez de todo).
    final datos = await resumenMensualDiarios(_mes.year, _mes.month,
        soloTelegramId: AuthService().isOwner
            ? null
            : (AuthService().telegramId ?? -1));
    if (mounted) {
      setState(() {
        _datos = datos;
        _cargando = false;
      });
    }
  }

  /// 1.25 T72: las barras de los días del mes en curso.
  Widget _graficoDias(Map<String, dynamic> porDia) {
    final diasEnMes =
        DateTime(_mes.year, _mes.month + 1, 0).day;
    final serie = serieDiasReporte(porDia, _mes.year,
        _mes.month, diasEnMes);
    final mejor = mejorDiaReporte(serie);
    var maximo = 0.0;
    for (final v in serie) {
      if (v > maximo) maximo = v;
    }
    // Argón 1.25 MEDIA: una selección de un mes más
    // largo (día 31) no puede indexar la serie de un
    // mes corto (RangeError al pintar el rótulo).
    final sel = (_diaSel != null && _diaSel! <= serie.length)
        ? _diaSel
        : null;
    final diaRotulo = sel ?? (mejor >= 0 ? mejor + 1 : null);
    return Tarjeta(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Diarios por día',
                    style: AppTexto.subtitulo),
              ),
              if (mejor >= 0)
                Text('★ Mejor día: ${mejor + 1}',
                    style: AppTexto.secundario.copyWith(
                        color: AppColores.naranja,
                        fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < serie.length; i++)
                Expanded(
                  child: GestureDetector(
                    // SL-5B G07-9: el objetivo de toque de
                    // cada barra es la zona completa de
                    // 64 dp (≥44 dp de la casa), no la
                    // barra visual — con 31 columnas a
                    // 360 dp la barra sola medía ~8 dp.
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        setState(() => _diaSel = i + 1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 1),
                      child: SizedBox(
                        height: 64,
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          // 1.36 H-C3 (136-1044, GF-080): la
                          // barra crece animada (mismo patrón
                          // que las del Dashboard).
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(
                                'rep-mensual-${_mes.year}-${_mes.month}-$i-${serie[i]}'),
                            tween: Tween(begin: 0, end: 1),
                            duration: AppMovimiento.larga,
                            curve: AppMovimiento.curvaSuave,
                            builder: (ctx, f, _) => Container(
                              height: (8 +
                                      (maximo > 0
                                          ? serie[i] / maximo * 56
                                          : 0)) *
                                  f,
                              decoration: BoxDecoration(
                                color: i == mejor
                                    ? AppColores.naranja
                                    : sel == i + 1
                                        ? AppColores.naranja
                                            .withValues(alpha: 0.85)
                                        : AppColores.naranja
                                            .withValues(alpha: 0.35),
                                borderRadius:
                                    const BorderRadius.vertical(
                                        top: Radius.circular(2)),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppEspacio.sm),
          Text(
            diaRotulo == null
                ? 'Sin registros este mes'
                : 'Día $diaRotulo: '
                    '${fmtMonto(serie[diaRotulo - 1])} CUP'
                    '${sel == null && diaRotulo == mejor + 1 ? ' · el mejor del mes' : ''}',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  void _cambiarMes(int delta) {
    setState(() {
      _mes = DateTime(_mes.year, _mes.month + delta);
      // Argón 1.25 MEDIA: la selección de día no viaja
      // entre meses (un 31 no existe en febrero).
      _diaSel = null;
      // 1.36 H-C3 (136-1043, GF-079): el dato del mes
      // anterior se INVALIDA al cambiar: no se pinta el mes
      // viejo bajo el rótulo del nuevo mientras carga.
      _datos = {};
    });
    _cargar();
  }

  /// 1.36 H-C3 (136-1044, GF-080): salto rápido a un mes/ano
  /// concreto (antes solo flechas de a un mes).
  Future<void> _saltarAMes() async {
    var ano = _mes.year;
    final elegido = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => DialogoApp(
          titulo: 'Ir a un mes',
          iconoTitulo: Icons.calendar_month_rounded,
          contenido: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Año anterior',
                    icon: const Icon(Icons.chevron_left_rounded),
                    onPressed: () => setD(() => ano--),
                  ),
                  Text('$ano', style: AppTexto.subtitulo),
                  IconButton(
                    tooltip: 'Año siguiente',
                    icon: const Icon(Icons.chevron_right_rounded),
                    onPressed: ano >= ahoraHabana().year
                        ? null
                        : () => setD(() => ano++),
                  ),
                ],
              ),
              const SizedBox(height: AppEspacio.sm),
              Wrap(
                spacing: AppEspacio.sm,
                runSpacing: AppEspacio.sm,
                children: [
                  for (var m = 1; m <= 12; m++)
                    ChoiceChip(
                      label: Text(_meses[m - 1].substring(0, 3)),
                      selected: ano == _mes.year && m == _mes.month,
                      onSelected: (_) =>
                          Navigator.pop(ctx, DateTime(ano, m)),
                    ),
                ],
              ),
            ],
          ),
          acciones: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      ),
    );
    if (elegido == null || !mounted) return;
    final ahora = ahoraHabana();
    final limite = DateTime(ahora.year, ahora.month);
    final destino =
        elegido.isAfter(limite) ? limite : elegido;
    if (destino.year == _mes.year && destino.month == _mes.month) {
      return;
    }
    setState(() {
      _mes = destino;
      _diaSel = null;
      _datos = {};
    });
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    final porTurno =
        (_datos['porTurno'] as Map<String, dynamic>?) ?? {};
    final porEntrenador =
        (_datos['porEntrenador'] as Map<String, dynamic>?) ?? {};
    final porDia =
        (_datos['porDia'] as Map<String, dynamic>?) ?? {};
    final total = (_datos['total'] as num?)?.toDouble() ?? 0;
    final diasConRegistro = porDia.keys.toList()..sort();
    // SL-5B G07-4: los turnos sin importe no se generan
    // (en cero no aparecen, regla de Jc).
    final turnosVisibles = [
      for (final t in ['mañana', 'tarde'])
        if (((porTurno[t]?['total'] as num?)?.toDouble() ?? 0) > 0) t,
    ];

    return Scaffold(
      appBar: appBarIron(context, 'Pagos diarios del mes'),
      body: _cargando
          // 1.25 T118 (F2-20): carga del sistema (antes un
          // CircularProgressIndicator crudo; las pantallas
          // hermanas del frente usan EstadoCargando para
          // resúmenes y SkeletonLista para listas).
          ? const EstadoCargando(texto: 'Cargando pagos diarios…')
          : ListView(
              padding: const EdgeInsets.all(AppEspacio.lg),
              children: [
                // Selector de mes
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.center,
                  children: [
                    IconButton(
                      // 1.36 H-C3 (136-1044, GF-080): las
                      // flechas se anuncian.
                      tooltip: 'Mes anterior',
                      icon: const Icon(
                          Icons.chevron_left_rounded),
                      onPressed: () => _cambiarMes(-1),
                    ),
                    // 136-1044: tocar el rótulo abre el salto
                    // rápido a mes/año.
                    InkWell(
                      onTap: _saltarAMes,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppEspacio.sm,
                            vertical: AppEspacio.xs),
                        child: Text(
                          '${_meses[_mes.month - 1]} ${_mes.year}',
                          style: AppTexto.subtitulo,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Mes siguiente',
                      icon: const Icon(
                          Icons.chevron_right_rounded),
                      onPressed: () {
                        final ahora = ahoraHabana();
                        final limite = DateTime(
                            ahora.year, ahora.month);
                        if (_mes.isBefore(limite)) {
                          _cambiarMes(1);
                        }
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // Total del mes
                Tarjeta(
                  color: AppColores.naranja,
                  padding:
                      const EdgeInsets.all(AppEspacio.lg),
                  child: Column(
                    children: [
                      Text('Total del mes',
                          style: AppTexto.secundario
                              .copyWith(
                                  color: Colors.white
                                      .withValues(
                                          alpha:
                                              0.85))),
                      Text('${fmtMonto(total)} CUP',
                          style: AppTexto.display
                              .copyWith(
                                  color:
                                      Colors.white)),
                      Text(
                          '${diasConRegistro.length} días con registro',
                          style: AppTexto.minuscula
                              .copyWith(
                                  color: Colors.white
                                      .withValues(
                                          alpha:
                                              0.85))),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 1.25 T72: el mes en barras — un vistazo
                // al ritmo de los diarios, con el mejor
                // día marcado; tocar una barra la detalla.
                if (total > 0) ...[
                  _graficoDias(porDia),
                  const SizedBox(height: 16),
                ],
                // Por turno
                // 1.36 H-C3 (136-1043, GF-079): la sección
                // entera se oculta si ningún turno tiene
                // importe (regla de filas en cero de Jc).
                if (turnosVisibles.isNotEmpty) ...[
                const Text('Por turno',
                    style: AppTexto.subtitulo),
                const SizedBox(height: AppEspacio.sm),
                Row(
                  children: [
                    for (var i = 0; i < turnosVisibles.length; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                              right: i < turnosVisibles.length - 1
                                  ? 8
                                  : 0),
                          child: Tarjeta(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text(
                                    turnosVisibles[i] == 'mañana'
                                        ? 'Mañana'
                                        : 'Tarde',
                                    style: AppTexto
                                        .secundario),
                                Text(
                                  '${fmtMonto((porTurno[turnosVisibles[i]]?['total'] as num?)?.toDouble() ?? 0)} CUP',
                                  style: AppTexto.titulo,
                                ),
                                Text(
                                    '${((porTurno[turnosVisibles[i]]?['cantidad'] as num?)?.toDouble() ?? 0).toInt()} pagos'),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                ],
                // Argón stats MENOR: resumenMensualDiarios agrupa
                // también 'noche'; sin tarjeta, ese dinero sumaba en
                // el total sin aparecer en ninguna tarjeta de turno.
                if (((porTurno['noche']?['total'] as num?)?.toDouble() ??
                        0) >
                    0)
                  Padding(
                    padding: const EdgeInsets.only(top: AppEspacio.sm),
                    child: Tarjeta(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Noche', style: AppTexto.secundario),
                          Text(
                            '${fmtMonto((porTurno['noche']?['total'] as num?)?.toDouble() ?? 0)} CUP',
                            style: AppTexto.titulo,
                          ),
                          Text(
                              '${((porTurno['noche']?['cantidad'] as num?)?.toDouble() ?? 0).toInt()} pagos'),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                // Por entrenador
                const Text('Por entrenador',
                    style: AppTexto.subtitulo),
                const SizedBox(height: 8),
                if (porEntrenador.isEmpty)
                  Tarjeta(
                    child: Text(
                        'Sin registros este mes.',
                        textAlign: TextAlign.center,
                        style: AppTexto.secundario
                            .copyWith(
                                color: AppColores
                                    .textoSecundario(
                                        context))),
                  )
                else
                  for (final e
                      in porEntrenador.entries)
                    Padding(
                      padding:
                          const EdgeInsets.only(
                              bottom: AppEspacio.sm),
                      child: Tarjeta(
                        child: ListTile(
                          contentPadding:
                              EdgeInsets.zero,
                          title: Text('${e.key}',
                              style:
                                  const TextStyle(
                                      fontWeight:
                                          FontWeight
                                              .w600)),
                          subtitle: Text(
                              '${((e.value['cantidad'] as num?)?.toDouble() ?? 0).toInt()} pagos'),
                          trailing: Text(
                            '${fmtMonto((e.value['total'] as num?)?.toDouble() ?? 0)} CUP',
                            style: const TextStyle(
                                fontWeight:
                                    FontWeight.bold,
                                color: AppColores
                                    .naranja),
                          ),
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
                // 1.25 T27: los diarios por día dejan de vivir
                // solo en la lista plegada del final: el gráfico
                // de barras de la casa se ve al entrar (la forma
                // del mes de un vistazo); la lista con la cifra
                // exacta de cada día queda debajo, desplegable.
                if (diasConRegistro.isNotEmpty) ...[
                  const Text('Diarios por día',
                      style: AppTexto.subtitulo),
                  const SizedBox(height: 8),
                  Tarjeta(
                    child: GraficoBarrasDiarias(
                      datos: [
                        for (final d in diasConRegistro)
                          {
                            'fecha': d,
                            'total':
                                (porDia[d] as num?)?.toDouble() ??
                                    0,
                          }
                      ],
                      altura: 96,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                // Por día (colapsado)
                if (diasConRegistro.isNotEmpty)
                  Tarjeta(
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      title: const Text('Por día',
                          style: AppTexto.subtitulo),
                      children: [
                        for (final d
                            in diasConRegistro)
                          ListTile(
                            dense: true,
                            contentPadding:
                                EdgeInsets.zero,
                            title: Text(
                                fmtFecha(d)),
                            trailing: Text(
                                '${fmtMonto((porDia[d] as num?)?.toDouble() ?? 0)} CUP',
                                style:
                                    const TextStyle(
                                        fontWeight:
                                            FontWeight
                                                .w600)),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
    );
  }
}


/// 1.25 T72: los totales de pagos diarios por día del
/// mes (índice 0 = día 1), 0 donde no hubo registro.
/// [porDia] trae las claves 'AAAA-MM-DD'.
List<double> serieDiasReporte(Map<String, dynamic> porDia,
    int anio, int mes, int diasEnMes) {
  String clave(int d) =>
      '$anio-${mes.toString().padLeft(2, '0')}-'
      '${d.toString().padLeft(2, '0')}';
  return [
    for (var d = 1; d <= diasEnMes; d++)
      (porDia[clave(d)] as num?)?.toDouble() ?? 0,
  ];
}

/// 1.25 T72: índice (0-based) del día con mayor total;
/// -1 si todos son cero.
int mejorDiaReporte(List<double> serie) {
  var mejor = -1;
  var maximo = 0.0;
  for (var i = 0; i < serie.length; i++) {
    if (serie[i] > maximo) {
      maximo = serie[i];
      mejor = i;
    }
  }
  return mejor;
}
