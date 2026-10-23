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
  // v1.7.0 (oleada A++): Cuenta a la Casa (solo dueño) y las dos
  // decisiones sobre un reporte de pago App Plus de un invitado
  // (ops separadas según el contrato definitivo del servidor).
  'cuenta_casa':
      TipoOperacionInfo('Cuenta a la Casa', Icons.home_rounded),
  'plus_confirmar_reporte':
      TipoOperacionInfo('Confirmación App Plus', Icons.star_rounded),
  'plus_rechazar_reporte':
      TipoOperacionInfo('Rechazo App Plus', Icons.star_border_rounded),
  'ajuste': TipoOperacionInfo('Cambio de precio', Icons.tune),
  'gympedia_upsert_publicado':
      TipoOperacionInfo('Artículo GymPedia', Icons.menu_book),
  'gympedia_retirar':
      TipoOperacionInfo('Retirar artículo GymPedia', Icons.menu_book),
  'admin_usuario': TipoOperacionInfo('Usuario APK', Icons.manage_accounts),
  'confirmar_entrega':
      TipoOperacionInfo('Confirmar entrega', Icons.check_circle),
  // Reservas v2.
  'confirmar_reserva':
      TipoOperacionInfo('Confirmar reserva', Icons.bookmark_added),
  'rechazar_reserva':
      TipoOperacionInfo('Rechazar reserva', Icons.bookmark_remove),
  'cancelar_reserva':
      TipoOperacionInfo('Cancelar reserva', Icons.bookmark_remove),
  'cobrar_reserva':
      TipoOperacionInfo('Cobrar reserva', Icons.payments),
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
  // v1.8.0: servicios por dosis.
  'abrir_bote_servicio':
      TipoOperacionInfo('Abrir bote de servicio', Icons.science),
  'crear_lote_servicio':
      TipoOperacionInfo('Crear lote de servicio', Icons.local_drink),
  'venta_servicio':
      TipoOperacionInfo('Venta de servicio', Icons.bolt),
  'salida_servicio':
      TipoOperacionInfo('Salida de servicio', Icons.outbox),
  'revertir_venta_servicio':
      TipoOperacionInfo('Reverso de servicio', Icons.undo),
  'reponer_agua': TipoOperacionInfo('Reponer agua', Icons.water_drop),
  'cerrar_lote_servicio':
      TipoOperacionInfo('Cerrar lote de servicio', Icons.lock),
  'cerrar_bote_servicio':
      TipoOperacionInfo('Cerrar bote de servicio', Icons.lock),
  // v1.8.0: adelantos a entrenadores.
  'registrar_adelanto':
      TipoOperacionInfo('Adelanto a entrenador', Icons.payments),
  'anular_adelanto':
      TipoOperacionInfo('Anulación de adelanto', Icons.undo),
  'liquidar_nomina':
      TipoOperacionInfo('Nómina liquidada', Icons.fact_check),
};

/// v1.4.4: etiquetas de la op 'ajuste' según su clave. Antes TODA
/// op de ajuste se etiquetaba «Cambio de precio» y un cambio de
/// horario de turnos parecía un cambio de precio en el historial.
const Map<String, String> kEtiquetasAjuste = {
  'mensualidad': 'Ajuste: precio de mensualidad',
  'mensualidad_menores': 'Ajuste: mensualidad de menores',
  'transferencia': 'Ajuste: precio por transferencia',
  'pago_diario': 'Ajuste: precio del pago diario',
  'pago_semanal': 'Ajuste: precio semanal',
  'pago_quincenal': 'Ajuste: precio quincenal',
  'promo_suplementos': 'Ajuste: promo de suplementos',
  'tarjeta_bandec': 'Ajuste: tarjeta BANDEC',
  'tarjeta_bpa': 'Ajuste: tarjeta BPA',
  'movil_confirmacion': 'Ajuste: móvil de confirmación',
  'tasa_usd': 'Ajuste: tasa USD',
  'horario_turnos': 'Ajuste: horario de turnos',
  'horario_excepciones': 'Ajuste: excepciones de turnos',
  'plantillas_wa': 'Ajuste: plantillas de WhatsApp',
  'titular': 'Ajuste: titular de la cuenta',
  'precio_app_plus': 'Ajuste: precio App Plus (A++)',
  'servicio_precio_sin_agua': 'Ajuste: precio dosis sin agua',
  'servicio_precio_con_agua': 'Ajuste: precio dosis con agua',
  'servicio_precio_agua': 'Ajuste: precio del pomo de agua',
  'servicio_comision_dosis': 'Ajuste: comisión por dosis',
};

/// Nombre formal de un tipo de operación. Si no está en el mapa,
/// devuelve el identificador tal cual (no rompe con tipos nuevos).
String describirTipoOp(String tipo) =>
    kTiposOperacion[tipo]?.etiqueta ?? tipo;

/// Como [describirTipoOp] pero consciente del payload: para la op
/// 'ajuste' la etiqueta sale de la CLAVE ajustada, no del tipo.
String describirTipoOpConPayload(
    String tipo, Map<String, dynamic>? payload) {
  if (tipo == 'ajuste') {
    final clave = '${payload?['clave'] ?? ''}';
    return kEtiquetasAjuste[clave] ?? 'Ajuste';
  }
  return describirTipoOp(tipo);
}

/// Icono de un tipo de operación. Fallback genérico.
IconData iconoTipoOp(String tipo) =>
    kTiposOperacion[tipo]?.icono ?? Icons.sync;
