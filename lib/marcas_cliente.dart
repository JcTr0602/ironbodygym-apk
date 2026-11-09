/// 1.30 (§14 · Marcas verificadas): las marcas personales
/// que el cliente registra en su app de Clientes, con el
/// sello de verificación del personal.
///
/// Dónde viven: en Supabase, tabla `public.sync_marcas`
/// (las crea la app de Clientes por las RPC
/// `registrar_marca_cliente` / `actualizar_marca_cliente`);
/// NO viven en el espejo local de Gestión ni viajan por
/// sync_ops: se leen y se verifican en línea por las RPC
/// `admin_marcas_cliente` / `admin_verificar_marca`, con
/// guarda de personal en el servidor (`es_staff()`: dueño
/// y entrenadores). El estado de verificación son las
/// columnas `verificada_*` de la misma fila: toda marca
/// nace «Sin verificar» y editarla en la app le retira el
/// aval (el aval era sobre el valor anterior).
///
/// Sin caché a propósito: la lista es pequeña (tope 200
/// en el servidor) y la pantalla se abre a demanda desde
/// la ficha; la honestidad manda — sin conexión se dice y
/// no se inventa una copia vieja (error ≠ vacío).
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Una marca personal tal como la devuelve el servidor,
/// con su estado de verificación.
class MarcaServidor {
  final int id;
  final int ejercicioId;
  final String? ejercicioNombre;
  final double peso;
  final String fecha; // 'aaaa-mm-dd'
  final bool verificada;
  final String? verificadaPor;
  final String? verificadaRol; // 'dueno' | 'entrenador'
  final DateTime? verificadaEn;

  const MarcaServidor({
    required this.id,
    required this.ejercicioId,
    required this.ejercicioNombre,
    required this.peso,
    required this.fecha,
    required this.verificada,
    required this.verificadaPor,
    required this.verificadaRol,
    required this.verificadaEn,
  });

  factory MarcaServidor.desdeRpc(Map<String, dynamic> f) {
    return MarcaServidor(
      id: (f['id'] as num?)?.toInt() ?? 0,
      ejercicioId: (f['ejercicio_id'] as num?)?.toInt() ?? 0,
      ejercicioNombre: f['ejercicio_nombre'] as String?,
      peso: (f['peso'] as num?)?.toDouble() ?? 0,
      fecha: '${f['fecha'] ?? ''}',
      verificada: f['verificada'] == true,
      verificadaPor: f['verificada_por'] as String?,
      verificadaRol: f['verificada_rol'] as String?,
      verificadaEn: DateTime.tryParse('${f['verificada_en'] ?? ''}'),
    );
  }
}

/// El sello de estado de una marca, tal como se lee en la
/// ficha (y como la app de Clientes lo pintará en la 0.5
/// con estas mismas palabras): «Sin verificar» ·
/// «Verificada por el dueño» · «Verificada por <nombre>».
String textoSelloMarca(MarcaServidor m) {
  if (!m.verificada) return 'Sin verificar';
  if (m.verificadaRol == 'dueno') return 'Verificada por el dueño';
  final nombre = (m.verificadaPor ?? '').trim();
  return nombre.isEmpty
      ? 'Verificada por un entrenador'
      : 'Verificada por $nombre';
}

/// El peso de una marca en kg, con la coma decimal de la
/// casa y sin decimales cuando es entero («100 kg»,
/// «102,5 kg»).
String fmtPesoKg(double peso) {
  if (peso == peso.roundToDouble()) return '${peso.toInt()} kg';
  return '${peso.toStringAsFixed(1).replaceAll('.', ',')} kg';
}

/// Lee y verifica las marcas de un cliente contra el
/// servidor. [rpcParaTest] es la costura de los tests (el
/// patrón de `ActividadClienteService`): recibe el nombre
/// de la RPC y sus parámetros y devuelve la respuesta
/// cruda. Toda llamada lleva el timeout de escritura de
/// la casa (12 s) y toda respuesta malformada es un error,
/// nunca una lista vacía inventada.
class MarcasClienteService {
  final Future<Object?> Function(
      String rpc, Map<String, dynamic> params)? _rpcParaTest;

  MarcasClienteService({
    Future<Object?> Function(String rpc, Map<String, dynamic> params)?
        rpcParaTest,
  }) : _rpcParaTest = rpcParaTest;

  Future<Object?> _rpc(String nombre, Map<String, dynamic> params) async {
    final paraTest = _rpcParaTest;
    if (paraTest != null) return paraTest(nombre, params);
    return Supabase.instance.client
        .rpc(nombre, params: params)
        .timeout(const Duration(seconds: 12));
  }

  /// Las marcas del cliente [clienteId], de la más
  /// reciente a la más antigua (el orden lo fija el
  /// servidor: fecha DESC, id DESC; tope 200).
  Future<List<MarcaServidor>> consultar(int clienteId) async {
    final res = await _rpc('admin_marcas_cliente', {
      'p_cliente_id': clienteId,
    });
    if (res is! Map) {
      throw StateError('Respuesta inesperada del servidor (marcas).');
    }
    final crudas = res['marcas'];
    if (crudas is! List) {
      throw StateError('Respuesta inesperada del servidor (marcas).');
    }
    return [
      for (final f in crudas)
        if (f is Map)
          MarcaServidor.desdeRpc(Map<String, dynamic>.from(f)),
    ];
  }

  /// Verifica la marca [marcaId]: el servidor registra
  /// quién (el usuario conectado) y cuándo. La primera
  /// verificación manda: si otro del personal la verificó
  /// mientras tanto, la respuesta trae SU aval con
  /// `yaVerificada` en true y nada se pisa.
  Future<({MarcaServidor marca, bool yaVerificada})> verificar(
      int marcaId) async {
    final res = await _rpc('admin_verificar_marca', {
      'p_marca_id': marcaId,
    });
    if (res is! Map) {
      throw StateError('Respuesta inesperada del servidor (verificar).');
    }
    final cruda = res['marca'];
    if (cruda is! Map) {
      throw StateError('Respuesta inesperada del servidor (verificar).');
    }
    return (
      marca: MarcaServidor.desdeRpc(Map<String, dynamic>.from(cruda)),
      yaVerificada: res['ya_verificada'] == true,
    );
  }
}
