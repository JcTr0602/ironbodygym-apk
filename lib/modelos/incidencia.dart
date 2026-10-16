import 'package:flutter/material.dart';

import '../tiempo.dart';

/// Tipo personalizado de incidencia.
/// Revisado por Gemini 2026-10-13.
class TipoIncidencia {
  final String id;
  final String nombre;
  final String? icono;
  final int? color;
  final bool activo;
  final int orden;
  final String? plantillaDescripcion;

  const TipoIncidencia({
    required this.id,
    required this.nombre,
    this.icono,
    this.color,
    this.activo = true,
    this.orden = 0,
    this.plantillaDescripcion,
  });

  factory TipoIncidencia.fromMap(Map<String, dynamic> m) {
    return TipoIncidencia(
      id: '${m['id']}',
      nombre: '${m['nombre'] ?? ''}',
      icono: m['icono'] as String?,
      color: (m['color'] as num?)?.toInt(),
      activo: (m['activo'] as num?)?.toInt() == 1,
      orden: (m['orden'] as num?)?.toInt() ?? 0,
      plantillaDescripcion: m['plantilla_descripcion'] as String?,
    );
  }

  /// Serialización para SQLite y sync_ops.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'nombre': nombre,
      'icono': icono,
      'color': color,
      'activo': activo ? 1 : 0,
      'orden': orden,
      'plantilla_descripcion': plantillaDescripcion,
    };
  }

  /// Resuelve el nombre del icono a IconData.
  IconData get iconoData {
    switch (icono) {
      case 'fitness_center':
        return Icons.fitness_center;
      case 'build':
        return Icons.build;
      case 'cleaning_services':
        return Icons.cleaning_services;
      case 'report':
        return Icons.report;
      case 'electrical_services':
        return Icons.electrical_services;
      case 'water_drop':
        return Icons.water_drop;
      default:
        return Icons.label;
    }
  }

  Color get colorData =>
      color != null ? Color(color!) : Colors.grey;
}

/// Incidencia.
/// Revisado por Gemini 2026-10-13.
class Incidencia {
  final String id;
  final String? tipoId;
  final String descripcion;
  final String? detalle;
  final String estado; // pendiente, en_proceso, bloqueada, resuelta
  final String? asignadoA;
  final String prioridad; // alta, media, baja
  final DateTime? fechaLimite;
  final String? ubicacion;
  final String creadaPor;
  // Fix #24 (Sol): nullable para no inventar fechas.
  final DateTime? creadaEn;
  // Resolución
  final String? resueltaPor;
  final DateTime? resueltaEn;
  final String? notaResolucion;
  // Control de concurrencia y sync
  final int version;
  final String syncEstado;
  final DateTime? actualizadoEn;

  const Incidencia({
    required this.id,
    this.tipoId,
    required this.descripcion,
    this.detalle,
    this.estado = 'pendiente',
    this.asignadoA,
    this.prioridad = 'media',
    this.fechaLimite,
    this.ubicacion,
    required this.creadaPor,
    required this.creadaEn,
    this.resueltaPor,
    this.resueltaEn,
    this.notaResolucion,
    this.version = 1,
    this.syncEstado = 'synced',
    this.actualizadoEn,
  });

  factory Incidencia.fromMap(Map<String, dynamic> m) {
    DateTime? _dt(dynamic v) {
      if (v == null) return null;
      if (v is DateTime) return v;
      try {
        return DateTime.parse('$v');
      } catch (_) {
        return null;
      }
    }

    return Incidencia(
      id: '${m['id']}',
      tipoId: m['tipo_id'] as String?,
      descripcion: '${m['descripcion'] ?? ''}',
      detalle: m['detalle'] as String?,
      estado: '${m['estado'] ?? 'pendiente'}',
      asignadoA: m['asignado_a'] as String?,
      prioridad: '${m['prioridad'] ?? 'media'}',
      fechaLimite: _dt(m['fecha_limite']),
      ubicacion: m['ubicacion'] as String?,
      creadaPor: '${m['creada_por'] ?? ''}',
      // Fix #24: null si inválida, no DateTime.now().
      creadaEn: _dt(m['creada_en']),
      resueltaPor: m['resuelta_por'] as String?,
      resueltaEn: _dt(m['resuelta_en']),
      notaResolucion:
          m['nota_resolucion'] as String?,
      version: (m['version'] as num?)?.toInt() ?? 1,
      syncEstado: '${m['sync_estado'] ?? 'synced'}',
      actualizadoEn: _dt(m['actualizado_en']),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'tipo_id': tipoId,
      'descripcion': descripcion,
      'detalle': detalle,
      'estado': estado,
      'asignado_a': asignadoA,
      'prioridad': prioridad,
      'fecha_limite': fechaLimite?.toIso8601String(),
      'ubicacion': ubicacion,
      'creada_por': creadaPor,
      'creada_en': creadaEn?.toIso8601String(),
      'resuelta_por': resueltaPor,
      'resuelta_en': resueltaEn?.toIso8601String(),
      'nota_resolucion': notaResolucion,
      'version': version,
      'sync_estado': syncEstado,
      'actualizado_en':
          actualizadoEn?.toIso8601String(),
    };
  }

  /// Días abierta (congelado si está resuelta).
  /// Corrección Gemini: no sigue contando tras resolver.
  int get diasAbierta {
    // Fix #24: si creadaEn es null (fecha inválida), retornar 0.
    final inicio = creadaEn;
    if (inicio == null) return 0;
    final fin = (estado == 'resuelta' &&
            resueltaEn != null)
        ? resueltaEn!
        // v1.3.4: hora de La Habana, no la del dispositivo.
        : ahoraHabana();
    return fin.difference(inicio).inDays;
  }

  // v1.3.4: hora de La Habana, no la del dispositivo.
  bool get vencida =>
      fechaLimite != null &&
      ahoraHabana().isAfter(fechaLimite!) &&
      estado != 'resuelta';

  bool get estaResuelta => estado == 'resuelta';

  /// ¿Puede transicionar a este estado?
  /// Flujo Gemini: resolución directa, reapertura, bloqueo bidireccional.
  bool puedeTransicionarA(String nuevo) {
    switch (estado) {
      case 'pendiente':
        return nuevo == 'en_proceso' ||
            nuevo == 'bloqueada' ||
            nuevo == 'resuelta'; // resolución directa
      case 'en_proceso':
        return nuevo == 'bloqueada' ||
            nuevo == 'resuelta' ||
            nuevo == 'pendiente';
      case 'bloqueada':
        return nuevo == 'en_proceso' ||
            nuevo == 'pendiente';
      case 'resuelta':
        return nuevo ==
            'en_proceso'; // reapertura (solo dueño)
      default:
        return false;
    }
  }
}

/// Foto de incidencia (offline-first).
class IncidenciaFoto {
  final String id;
  final String incidenciaId;
  final String localPath;
  final String? storagePath;
  final String tipo; // evidencia | resolucion
  final String syncEstado; // pending | uploading | synced | error
  final DateTime creadoEn;

  const IncidenciaFoto({
    required this.id,
    required this.incidenciaId,
    required this.localPath,
    this.storagePath,
    this.tipo = 'evidencia',
    this.syncEstado = 'pending',
    required this.creadoEn,
  });

  factory IncidenciaFoto.fromMap(
      Map<String, dynamic> m) {
    return IncidenciaFoto(
      id: '${m['id']}',
      incidenciaId: '${m['incidencia_id']}',
      localPath: '${m['local_path']}',
      storagePath: m['storage_path'] as String?,
      tipo: '${m['tipo'] ?? 'evidencia'}',
      syncEstado: '${m['sync_estado'] ?? 'pending'}',
      creadoEn: DateTime.tryParse(
              '${m['creado_en']}') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'incidencia_id': incidenciaId,
      'local_path': localPath,
      'storage_path': storagePath,
      'tipo': tipo,
      'sync_estado': syncEstado,
      'creado_en': creadoEn.toIso8601String(),
    };
  }
}

/// Comentario de incidencia.
class IncidenciaComentario {
  final String id;
  final String incidenciaId;
  final String texto;
  final String creadoPor;
  final DateTime creadoEn;
  final String syncEstado;

  const IncidenciaComentario({
    required this.id,
    required this.incidenciaId,
    required this.texto,
    required this.creadoPor,
    required this.creadoEn,
    this.syncEstado = 'pending',
  });

  factory IncidenciaComentario.fromMap(
      Map<String, dynamic> m) {
    return IncidenciaComentario(
      id: '${m['id']}',
      incidenciaId: '${m['incidencia_id']}',
      texto: '${m['texto'] ?? ''}',
      creadoPor: '${m['creado_por'] ?? ''}',
      creadoEn: DateTime.tryParse(
              '${m['creado_en']}') ??
          DateTime.now(),
      syncEstado: '${m['sync_estado'] ?? 'pending'}',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'incidencia_id': incidenciaId,
      'texto': texto,
      'creado_por': creadoPor,
      'creado_en': creadoEn.toIso8601String(),
      'sync_estado': syncEstado,
    };
  }
}

/// Entrada del historial de cambios.
class IncidenciaHistorial {
  final String id;
  final String incidenciaId;
  final String campo;
  final String? valorAnterior;
  final String? valorNuevo;
  final String cambiadoPor;
  final DateTime cambiadoEn;

  const IncidenciaHistorial({
    required this.id,
    required this.incidenciaId,
    required this.campo,
    this.valorAnterior,
    this.valorNuevo,
    required this.cambiadoPor,
    required this.cambiadoEn,
  });

  factory IncidenciaHistorial.fromMap(
      Map<String, dynamic> m) {
    return IncidenciaHistorial(
      id: '${m['id']}',
      incidenciaId: '${m['incidencia_id']}',
      campo: '${m['campo']}',
      valorAnterior:
          m['valor_anterior'] as String?,
      valorNuevo: m['valor_nuevo'] as String?,
      cambiadoPor: '${m['cambiado_por']}',
      cambiadoEn: DateTime.tryParse(
              '${m['cambiado_en']}') ??
          DateTime.now(),
    );
  }
}
