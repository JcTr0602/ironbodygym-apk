/// Pantalla principal: acciones del entrenador.
library;

import 'package:flutter/material.dart';

import '../auth.dart';
import '../negocio.dart';
import '../sync.dart';
import '../theme.dart';
import 'buscar.dart';
import 'cola.dart';
import 'inscribir.dart';
import 'listas.dart';
import 'login.dart';
import 'pago.dart';
import 'pago_diario.dart';
import 'pendiente.dart';
import 'transferencia.dart';
import 'widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _vencen = 0;
  int _atras = 0;
  double _pendiente = 0;
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _cargar();
  }

  Future<void> _cargar() async {
    final v = await vencenHoy();
    final a = await atrasados(masDe30: false);
    final a30 = await atrasados(masDe30: true);
    final p = await pendienteEntrega(_auth.telegramId);
    if (mounted) {
      setState(() {
        _vencen = v.length;
        _atras = a.length + a30.length;
        _pendiente = p;
      });
    }
  }

  Future<void> _salir() async {
    await _auth.signOut();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  void _ir(Widget w) {
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => w))
        .then((_) => _cargar());
  }

  @override
  Widget build(BuildContext context) {
    final nombre = _auth.displayName;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.asset('assets/logo.jpg', height: 32),
            ),
            const SizedBox(width: 8),
            const Text('Iron Body Gym'),
          ],
        ),
        actions: [
          ValueListenableBuilder<ThemeMode>(
            valueListenable: ThemeController.mode,
            builder: (_, mode, __) => IconButton(
              tooltip: 'Modo oscuro / claro',
              icon: Icon(mode == ThemeMode.dark
                  ? Icons.light_mode
                  : Icons.dark_mode),
              onPressed: () => ThemeController.toggle(),
            ),
          ),
          IconButton(
              tooltip: 'Sincronizar ahora',
              icon: const Icon(Icons.sync),
              onPressed: () => SyncEngine.instance.run()),
          IconButton(
              tooltip: 'Salir',
              icon: const Icon(Icons.logout),
              onPressed: _salir),
        ],
      ),
      body: Column(
        children: [
          const SyncBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Hola, $nombre 👋',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Card(
              color: _pendiente > 0
                  ? Colors.orange.shade50
                  : Colors.green.shade50,
              child: ListTile(
                leading: Text(_pendiente > 0 ? '💰' : '✅',
                    style: const TextStyle(fontSize: 28)),
                title: Text(
                    'Pendiente a entregar: ${fmtMonto(_pendiente)} CUP',
                    style:
                        const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_pendiente > 0
                    ? 'Toca para ver el desglose'
                    : 'Nada pendiente'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _ir(const PendienteScreen()),
              ),
            ),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: 2,
              padding: const EdgeInsets.all(12),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              children: [
                _boton(context, '➕', 'Inscribir', 'Nuevo cliente',
                    () => _ir(const InscribirScreen())),
                _boton(context, '💰', 'Agregar Pago',
                    'Semanal · quincenal · mensual',
                    () => _ir(const PagoScreen())),
                _boton(context, '🔍', 'Buscar', null,
                    () => _ir(const BuscarScreen())),
                _boton(context, '📅', 'Vencen hoy ($_vencen)', null,
                    () => _ir(const ListasScreen())),
                _boton(context, '⏳', 'Atrasados ($_atras)', null,
                    () => _ir(const ListasScreen())),
                _boton(context, '🎫', 'Pago diario',
                    'Registro de Cantidad de Diarios',
                    () => _ir(const PagoDiarioScreen())),
                _boton(context, '💳', 'Transferencia', 'Ver transferencias',
                    () => _ir(const TransferenciaScreen())),
                _boton(context, '📤', 'Sincronización', null,
                    () => _ir(const ColaScreen())),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _boton(BuildContext context, String emoji, String texto,
      String? subtitulo, VoidCallback onTap) {
    return Card(
      elevation: 2,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(emoji, style: const TextStyle(fontSize: 36)),
              const SizedBox(height: 8),
              Text(texto,
                  style: const TextStyle(fontSize: 15),
                  textAlign: TextAlign.center),
              if (subtitulo != null) ...[
                const SizedBox(height: 2),
                Text(subtitulo,
                    style: const TextStyle(
                        fontSize: 11, color: Colors.grey),
                    textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
