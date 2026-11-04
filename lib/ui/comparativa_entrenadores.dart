/// F7 (1.20): comparativa de entrenadores del mes, lado a
/// lado — quién cobró más, vendió más o dio más dosis.
/// Solo dueño. Los datos salen de
/// [comparativaEntrenadores] (espejos locales, sin red) y
/// tocar el nombre de un entrenador abre su detalle.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import '../tiempo.dart';
import 'app_bar.dart';
import 'componentes.dart';
import 'detalle_entrenador.dart';
import 'diseno.dart';

class ComparativaEntrenadoresScreen extends StatefulWidget {
  const ComparativaEntrenadoresScreen({super.key});

  @override
  State<ComparativaEntrenadoresScreen> createState() =>
      _ComparativaEntrenadoresScreenState();
}

class _ComparativaEntrenadoresScreenState
    extends State<ComparativaEntrenadoresScreen> {
  static const _meses = [
    'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
    'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre',
    'Diciembre',
  ];

  late DateTime _mes;
  bool _cargando = true;
  List<Map<String, dynamic>> _filas = [];

  @override
  void initState() {
    super.initState();
    final n = ahoraHabana();
    _mes = DateTime(n.year, n.month);
    _cargar();
  }

  String get _prefijo =>
      '${_mes.year.toString().padLeft(4, '0')}-'
      '${_mes.month.toString().padLeft(2, '0')}';

  Future<void> _cargar() async {
    setState(() => _cargando = true);
    final filas = await comparativaEntrenadores(_prefijo);
    if (!mounted) return;
    setState(() {
      _filas = filas;
      _cargando = false;
    });
  }

  void _moverMes(int delta) {
    setState(() => _mes = DateTime(_mes.year, _mes.month + delta));
    _cargar();
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService().isOwner) {
      // FIN-07 de Argón (1.20): mismo patrón visual que
      // conciliación y diferencias para el bloqueo de rol.
      return Scaffold(
        appBar:
            appBarIron(context, 'Comparativa de entrenadores'),
        body: const EstadoVacio(
          icono: Icons.lock_rounded,
          titulo: 'Solo el dueño',
          subtitulo: 'La comparativa es solo del dueño.',
        ),
      );
    }
    final n = ahoraHabana();
    final esMesActual = _mes.year == n.year && _mes.month == n.month;
    return Scaffold(
      appBar: appBarIron(context, 'Comparativa de entrenadores'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.lg),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: 'Mes anterior',
                icon: const Icon(Icons.chevron_left_rounded),
                onPressed: () => _moverMes(-1),
              ),
              Expanded(
                child: Text(
                  '${_meses[_mes.month - 1]} ${_mes.year}',
                  textAlign: TextAlign.center,
                  style: AppTexto.titulo,
                ),
              ),
              IconButton(
                tooltip: 'Mes siguiente',
                icon: const Icon(Icons.chevron_right_rounded),
                onPressed: esMesActual ? null : () => _moverMes(1),
              ),
            ],
          ),
          const SizedBox(height: AppEspacio.md),
          if (_cargando)
            const EstadoCargando()
          else if (_filas.length < 2)
            const EstadoVacio(
              icono: Icons.group_rounded,
              titulo: 'Sin comparativa este mes',
              subtitulo: 'Hacen falta al menos dos entrenadores '
                  'con actividad registrada en el mes.',
            )
          else
            _tabla(),
          const SizedBox(height: AppEspacio.md),
          const Text(
            'La Casa cuenta como dosis dadas, no como dinero. '
            'Las ventas anuladas no cuentan y los reversos '
            'restan.',
            style: AppTexto.secundario,
          ),
        ],
      ),
    );
  }

  Widget _tabla() {
    final cols = _filas.take(3).toList();
    final hayUsd =
        cols.any((f) => ((f['ventas_usd'] as num?) ?? 0) > 0);
    return Tarjeta(
      child: Column(
        children: [
          // FIN-07 de Argón (1.20): la tabla muestra hasta 3
          // columnas (ordenadas por total); si hay más perfiles
          // con actividad, se avisa en vez de ocultarlos.
          if (_filas.length > 3)
            Padding(
              padding: const EdgeInsets.only(bottom: AppEspacio.sm),
              child: Text(
                'Se muestran los 3 con más actividad de '
                '${_filas.length} perfiles.',
                style: AppTexto.metadato,
              ),
            ),
          // Cabecera: nombre de cada entrenador (tocable →
          // su detalle).
          Row(
            children: [
              const Expanded(flex: 3, child: SizedBox()),
              for (final f in cols)
                Expanded(
                  flex: 2,
                  child: InkWell(
                    onTap: () => Navigator.push(
                      context,
                      RutaIron(
                        builder: (_) => DetalleEntrenadorScreen(
                            nombre: '${f['nombre']}'),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppEspacio.sm),
                      child: Text(
                        '${f['nombre']}',
                        textAlign: TextAlign.right,
                        style: AppTexto.subtitulo.copyWith(
                            color: AppColores.textoNaranja(context)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          _filaMetrica('Cobros', cols,
              (f) => '${f['cobros_n']} pagos'),
          _filaMetrica('Cobrado', cols,
              (f) => '${fmtMonto(f['cobros_monto'])} CUP',
              clave: 'cobros_monto'),
          _filaMetrica('Ventas', cols,
              (f) => '${f['ventas_n']} ventas'),
          _filaMetrica('Vendido (CUP)', cols,
              (f) => '${fmtMonto(f['ventas_cup'])} CUP',
              clave: 'ventas_cup'),
          if (hayUsd)
            _filaMetrica('Vendido (USD)', cols,
                (f) => '${fmtMonto(f['ventas_usd'])} USD',
                clave: 'ventas_usd'),
          _filaMetrica('Dosis y servicios', cols,
              (f) => '${f['dosis_n']}'),
          _filaMetrica('En dosis', cols,
              (f) => '${fmtMonto(f['dosis_monto'])} CUP',
              clave: 'dosis_monto'),
          _filaMetrica('Inscripciones', cols,
              (f) => '${f['inscripciones']}'),
          const Divider(height: 1),
          _filaMetrica('Total movido', cols,
              (f) => '${fmtMonto(f['total_cup'])} CUP',
              clave: 'total_cup', destacada: true),
        ],
      ),
    );
  }

  /// Una fila de la tabla: etiqueta a la izquierda y un
  /// valor por entrenador; el mayor de la fila (con clave
  /// numérica) va en negrita.
  Widget _filaMetrica(
    String etiqueta,
    List<Map<String, dynamic>> cols,
    String Function(Map<String, dynamic>) texto, {
    String? clave,
    bool destacada = false,
  }) {
    num? mayor;
    if (clave != null) {
      for (final f in cols) {
        final v = (f[clave] as num?) ?? 0;
        if (mayor == null || v > mayor) mayor = v;
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppEspacio.sm),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(etiqueta,
                style: destacada
                    ? AppTexto.cuerpo
                        .copyWith(fontWeight: FontWeight.bold)
                    : AppTexto.cuerpo),
          ),
          for (final f in cols)
            Expanded(
              flex: 2,
              child: Text(
                texto(f),
                textAlign: TextAlign.right,
                style: AppTexto.cuerpo.copyWith(
                  fontWeight: (clave != null &&
                          mayor != null &&
                          mayor > 0 &&
                          ((f[clave] as num?) ?? 0) == mayor)
                      ? FontWeight.bold
                      : destacada
                          ? FontWeight.bold
                          : FontWeight.normal,
                  fontFeatures: const [
                    FontFeature.tabularFigures()
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
