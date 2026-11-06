import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../comunidad_panel.dart';
import 'app_bar.dart';

/// 1.27 (Comunidad MVP, Pieza G): «Comunidad» del
/// Panel — los perfiles que los clientes han hecho
/// visibles y el botón de ocultarlos.
///
/// El cliente manda sobre sus datos: esta pantalla NO
/// puede encender la vitrina de nadie ni ver lo que el
/// cliente apagó (eso ni siquiera sale del servidor);
/// solo puede OCULTAR un perfil del directorio (p. ej.
/// un nombre inadecuado) y deshacer esa ocultación.
/// La RPC admin_comunidad_ocultar valida es_admin en
/// el servidor (la tarjeta solo vive en el Panel del
/// dueño, como la de Premios, cuya compuerta visual
/// está en el hub). Cargadores inyectables para los
/// tests.
class ComunidadPanelScreen extends StatefulWidget {
  final Future<Map<String, dynamic>> Function()? cargarPerfiles;
  final Future<Map<String, dynamic>> Function(
      int clienteId, bool ocultar)? ocultarPerfil;

  const ComunidadPanelScreen(
      {super.key, this.cargarPerfiles, this.ocultarPerfil});

  @override
  State<ComunidadPanelScreen> createState() =>
      _ComunidadPanelScreenState();
}

class _ComunidadPanelScreenState extends State<ComunidadPanelScreen> {
  bool _cargando = true;
  bool _falloCarga = false;
  bool _resolviendo = false;
  List<PerfilComunidadAdmin> _perfiles = const [];

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<Map<String, dynamic>> _cargarReal() async {
    final res = await Supabase.instance.client
        .rpc('admin_comunidad_perfiles')
        .timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<Map<String, dynamic>> _ocultarReal(
      int clienteId, bool ocultar) async {
    final res = await Supabase.instance.client.rpc(
      'admin_comunidad_ocultar',
      params: {'p_cliente_id': clienteId, 'p_ocultar': ocultar},
    ).timeout(const Duration(seconds: 12));
    if (res is Map) return Map<String, dynamic>.from(res);
    return {};
  }

  Future<void> _cargar() async {
    setState(() {
      _cargando = true;
      _falloCarga = false;
    });
    try {
      final json = await (widget.cargarPerfiles ?? _cargarReal)();
      if (!mounted) return;
      setState(() {
        _perfiles = parsePerfilesComunidad(json);
        _cargando = false;
        _falloCarga = json.isNotEmpty && json['ok'] != true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _cargando = false;
          _falloCarga = true;
        });
      }
    }
  }

  Future<void> _alternarOculto(PerfilComunidadAdmin p) async {
    final nuevo = !p.ocultoAdmin;
    setState(() => _resolviendo = true);
    try {
      final res = await (widget.ocultarPerfil ?? _ocultarReal)(
          p.clienteId, nuevo);
      if (!mounted) return;
      if (res['ok'] == true) {
        setState(() {
          _perfiles = [
            for (final x in _perfiles)
              if (x.clienteId == p.clienteId) x.conOculto(nuevo) else x,
          ];
          _resolviendo = false;
        });
      } else {
        setState(() => _resolviendo = false);
        _avisar('El servidor no aplicó el cambio. '
            'Inténtalo de nuevo.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _resolviendo = false);
        _avisar('Sin conexión no se pudo cambiar. '
            'Inténtalo de nuevo.');
      }
    }
  }

  void _avisar(String texto) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(texto)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBarIron(context, 'Comunidad'),
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _falloCarga
              ? _mensaje(
                  'No se pudieron cargar los perfiles. '
                  'Revisa la conexión e inténtalo de nuevo.',
                  reintento: true)
              : _perfiles.isEmpty
                  ? _mensaje('Ningún cliente ha creado su '
                      'vitrina todavía. Cuando alguien la '
                      'encienda en su app, aparecerá aquí.')
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: _perfiles.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return const Padding(
                            padding: EdgeInsets.only(bottom: 12),
                            child: Text(
                              'El cliente manda sobre sus datos: '
                              'desde aquí solo puedes ocultar un '
                              'perfil del directorio (y deshacerlo). '
                              'Lo que cada cliente apagó no se ve '
                              'ni aquí.',
                              style: TextStyle(
                                  fontSize: 13, height: 1.4),
                            ),
                          );
                        }
                        return _tarjeta(_perfiles[i - 1]);
                      },
                    ),
    );
  }

  Widget _mensaje(String texto, {bool reintento = false}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(texto,
                textAlign: TextAlign.center,
                style: const TextStyle(height: 1.4)),
            if (reintento) ...[
              const SizedBox(height: 14),
              FilledButton(
                  onPressed: _cargar, child: const Text('Reintentar')),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tarjeta(PerfilComunidadAdmin p) {
    final estado = p.ocultoAdmin
        ? 'Oculto por administración'
        : p.visible
            ? 'Visible en el directorio'
            : 'Vitrina apagada (no aparece)';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        title: Text(p.nombre,
            style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Text(
          '$estado'
          '${p.bloquesActivos.isEmpty ? '' : '\nComparte: ${p.bloquesActivos.join(', ')}'}',
        ),
        trailing: TextButton(
          onPressed:
              _resolviendo ? null : () => _alternarOculto(p),
          child: Text(p.ocultoAdmin ? 'Mostrar' : 'Ocultar'),
        ),
      ),
    );
  }
}
