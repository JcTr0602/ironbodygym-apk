/// 1.30 (§14 · Marcas verificadas): la pantalla de las
/// marcas personales que un cliente registra en su app,
/// abierta desde su ficha. Cada marca lleva su sello de
/// estado y, si está sin verificar, el botón «Verificar»:
/// el aval queda registrado en el servidor (quién y
/// cuándo) y la primera verificación manda.
///
/// La ficha ya pintó con su espejo local antes de llegar
/// aquí (offline-first intacto): esta pantalla es en línea
/// por naturaleza — las marcas viven en el servidor, no en
/// el espejo — y lo dice cuando no hay conexión; nunca
/// presenta un error como si no hubiera marcas.
library;

import 'package:flutter/material.dart';

import '../errores_sync.dart';
import '../marcas_cliente.dart';
import '../negocio.dart' show fmtFecha;
import 'app_bar.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'skeleton.dart';

class MarcasClienteScreen extends StatefulWidget {
  final int clienteId;
  final String nombreCliente;
  final MarcasClienteService? servicio;

  const MarcasClienteScreen({
    super.key,
    required this.clienteId,
    required this.nombreCliente,
    this.servicio,
  });

  @override
  State<MarcasClienteScreen> createState() => _MarcasClienteScreenState();
}

class _MarcasClienteScreenState extends State<MarcasClienteScreen> {
  late final MarcasClienteService _servicio =
      widget.servicio ?? MarcasClienteService();

  List<MarcaServidor> _marcas = const [];
  bool _cargando = true;
  bool _sinConexion = false;
  int _generacion = 0;
  final Set<int> _verificando = <int>{};

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final gen = ++_generacion;
    if (mounted) {
      setState(() {
        _cargando = true;
        _sinConexion = false;
      });
    }
    try {
      final marcas = await _servicio.consultar(widget.clienteId);
      if (!mounted || gen != _generacion) return;
      setState(() {
        _marcas = marcas;
        _cargando = false;
      });
    } catch (_) {
      if (!mounted || gen != _generacion) return;
      setState(() {
        _cargando = false;
        _sinConexion = true;
      });
    }
  }

  Future<void> _verificar(MarcaServidor m) async {
    // Guarda anti-doble-toque: un aval por toque.
    if (_verificando.contains(m.id)) return;
    setState(() => _verificando.add(m.id));
    try {
      final r = await _servicio.verificar(m.id);
      if (!mounted) return;
      setState(() {
        final i = _marcas.indexWhere((x) => x.id == m.id);
        if (i >= 0) _marcas[i] = r.marca;
      });
      if (r.yaVerificada) {
        // Otro del personal llegó primero: se pinta su
        // aval (vino en la respuesta) y se dice con su
        // nombre, sin tocarle las mayúsculas.
        final nombreAval = (r.marca.verificadaPor ?? '').trim();
        final quien = r.marca.verificadaRol == 'dueno'
            ? 'el dueño'
            : (nombreAval.isEmpty ? 'un entrenador' : nombreAval);
        mostrarSnack(context, 'Ya estaba verificada por $quien.');
      } else {
        mostrarSnack(context, 'Marca verificada.',
            significado: SignificadoChip.exito);
      }
    } catch (e) {
      if (mounted) {
        mostrarSnack(context,
            'No se pudo verificar la marca: ${mensajeErrorAmable(e)}',
            significado: SignificadoChip.error);
      }
    } finally {
      if (mounted) setState(() => _verificando.remove(m.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Marcas en la app'),
      body: ListView(
        padding: const EdgeInsets.all(AppEspacio.md),
        children: [
          Text(widget.nombreCliente, style: AppTexto.titulo),
          const SizedBox(height: AppEspacio.xs),
          const Text(
            'Las marcas que registra en su app de Clientes. '
            'Verificar una marca deja registrado quién la '
            'avaló y cuándo; editarla en la app le retira '
            'el aval.',
            style: AppTexto.secundario,
          ),
          const SizedBox(height: AppEspacio.md),
          if (_cargando)
            const SkeletonLista(items: 3)
          else if (_sinConexion) ...[
            const AvisoEstado(
              tipo: TipoAviso.error,
              texto: 'Sin conexión: las marcas viven en el '
                  'servidor y no en este teléfono, así que no '
                  'se pueden consultar ahora.',
            ),
            const SizedBox(height: AppEspacio.sm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _cargar,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Reintentar'),
              ),
            ),
          ] else if (_marcas.isEmpty)
            const EstadoVacio(
              icono: Icons.emoji_events_rounded,
              titulo: 'Sin marcas registradas',
              subtitulo: 'Este cliente aún no registra '
                  'marcas personales en su app.',
            )
          else
            for (final m in _marcas) _fila(m),
        ],
      ),
    );
  }

  Widget _fila(MarcaServidor m) {
    final verificando = _verificando.contains(m.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppEspacio.sm),
      child: Tarjeta(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    (m.ejercicioNombre ?? '').trim().isEmpty
                        ? 'Ejercicio'
                        : m.ejercicioNombre!,
                    style: AppTexto.subtitulo,
                  ),
                ),
                const SizedBox(width: AppEspacio.sm),
                Text(fmtPesoKg(m.peso),
                    style: AppTexto.titulo),
              ],
            ),
            const SizedBox(height: AppEspacio.xs),
            Text(fmtFecha(m.fecha), style: AppTexto.secundario),
            const SizedBox(height: AppEspacio.sm),
            Wrap(
              spacing: AppEspacio.sm,
              runSpacing: AppEspacio.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                ChipEstado.semantico(
                  significado: m.verificada
                      ? SignificadoChip.exito
                      : SignificadoChip.neutral,
                  texto: textoSelloMarca(m),
                  icono: m.verificada
                      ? Icons.verified_rounded
                      : Icons.hourglass_empty_rounded,
                ),
                if (!m.verificada)
                  TextButton.icon(
                    onPressed:
                        verificando ? null : () => _verificar(m),
                    icon: verificando
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_rounded,
                            size: 18),
                    label: Text(
                        verificando ? 'Verificando…' : 'Verificar'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
