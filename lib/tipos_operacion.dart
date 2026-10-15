import 'package:flutter/material.dart';

/// v1.2.9+46 (Gemini): centralización de tipos de operación.
/// Un solo mapa para nombres formales e iconos — la UI no duplica switches.
class TipoOperacionInfo {
  final String etiqueta;
  final IconData icono;
  const TipoOperacionInfo(this.etiqueta, this.icono);
}

const Map<String, TipoOperacionInfo> kTiposOperacion = {
  'inscribir': TipoOperacionInfo('Inscripción', Icons.person_add),
  'crear_cliente':
      TipoOperacionInfo('Nuevo cliente', Icons.person_add),
  'editar_cliente':
      TipoOperacionInfo('Edición de cliente', Icons.edit),
  'eliminar_cliente':
      TipoOperacionInfo('Eliminación de cliente', Icons.person_remove),
  'pago_mensual': TipoOperacionInfo('Pago mensual', Icons.payments),
  'pago_mensualidad':
      TipoOperacionInfo('Pago de mensualidad', Icons.payments),
  'regalar_mes_cumpleanos':
      TipoOperacionInfo('Regalo de cumpleaños', Icons.card_giftcard),
  'pago_diario': TipoOperacionInfo('Pago diario', Icons.payments),
  'editar_pago':
      TipoOperacionInfo('Corrección de pago', Icons.edit_note),
  'anular_pago': TipoOperacionInfo('Anulación de pago', Icons.cancel),
  'foto': TipoOperacionInfo('Foto', Icons.photo),
  'vincular_foto':
      TipoOperacionInfo('Vinculación de foto', Icons.photo_library),
  'cambiar_estado':
      TipoOperacionInfo('Cambio de estado', Icons.swap_horiz),
  'ajuste': TipoOperacionInfo('Cambio de precio', Icons.tune),
  'admin_usuario': TipoOperacionInfo('Usuario APK', Icons.manage_accounts),
  'confirmar_entrega':
      TipoOperacionInfo('Confirmar entrega', Icons.check_circle),
  'gasto': TipoOperacionInfo('Gasto', Icons.receipt),
  'crear_suplemento':
      TipoOperacionInfo('Nuevo suplemento', Icons.fitness_center),
  'editar_suplemento':
      TipoOperacionInfo('Edición de suplemento', Icons.edit_note),
  'eliminar_suplemento':
      TipoOperacionInfo('Eliminación de suplemento', Icons.delete_outline),
  'venta_suplemento':
      TipoOperacionInfo('Venta de suplemento', Icons.point_of_sale),
  'crear_categoria':
      TipoOperacionInfo('Nueva categoría', Icons.category),
  'editar_categoria':
      TipoOperacionInfo('Edición de categoría', Icons.edit),
  'inscripcion_venta_suplemento':
      TipoOperacionInfo('Inscripción + venta', Icons.person_add),
};

/// Nombre formal de un tipo de operación. Si no está en el mapa,
/// devuelve el identificador tal cual (no rompe con tipos nuevos).
String describirTipoOp(String tipo) =>
    kTiposOperacion[tipo]?.etiqueta ?? tipo;

/// Icono de un tipo de operación. Fallback genérico.
IconData iconoTipoOp(String tipo) =>
    kTiposOperacion[tipo]?.icono ?? Icons.sync;
