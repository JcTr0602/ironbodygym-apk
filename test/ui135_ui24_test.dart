/// 1.35 (UI-24): barrido de objetivos táctiles de las
/// pantallas de trabajo diario — se MIDE el alto tocable
/// real de cada fila y control (réplicas fieles de la
/// configuración de origen, citadas una a una) y todo lo
/// que quede por debajo de 48 dp se sube con relleno
/// invisible, sin cambiar la densidad visual de la fila
/// (el patrón del avatar del marco, RD-3 de la 1.32).
///
/// Superficies: Directorio y Listas (FilaCliente, el
/// widget real), búsqueda avanzada, filtro de Suplementos,
/// Cola (bloqueadas) y bandeja Por Decidir.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ironbody_gym/tiempo.dart';
import 'package:ironbody_gym/ui/buscar.dart';
import 'package:ironbody_gym/ui/componentes.dart';
import 'package:ironbody_gym/ui/diseno.dart';

const _minimo = 48.0;

Map<String, dynamic> _cliente({int dias = 30}) {
  final hoy = ahoraHabana();
  final f = DateTime(hoy.year, hoy.month, hoy.day + dias);
  return {
    'id': 51,
    'nombre': 'Cliente Fila',
    'pagado_hasta': '${f.year}-'
        '${f.month.toString().padLeft(2, '0')}-'
        '${f.day.toString().padLeft(2, '0')}',
  };
}

Future<double> _altoDe(WidgetTester t, Widget w,
    {required Finder finder}) async {
  await t.pumpWidget(MaterialApp(
    theme: AppTema.tacticoOscuro(),
    home: Scaffold(
        body: Align(alignment: Alignment.topLeft, child: w)),
  ));
  await t.pump();
  return t.getSize(finder).height;
}

void main() {
  testWidgets('FilaCliente normal: la fila toca ≥48',
      (t) async {
    final h = await _altoDe(
      t,
      SizedBox(
          width: 360, child: FilaCliente(cliente: _cliente())),
      finder: find.byType(FilaCliente),
    );
    expect(h, greaterThanOrEqualTo(_minimo), reason: 'fila: $h');
  });

  testWidgets('FilaCliente compacta (recientes y vista '
      'compacta): la fila toca ≥48', (t) async {
    final h = await _altoDe(
      t,
      SizedBox(
          width: 360,
          child: FilaCliente(cliente: _cliente(), compacta: true)),
      finder: find.byType(FilaCliente),
    );
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'fila compacta: $h');
  });

  testWidgets('FilaCliente: el botón directo de WhatsApp '
      'toca ≥48 (buscar.dart, accionWhatsapp)', (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: SizedBox(
              width: 360,
              child: FilaCliente(
                  cliente: _cliente(), accionWhatsapp: () {}))),
    ));
    await t.pump();
    final boton = find.ancestor(
        of: find.byIcon(Icons.chat_rounded),
        matching: find.byType(IconButton));
    expect(boton, findsOneWidget);
    final h = t.getSize(boton).height;
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'botón WhatsApp: $h');
  });

  testWidgets('FilaCliente: el botón fantasma de la '
      '«próxima acción» toca ≥48 (accionPrincipal)',
      (t) async {
    await t.pumpWidget(MaterialApp(
      theme: AppTema.tacticoOscuro(),
      home: Scaffold(
          body: SizedBox(
              width: 360,
              child: FilaCliente(
                cliente: _cliente(dias: -3),
                accionPrincipal: (
                  texto: 'Cobrar',
                  icono: Icons.payments_rounded,
                  alTocar: () {},
                ),
              ))),
    ));
    await t.pump();
    final boton = find.widgetWithText(TextButton, 'Cobrar');
    expect(boton, findsOneWidget);
    final h = t.getSize(boton).height;
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'botón próxima acción: $h');
  });

  testWidgets('búsqueda avanzada: el SwitchListTile de '
      '«Buscar también en notas» toca ≥48 (réplica de '
      'buscar.dart)', (t) async {
    final h = await _altoDe(
      t,
      const SizedBox(
        width: 360,
        child: SwitchListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text('Buscar también en notas',
              style: AppTexto.secundario),
          value: false,
          onChanged: null,
        ),
      ),
      finder: find.byType(SwitchListTile),
    );
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'SwitchListTile: $h');
  });

  testWidgets('filtro de Suplementos: el RadioListTile '
      'toca ≥48 (réplica de suplementos.dart)', (t) async {
    final h = await _altoDe(
      t,
      SizedBox(
        width: 360,
        child: RadioGroup<String>(
          groupValue: 'todos',
          onChanged: (_) {},
          child: RadioListTile<String>(
            value: 'todos',
            title: Text('Todos'),
            dense: true,
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
      finder: find.byType(RadioListTile<String>),
    );
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'RadioListTile: $h');
  });

  testWidgets('Por Decidir: la fila densa de conteo toca '
      '≥48 (réplica de por_decidir.dart)', (t) async {
    final h = await _altoDe(
      t,
      SizedBox(
        width: 360,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: IconoModuloBadge.naranja(Icons.search_rounded),
          title: const Text('Buscar cliente',
              style: AppTexto.cuerpo),
          trailing: Text('3',
              style: AppTexto.subtitulo
                  .copyWith(fontWeight: FontWeight.w700)),
          onTap: () {},
        ),
      ),
      finder: find.byType(ListTile),
    );
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'fila Por Decidir: $h');
  });

  testWidgets('Por Decidir: «Liquidar Arqueo» toca ≥48 '
      '(réplica del estilo local de por_decidir.dart '
      'sobre el tema de la casa)', (t) async {
    final h = await _altoDe(
      t,
      FilledButton.tonal(
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(
              horizontal: AppEspacio.sm),
          minimumSize: const Size(64, 48),
        ),
        onPressed: () {},
        child: const Text('Liquidar Arqueo'),
      ),
      finder: find.byType(FilledButton),
    );
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'Liquidar Arqueo: $h');
  });

  testWidgets('Cola: el «Reintentar» de una op bloqueada '
      'toca ≥48 (réplica del trailing de cola.dart sobre '
      'el tema de la casa)', (t) async {
    final h = await _altoDe(
      t,
      TextButton(
        onPressed: () {},
        child: const Text('Reintentar'),
      ),
      finder: find.byType(TextButton),
    );
    expect(h, greaterThanOrEqualTo(_minimo),
        reason: 'Reintentar: $h');
  });

  test('contrato: las correcciones viven en el origen '
      '(densidades fuera, mínimos en el sitio)', () {
    final buscar = File('lib/ui/buscar.dart').readAsStringSync();
    // El botón de WhatsApp de la fila ya no va compacto.
    final i = buscar.indexOf("'Avisar por WhatsApp'");
    final segWa = buscar.substring(i - 200, i + 200);
    expect(segWa, isNot(contains('VisualDensity.compact')));
    // El botón fantasma de la próxima acción declara su
    // mínimo de 48 en su estilo.
    final j = buscar.indexOf('widget.accionPrincipal!.alTocar');
    final segAccion = buscar.substring(j - 900, j);
    expect(segAccion, contains('Size(64, 48)'));
    expect(segAccion, isNot(contains('MaterialTapTargetSize.shrinkWrap')));
    // «Liquidar Arqueo» declara el mínimo de la casa y
    // va SIN densidad compacta (la compacta descuenta
    // 8 dp del mínimo resuelto: con ella, ni el tema ni
    // el minimumSize mandan — medido en la pieza).
    final porDecidir =
        File('lib/ui/por_decidir.dart').readAsStringSync();
    final k = porDecidir.indexOf("'Liquidar Arqueo'");
    final segLiq = porDecidir.substring(k - 900, k);
    expect(segLiq, contains('Size(64, 48)'));
    expect(segLiq, isNot(contains('VisualDensity.compact')));
  });
}
