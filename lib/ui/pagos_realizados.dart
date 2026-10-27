/// ✅ Pagos realizados del mes (v1.0.13).
/// Lista de clientes que pagaron este mes y tienen mensualidad válida.
library;

import 'package:flutter/material.dart';
import 'dart:io';

import '../auth.dart';
import '../fotos.dart';
import '../localdb.dart';
import '../negocio.dart';
import '../permisos_entrenador.dart';
import '../permisos_visibilidad.dart';
import '../sync.dart';
import '../cliente_protegido.dart';
import 'componentes.dart';
import 'diseno.dart';
import 'ficha.dart';
import 'widgets.dart';

class PagosRealizadosScreen extends StatefulWidget {
  const PagosRealizadosScreen({super.key});

  @override
  State<PagosRealizadosScreen> createState() =>
      _PagosRealizadosScreenState();
}

/// v1.2.8 (Paso 4/E2): avatar con miniatura de foto.
/// Corrección Gemini: StatefulWidget dedicado en vez de FutureBuilder
/// directo en el itemBuilder (evita recrear futures en cada scroll).
class ClienteAvatarThumb extends StatefulWidget {
  final String? fotoStorage;
  final String? fotoLocal;
  const ClienteAvatarThumb({super.key, this.fotoStorage, this.fotoLocal});

  @override
  State<ClienteAvatarThumb> createState() => _ClienteAvatarThumbState();
}

class _ClienteAvatarThumbState extends State<ClienteAvatarThumb> {
  File? _archivo;

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  @override
  void didUpdateWidget(ClienteAvatarThumb old) {
    super.didUpdateWidget(old);
    if (old.fotoStorage != widget.fotoStorage ||
        old.fotoLocal != widget.fotoLocal) {
      // Corrección Gemini ronda 2: resetear antes de cargar para no
      // mostrar la foto del cliente anterior durante el I/O.
      setState(() => _archivo = null);
      _cargar();
    }
  }

  Future<void> _cargar() async {
    File? f;
    if (widget.fotoLocal != null && widget.fotoLocal!.isNotEmpty) {
      final lf = File(widget.fotoLocal!);
      if (await lf.exists()) f = lf;
    }
    f ??= await FotoCache.instance.enCache(widget.fotoStorage);
    if (mounted) setState(() => _archivo = f);
  }

  @override
  Widget build(BuildContext context) {
    if (_archivo != null) {
      return CircleAvatar(
        backgroundImage: FileImage(_archivo!),
        backgroundColor: Colors.transparent,
      );
    }
    return const Icon(Icons.verified, color: AppColores.exito);
  }
}

class _PagosRealizadosScreenState extends State<PagosRealizadosScreen> {
  bool _cargando = true;
  List<Map<String, dynamic>> _clientes = [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  /// v1.4.4: el ⟳ de esta pantalla ahora SÍ sincroniza (antes solo
  /// releía la BD local, a diferencia del de Buscar cliente, y los
  /// pagos bajados en otro dispositivo no aparecían). Sincroniza
  /// con el alcance de la pantalla y luego recarga la lista.
  Future<void> _actualizar() async {
    try {
      await SyncEngine.instance.sincronizarScope('pagos');
      await _cargar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Lista actualizada')));
    } catch (_) {
      await _cargar();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Sin conexión: mostrando datos locales')));
    }
  }

  Future<void> _cargar() async {
    final n = DateTime.now();
    final pref = '${n.year.toString().padLeft(4, '0')}-'
        '${n.month.toString().padLeft(2, '0')}';

    // Clientes con pago este mes
    // v1.3.4 (ítem 2): columna `fecha` indexada en vez de allMirror.
    var pagos = await LocalDb.instance.pagosDelMes(pref);
    // Permisos 2+3 (candado de UI): sin can_ver_todos_pagos el
    // entrenador solo ve SUS cobros (por telegram_user_id,
    // antes de agrupar por cliente: si no, un cliente cuyo
    // último pago es de otro desaparecía aunque tenga uno suyo).
    final permisos = PermisosEntrenador();
    if (!pagosSinRestriccion(
      esDueno: AuthService().isOwner,
      permisosCargados: permisos.cargado,
      canVerTodosPagos: permisos.canVerTodosPagos,
    )) {
      pagos = filtrarPagosPorEntrenador(pagos, AuthService().telegramId);
    }
    final porCliente = <int, Map<String, dynamic>>{};
    for (final p in pagos) {
      final cid = p['cliente_id'] as int?;
      if (cid == null) continue;
      // Quedarse con el pago más reciente por cliente
      final actual = porCliente[cid];
      if (actual == null ||
          '${p['fecha']}' .compareTo('${actual['fecha']}') > 0) {
        porCliente[cid] = p;
      }
    }

    // Datos de clientes
    final todos = await LocalDb.instance.allMirror('clientes');
    final porId = <int, Map<String, dynamic>>{
      for (final c in todos) (c['id'] as int): c,
    };

    final lista = <Map<String, dynamic>>[];
    for (final cid in porCliente.keys) {
      final c = porId[cid];
      if (c == null) continue;
      // Cliente protegido (2026-10-26, Protegido 2 H3): la fila
      // se omite entera para un no-dueño (la pantalla se titula
      // «clientes que pagaron este mes»: la presencia ya revela
      // el estado de pago).
      if (esVistaProtegida(c)) continue;
      final pago = porCliente[cid]!;
      lista.add({
        'id': cid,
        'nombre': c['nombre'] ?? 'Cliente $cid',
        'monto': pago['monto'],
        'metodo': pago['metodo'] ?? 'efectivo',
        // v1.4.6: quién cobró ese pago (mismo formato que la ficha).
        'registrado_por': pago['registrado_por'],
        'fecha': pago['fecha'],
        'pagado_hasta': c['pagado_hasta'],
        'foto_local': c['foto_local'],
        // v1.3.6 (Jc): miniaturas en lugar del check verde. enCache solo
        // lee disco/memoria (no descarga), así que no hay tormenta de red.
        'foto_storage': c['foto_storage'],
        // Cliente protegido (2026-10-26, A5): la fila muestra el
        // candado junto al nombre cuando el cliente lo está.
        'protegido': c['protegido'],
      });
    }
    // Ordenar por fecha de pago (más reciente primero)
    lista.sort((a, b) =>
        '${b['fecha']}'.compareTo('${a['fecha']}'));

    if (mounted) {
      setState(() {
        _clientes = lista;
        _cargando = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final n = DateTime.now();
    const meses = [
      '', 'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
      'julio', 'agosto', 'septiembre', 'octubre', 'noviembre',
      'diciembre'
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pagos realizados'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualizar (bajar cambios)',
            onPressed: _actualizar,
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(alcance: 'pagos'),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              '${_clientes.length} clientes pagaron en '
              '${meses[n.month]} ${n.year}',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: _cargando
                ? const Center(child: CircularProgressIndicator())
                : _clientes.isEmpty
                    ? const EstadoVacio(
                        icono: Icons.payments,
                        titulo: 'Sin pagos este mes',
                        subtitulo:
                            'Los pagos registrados aparecerán aquí')
                    : RefreshIndicator(
                        onRefresh: _actualizar,
                        child: ListView.builder(
                          itemCount: _clientes.length,
                          itemBuilder: (ctx, i) {
                            final c = _clientes[i];
                            return ListTile(
                              leading: ClienteAvatarThumb(
                                fotoLocal: c['foto_local'] as String?,
                                fotoStorage:
                                    c['foto_storage'] as String?,
                              ),
                              title: Text('${c['nombre']}'),
                              subtitle: Text(
                                '${fmtMonto(c['monto'])} CUP · '
                                '${c['metodo']} · '
                                '${fmtFecha(c['fecha'] as String?)}\n'
                                '${textoCobradoPor(c['registrado_por'])}',
                                style:
                                    const TextStyle(fontSize: 12),
                              ),
                              // Cliente protegido (2026-10-26,
                              // A5): candado en vez de chevron. El
                              // tap sigue abriendo la ficha
                              // bloqueada (foto + nombre).
                              trailing: esVistaProtegida(c)
                                  ? const Icon(Icons.lock,
                                      color: AppColores.naranja)
                                  : const Icon(
                                      Icons.chevron_right),
                              onTap: () => Navigator.of(context)
                                  .push(MaterialPageRoute(
                                builder: (_) => FichaScreen(
                                    clienteId: c['id'] as int),
                              )).then((_) => _cargar()),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }
}
