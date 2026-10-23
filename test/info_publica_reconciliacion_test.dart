/// Reconciliación de info pública contra el ajuste local
/// (delta del panel): cierra la inversión de orden EN EL
/// SERVIDOR entre isolates, que ninguna marca local puede
/// impedir — la RPC lenta del isolate de fondo (valor viejo)
/// completa DESPUÉS de la rápida de la app (valor nuevo) y el
/// público queda en el valor viejo, sin marcas pendientes en
/// ningún sitio.
///
/// La verdad de referencia es el AJUSTE LOCAL, no la marca: en
/// el paso de fin de sync se lee el valor público actual y, si
/// difiere del ajuste, se (re)marca la fila pendiente con el
/// valor local y se republica. Cualquier inversión se
/// autocorrige en la siguiente sync como muy tarde. Si la
/// lectura pública falla, no pasa nada: se reintenta en la
/// siguiente sync y la reconciliación nunca lanza.
///
/// Sin red real: servidor falso en memoria + RPC inyectada, y
/// la BD local real (FFI), patrón de la casa.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/invitados.dart';
import 'package:ironbody_gym/localdb.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _abrirDbVacia() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  final dir = await getDatabasesPath();
  final dbPath = p.join(dir, 'ironbody.db');
  try {
    await File(dbPath).delete();
  } catch (_) {}
  await LocalDb.resetParaTest();
  return await LocalDb.instance.db;
}

/// El "servidor" de info pública en memoria: lo que la RPC
/// `info_publica_listar` devolvería y lo que
/// `info_publica_guardar` escribe.
class _ServidorFalso {
  final Map<String, String> publico = {};
  final List<String> llamadasGuardar = [];
  bool fallarListar = false;

  Future<dynamic> rpc(String nombre, Map<String, dynamic>? params) async {
    switch (nombre) {
      case 'info_publica_listar':
        if (fallarListar) throw Exception('sin red (test)');
        return <String, dynamic>{
          'info_publica': Map<String, String>.of(publico),
        };
      case 'info_publica_guardar':
        final clave = '${params?['p_clave']}';
        final valor = '${params?['p_valor']}';
        llamadasGuardar.add('$clave=$valor');
        publico[clave] = valor;
        return <String, dynamic>{};
      default:
        return null;
    }
  }
}

/// RPC del isolate de fondo para el escenario de inversión:
/// su `info_publica_guardar` queda retenido en una puerta
/// (RPC lenta) y solo escribe en el servidor al abrirse.
class _RpcLenta {
  _RpcLenta(this.servidor);

  final _ServidorFalso servidor;
  final Completer<void> _enVuelo = Completer<void>();
  final Completer<void> _puerta = Completer<void>();

  Future<void> get enVuelo => _enVuelo.future;
  void abrir() => _puerta.complete();

  Future<dynamic> rpc(String nombre, Map<String, dynamic>? params) async {
    if (nombre == 'info_publica_guardar') {
      if (!_enVuelo.isCompleted) _enVuelo.complete();
      await _puerta.future;
    }
    return servidor.rpc(nombre, params);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ajustesComoInfoPublica / derivaInfoPublica (puros)', () {
    test('el ajuste numérico se normaliza a su forma publicada',
        () {
      expect(ajustesComoInfoPublica({'precio_app_plus': 1500}),
          {'precio_app_plus': '1500'});
      expect(ajustesComoInfoPublica({'precio_app_plus': 1500.0}),
          {'precio_app_plus': '1500'});
      expect(ajustesComoInfoPublica({'precio_app_plus': ' 1500 '}),
          {'precio_app_plus': '1500'});
    });

    test('sin ajuste local no hay verdad que imponer; las '
        'demás claves no entran', () {
      expect(ajustesComoInfoPublica({}), isEmpty);
      expect(ajustesComoInfoPublica({'mensualidad': 2000}), isEmpty);
      expect(
          ajustesComoInfoPublica({'precio_app_plus': null}), isEmpty);
    });

    test('deriva: solo difieren (o faltan en lo público)', () {
      expect(
        derivaInfoPublica(
          locales: {'precio_app_plus': '1500'},
          publicos: {'precio_app_plus': '1500'},
        ),
        isEmpty,
      );
      expect(
        derivaInfoPublica(
          locales: {'precio_app_plus': '1500'},
          publicos: {'precio_app_plus': '1200'},
        ),
        {'precio_app_plus': '1500'},
      );
      expect(
        derivaInfoPublica(
          locales: {'precio_app_plus': '1500'},
          publicos: const {},
        ),
        {'precio_app_plus': '1500'},
      );
    });
  });

  group('reconciliación de fin de sync', () {
    test('(a) inversión entre isolates: el público quedó en el '
        'valor viejo sin marcas, y la siguiente pasada lo '
        'autocorrige al valor del ajuste local', () async {
      final db = await _abrirDbVacia();
      // El dueño fijó el precio en 1500 (ajuste local = verdad).
      await LocalDb.instance.setAjustes({'precio_app_plus': 1500});
      final servidor = _ServidorFalso();

      // — Isolate de fondo: republica el 1200 marcado, con su
      // RPC retenida (lenta).
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1200');
      final rpcFondo = _RpcLenta(servidor);
      final fondo = InvitadosService(rpc: rpcFondo.rpc);
      final fFondo = fondo.republicarInfoPublicaPendiente();
      await rpcFondo.enVuelo.timeout(const Duration(seconds: 10));

      // — Isolate de la app: guarda el 1500 y su RPC completa
      // PRIMERO. Entre isolates no hay cadena compartida: se
      // reproducen sus pasos atómicos (marcar, publicar, limpiar
      // condicional).
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1500');
      servidor.publico['precio_app_plus'] = '1500';
      await LocalDb.instance
          .limpiarInfoPublicaPendiente('precio_app_plus', '1500');

      // — La RPC lenta del fondo completa DESPUÉS: pisa el
      // servidor con el 1200. Su limpieza condicional no borra
      // nada (la fila ya no existe). Inversión consumada.
      rpcFondo.abrir();
      await fFondo;
      expect(servidor.publico['precio_app_plus'], '1200');
      expect(await LocalDb.instance.infoPublicaPendientes(),
          isEmpty);

      // — Siguiente fin de sync: la reconciliación detecta
      // público(1200) ≠ local(1500), republica el 1500 y el
      // público final es el del ajuste.
      servidor.llamadasGuardar.clear();
      final svc = InvitadosService(rpc: servidor.rpc);
      await svc.republicarYReconciliarInfoPublica();
      expect(servidor.publico['precio_app_plus'], '1500');
      expect(servidor.llamadasGuardar, ['precio_app_plus=1500']);
      expect(await LocalDb.instance.infoPublicaPendientes(),
          isEmpty);
      await db.close();
    });

    test('(b) público == local: la reconciliación no publica '
        'nada (sin RPC de guardado extra)', () async {
      final db = await _abrirDbVacia();
      await LocalDb.instance.setAjustes({'precio_app_plus': 1500});
      final servidor = _ServidorFalso();
      servidor.publico['precio_app_plus'] = '1500';

      final svc = InvitadosService(rpc: servidor.rpc);
      await svc.republicarYReconciliarInfoPublica();

      expect(servidor.llamadasGuardar, isEmpty);
      expect(await LocalDb.instance.infoPublicaPendientes(),
          isEmpty);
      await db.close();
    });

    test('(c) la lectura pública falla: no lanza, no marca '
        'nada nuevo y la republicación de pendientes sigue',
        () async {
      final db = await _abrirDbVacia();
      await LocalDb.instance.setAjustes({'precio_app_plus': 1500});
      final servidor = _ServidorFalso()..fallarListar = true;
      await LocalDb.instance
          .marcarInfoPublicaPendiente('precio_app_plus', '1500');

      final svc = InvitadosService(rpc: servidor.rpc);
      await svc.republicarYReconciliarInfoPublica();

      // Lo pendiente se publicó por la vía de siempre pese a
      // que la reconciliación no pudo leer.
      expect(servidor.llamadasGuardar, ['precio_app_plus=1500']);
      expect(servidor.publico['precio_app_plus'], '1500');
      expect(await LocalDb.instance.infoPublicaPendientes(),
          isEmpty);
      await db.close();
    });
  });
}
