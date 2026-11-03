import 'package:flutter/material.dart';

/// v1.2.9+46 (Gemini): centralización de tipos de operación.
/// Un solo mapa para nombres formales e iconos — la UI no duplica switches.
class TipoOperacionInfo {
  final String etiqueta;
  final IconData icono;
  const TipoOperacionInfo(this.etiqueta, this.icono);
}

const Map<String, TipoOperacionInfo> kTiposOperacion = {
  'inscribir': TipoOperacionInfo('Inscripción', Icons.person_add_rounded),
  'crear_cliente':
      TipoOperacionInfo('Nuevo cliente', Icons.person_add_rounded),
  'editar_cliente':
      TipoOperacionInfo('Edición de cliente', Icons.edit_rounded),
  'eliminar_cliente':
      TipoOperacionInfo('Eliminación de cliente', Icons.person_remove_rounded),
  'pago_mensual': TipoOperacionInfo('Pago mensual', Icons.payments_rounded),
  'pago_mensualidad':
      TipoOperacionInfo('Pago de mensualidad', Icons.payments_rounded),
  'regalar_mes_cumpleanos':
      TipoOperacionInfo('Regalo de cumpleaños', Icons.card_giftcard_rounded),
  'pago_diario': TipoOperacionInfo('Pago diario', Icons.payments_rounded),
  'editar_pago':
      TipoOperacionInfo('Corrección de pago', Icons.edit_note_rounded),
  'anular_pago': TipoOperacionInfo('Anulación de pago', Icons.cancel_rounded),
  'foto': TipoOperacionInfo('Foto', Icons.photo_rounded),
  'vincular_foto':
      TipoOperacionInfo('Vinculación de foto', Icons.photo_library_rounded),
  'cambiar_estado':
      TipoOperacionInfo('Cambio de estado', Icons.swap_horiz_rounded),
  // v1.7.0 (oleada A++): Cuenta a la Casa (solo dueño) y las dos
  // decisiones sobre un reporte de pago App Plus de un invitado
  // (ops separadas según el contrato definitivo del servidor).
  'cuenta_casa':
      TipoOperacionInfo('Cuenta a la Casa', Icons.home_rounded),
  'plus_confirmar_reporte':
      TipoOperacionInfo('Confirmación App Plus', Icons.star_rounded),
  'plus_rechazar_reporte':
      TipoOperacionInfo('Rechazo App Plus', Icons.star_border_rounded),
  'ajuste': TipoOperacionInfo('Cambio de precio', Icons.tune_rounded),
  'gympedia_upsert_publicado':
      TipoOperacionInfo('Artículo GymPedia', Icons.menu_book_rounded),
  'gympedia_retirar':
      TipoOperacionInfo('Retirar artículo GymPedia', Icons.menu_book_rounded),
  'admin_usuario': TipoOperacionInfo('Usuario APK', Icons.manage_accounts_rounded),
  'confirmar_entrega':
      TipoOperacionInfo('Confirmar entrega', Icons.check_circle_rounded),
  // Reservas v2.
  'confirmar_reserva':
      TipoOperacionInfo('Confirmar reserva', Icons.bookmark_added_rounded),
  'rechazar_reserva':
      TipoOperacionInfo('Rechazar reserva', Icons.bookmark_remove_rounded),
  'cancelar_reserva':
      TipoOperacionInfo('Cancelar reserva', Icons.bookmark_remove_rounded),
  'cobrar_reserva':
      TipoOperacionInfo('Cobrar reserva', Icons.payments_rounded),
  'gasto': TipoOperacionInfo('Gasto', Icons.receipt_rounded),
  // v1.10.0 (Bloque 2 NÚCLEO, Argón ajuste 8): la app ya puede
  // ENCOLAR estos tipos. El handler del servidor y la ampliación
  // del CHECK de sync_ops llegan por otra vía: NO compilar antes
  // de eso, porque PostgREST rechazaría las ops en silencio.
  // upsert_panel_config se registra pero aún no se encola en
  // ningún flujo (los ítems C/F/H que lo usarían van a la 1.11.0).
  'upsert_tarifa_especial':
      TipoOperacionInfo('Tarifa especial', Icons.local_offer_rounded),
  'revoke_tarifa_especial':
      TipoOperacionInfo('Revocar tarifa especial', Icons.cancel_rounded),
  'update_cliente_sensible':
      TipoOperacionInfo('Edición sensible de cliente', Icons.security_rounded),
  'upsert_compra': TipoOperacionInfo('Compra registrada', Icons.receipt_long_rounded),
  'anular_compra': TipoOperacionInfo('Anulación de compra', Icons.cancel_rounded),
  'upsert_plantilla_mensaje':
      TipoOperacionInfo('Plantilla de mensaje', Icons.message_rounded),
  'delete_plantilla_mensaje':
      TipoOperacionInfo('Eliminar plantilla', Icons.delete_outline_rounded),
  'upsert_panel_config':
      TipoOperacionInfo('Configuración del panel', Icons.settings_rounded),
  // v1.11.0 (Bloque 2 RESTO, Argón AMARILLO): la app ya puede
  // ENCOLAR estos tipos. El handler del servidor y la ampliación
  // del CHECK de sync_ops llegan por otra vía (el SQL de la 1.11.0
  // está en entregas/): NO compilar antes de eso, porque PostgREST
  // rechazaría las ops.
  'liquidar_entrega_efectivo':
      TipoOperacionInfo('Entrega de efectivo', Icons.handshake_rounded),
  'actualizar_config_gym':
      TipoOperacionInfo('Configuración del gym', Icons.tune_rounded),
  'upsert_recordatorio_config':
      TipoOperacionInfo('Recordatorio', Icons.notifications_rounded),
  'delete_recordatorio_config':
      TipoOperacionInfo('Eliminar recordatorio', Icons.notifications_off_rounded),
  // v1.12.0 (Bloque 3): tipos con handler + CHECK en el servidor
  // (bot 59f2ffd, SQL_112_20261024.txt, CHECK 78).
  // v1.13.0 (Bloque 4): D4 (registrar_medicion_cliente, diferido
  // desde la 1.12.0 por decisión de Jc) + reponer_lote. NO compilar
  // antes de que Jc ejecute SQL_113 (CHECK 80): el salvavidas 23514
  // (G3) deja estas ops en reintento, no las marca rechazadas.
  // La reversión D3 NO añade tipo: reutiliza revertir_venta_servicio
  // (desde la 1.9.0, separado de anular_pago).
  'registrar_medicion_cliente':
      TipoOperacionInfo('Medición de cliente', Icons.straighten_rounded),
  'reponer_lote':
      TipoOperacionInfo('Reponer lote', Icons.add_circle_outline_rounded),
  // 1.15 (pomos): relleno del principal al pomo del entrenador.
  'reponer_pomo':
      TipoOperacionInfo('Rellenar pomo', Icons.add_circle_outline_rounded),
  'solicitar_adelanto':
      TipoOperacionInfo('Solicitud de adelanto', Icons.request_page_rounded),
  'resolver_solicitud_adelanto':
      TipoOperacionInfo('Resolución de adelanto', Icons.rule_rounded),
  'upsert_aviso_entrenador':
      TipoOperacionInfo('Aviso para entrenadores', Icons.campaign_rounded),
  'crear_suplemento':
      TipoOperacionInfo('Nuevo suplemento', Icons.fitness_center_rounded),
  'editar_suplemento':
      TipoOperacionInfo('Edición de suplemento', Icons.edit_note_rounded),
  'eliminar_suplemento':
      TipoOperacionInfo('Eliminación de suplemento', Icons.delete_outline_rounded),
  'venta_suplemento':
      TipoOperacionInfo('Venta de suplemento', Icons.point_of_sale_rounded),
  'crear_categoria':
      TipoOperacionInfo('Nueva categoría', Icons.category_rounded),
  'editar_categoria':
      TipoOperacionInfo('Edición de categoría', Icons.edit_rounded),
  'inscripcion_venta_suplemento':
      TipoOperacionInfo('Inscripción + venta', Icons.person_add_rounded),
  // v1.8.0: servicios por dosis.
  'abrir_bote_servicio':
      TipoOperacionInfo('Abrir bote de servicio', Icons.science_rounded),
  'crear_lote_servicio':
      TipoOperacionInfo('Crear lote de servicio', Icons.local_drink_rounded),
  'venta_servicio':
      TipoOperacionInfo('Venta de servicio', Icons.bolt_rounded),
  'salida_servicio':
      TipoOperacionInfo('Salida de servicio', Icons.outbox_rounded),
  'revertir_venta_servicio':
      TipoOperacionInfo('Reverso de servicio', Icons.undo_rounded),
  'reponer_agua': TipoOperacionInfo('Reponer agua', Icons.water_drop_rounded),
  'cerrar_lote_servicio':
      TipoOperacionInfo('Cerrar lote de servicio', Icons.lock_rounded),
  'cerrar_bote_servicio':
      TipoOperacionInfo('Cerrar bote de servicio', Icons.lock_rounded),
  // v1.8.0: adelantos a entrenadores.
  'registrar_adelanto':
      TipoOperacionInfo('Adelanto a entrenador', Icons.payments_rounded),
  'anular_adelanto':
      TipoOperacionInfo('Anulación de adelanto', Icons.undo_rounded),
  // 1.20 (W3): corrección del origen de un adelanto.
  'corregir_origen_adelanto': TipoOperacionInfo(
      'Corrección de origen de adelanto', Icons.swap_horiz_rounded),
  // 1.20 (T4): conciliación de una transferencia (solo dueño).
  'marcar_conciliacion': TipoOperacionInfo(
      'Conciliación de transferencia', Icons.fact_check_rounded),
  // 1.20 (T5): expediente de diferencia de caja (solo dueño).
  'diferencia_abrir': TipoOperacionInfo(
      'Expediente de diferencia de caja', Icons.folder_open_rounded),
  'diferencia_resolver': TipoOperacionInfo('Resolución de diferencia '
      'de caja', Icons.task_alt_rounded),
  'liquidar_nomina':
      TipoOperacionInfo('Nómina liquidada', Icons.fact_check_rounded),
  // Fase A 2026-10-25 (A4): bonos manuales sincronizados.
  'registrar_bono_nomina':
      TipoOperacionInfo('Bono de nómina', Icons.card_giftcard_rounded),
  'eliminar_bono_nomina':
      TipoOperacionInfo('Bono de nómina eliminado', Icons.undo_rounded),
  // 1.23 (contrato de ops): tipos vivos que faltaban en el
  // registro — se encolaban por opTipo:/constantes y la cola
  // los mostraba con el identificador crudo. El test
  // test_contrato_ops exige registro == servidor == CHECK.
  'crear_incidencia': TipoOperacionInfo(
      'Incidencia creada', Icons.report_problem_rounded),
  'editar_incidencia': TipoOperacionInfo(
      'Incidencia editada', Icons.edit_note_rounded),
  'incidencia': TipoOperacionInfo(
      'Incidencia', Icons.report_problem_rounded),
  'incidencia_estado': TipoOperacionInfo(
      'Estado de incidencia', Icons.swap_horiz_rounded),
  'cambiar_estado_incidencia': TipoOperacionInfo(
      'Estado de incidencia', Icons.swap_horiz_rounded),
  'agregar_comentario_incidencia': TipoOperacionInfo(
      'Comentario en incidencia', Icons.comment_rounded),
  'registrar_foto_incidencia': TipoOperacionInfo(
      'Foto de incidencia', Icons.photo_camera_rounded),
  'upsert_tipo_incidencia': TipoOperacionInfo(
      'Tipo de incidencia', Icons.category_rounded),
  'reordenar_tipos_incidencia': TipoOperacionInfo(
      'Orden de tipos de incidencia', Icons.reorder_rounded),
  'foto_suplemento': TipoOperacionInfo(
      'Foto de suplemento', Icons.photo_rounded),
  'gympedia_borrador_upsert': TipoOperacionInfo(
      'Borrador de GymPedia', Icons.edit_note_rounded),
  'gympedia_solicitud_descartar': TipoOperacionInfo(
      'Solicitud de GymPedia descartada', Icons.block_rounded),
  'nomina_confirmar_recepcion': TipoOperacionInfo(
      'Recepción de nómina confirmada', Icons.fact_check_rounded),
  'permiso_bandeja': TipoOperacionInfo(
      'Permiso de bandeja', Icons.mark_email_read_rounded),
  'acceso_bloqueo_set': TipoOperacionInfo(
      'Candado de acceso', Icons.lock_rounded),
  'ajustar_stock_suplemento': TipoOperacionInfo(
      'Ajuste de stock de suplemento', Icons.inventory_2_rounded),
  'anular_pago_diario': TipoOperacionInfo(
      'Pago diario anulado', Icons.cancel_rounded),
  'editar_pago_diario': TipoOperacionInfo(
      'Corrección de pago diario', Icons.edit_note_rounded),
  'anular_venta_suplemento': TipoOperacionInfo(
      'Venta de suplemento anulada', Icons.cancel_rounded),
  'saldar_fiado_suplemento': TipoOperacionInfo(
      'Fiado de suplemento saldado', Icons.payments_rounded),
  'apertura_turno':
      TipoOperacionInfo('Apertura de turno', Icons.play_circle_rounded),
  'cierre_turno':
      TipoOperacionInfo('Cierre de turno', Icons.stop_circle_rounded),
  'liquidar_caja': TipoOperacionInfo(
      'Liquidación de caja', Icons.fact_check_rounded),
  'aprobar_incidencia_sync': TipoOperacionInfo(
      'Incidencia de sync aprobada', Icons.task_alt_rounded),
  'descartar_incidencia_sync': TipoOperacionInfo(
      'Incidencia de sync descartada', Icons.block_rounded),
  'auditoria':
      TipoOperacionInfo('Auditoría', Icons.fact_check_rounded),
  'eliminar_foto':
      TipoOperacionInfo('Foto eliminada', Icons.hide_image_rounded),
  'guardar_tipos_pago': TipoOperacionInfo(
      'Tipos de pago guardados', Icons.payments_rounded),
  'guia_upsert_publicado': TipoOperacionInfo(
      'Guía publicada', Icons.menu_book_rounded),
  'guia_equipo_upsert': TipoOperacionInfo(
      'Equipo de guía guardado', Icons.fitness_center_rounded),
  'guia_retirar':
      TipoOperacionInfo('Guía retirada', Icons.block_rounded),
  'set_cliente_protegido': TipoOperacionInfo(
      'Cliente protegido', Icons.shield_rounded),
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
    kTiposOperacion[tipo]?.icono ?? Icons.sync_rounded;
