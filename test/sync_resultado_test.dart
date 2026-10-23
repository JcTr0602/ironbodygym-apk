/// Tests v1.8.0 (Frente 5) — SyncResultado: el resumen de la
/// sincronización manual dice la VERDAD.
///
/// Bug de campo 2026-10-23: con dos ops pendientes desde hacía
/// horas, el botón «Sincronizar» respondía al instante «Subidos 0
/// · Bajados 0 · Todo estaba al día» — el ciclo ni siquiera corría
/// (lock ocupado) y el resumen se armaba con contadores meta de
/// corridas viejas. Contrato que se verifica aquí:
/// (i) si el ciclo no corrió (lock ocupado / sin sesión), el
///     resultado NO es éxito jamás y el mensaje lo dice en claro;
/// (iv) con pendientes restantes al cierre, el resumen NO dice
///     «al día» y el detalle nombra cuántas quedan y de qué tipo;
/// y el control positivo: corrida limpia sin movimientos SÍ es
/// «Todo estaba al día».
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ironbody_gym/sync.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SyncResultado.noCorrio (i)', () {
    test('lock ocupado: no es éxito y el mensaje es «en curso»', () {
      const r = SyncResultado.noCorrio(SyncMotivoNoCorrio.enCurso);
      expect(r.corrio, isFalse);
      expect(r.alDia, isFalse);
      expect(r.resumenCorto, 'Ya hay una sincronización en curso');
      expect(r.resumenCorto, isNot(contains('al día')));
    });

    test('sin sesión: no es éxito y el mensaje lo dice', () {
      const r = SyncResultado.noCorrio(SyncMotivoNoCorrio.sinSesion);
      expect(r.corrio, isFalse);
      expect(r.alDia, isFalse);
      expect(r.resumenCorto, contains('Sin sesión'));
    });

    test('run() sin sesión devuelve «no corrió», jamás éxito',
        () async {
      // En el entorno de test no hay Supabase inicializado: el
      // motor lo lee como «sin sesión» (fail-closed) y run() lo
      // reporta en el resultado en vez de tragarlo.
      final r = await SyncEngine.instance.run();
      expect(r.corrio, isFalse);
      expect(r.motivoNoCorrio, SyncMotivoNoCorrio.sinSesion);
      expect(r.alDia, isFalse);
    });

    test('push() y pull() sin sesión también devuelven «no corrió»',
        () async {
      final rp = await SyncEngine.instance.push();
      expect(rp.corrio, isFalse);
      final rl = await SyncEngine.instance.pull();
      expect(rl.corrio, isFalse);
    });
  });

  group('SyncResultado con pendientes restantes (iv)', () {
    test('esperando confirmación: no dice «al día» y lo detalla', () {
      const r = SyncResultado(
        corrio: true,
        subidos: 0,
        bajados: 0,
        pendientesRestantes: 2,
        esperandoConfirmacion: 2,
      );
      expect(r.alDia, isFalse);
      expect(r.resumenCorto, isNot(contains('al día')));
      expect(r.resumenCorto, contains('2'));
      expect(r.textoPendientes, contains('esperando confirmación'));
      expect(r.textoPendientes, contains('servidor'));
    });

    test('categorías: error y otro usuario se nombran con su salida',
        () {
      const r = SyncResultado(
        corrio: true,
        pendientesRestantes: 3,
        porSubir: 1,
        conError: 1,
        deOtroUsuario: 1,
      );
      expect(r.alDia, isFalse);
      expect(r.textoPendientes, contains('por subir'));
      expect(r.textoPendientes, contains('con error'));
      expect(r.textoPendientes, contains('otro usuario'));
    });

    test('con error de corrida tampoco es «al día» ni con cola '
        'vacía', () {
      const r = SyncResultado(
        corrio: true,
        error: 'Sin conexión a internet.',
        pendientesRestantes: 0,
      );
      expect(r.alDia, isFalse);
      expect(r.resumenCorto, 'No se pudo sincronizar');
    });
  });

  group('SyncResultado limpio (control positivo)', () {
    test('corrió, sin movimientos y sin pendientes: «al día»', () {
      const r = SyncResultado(corrio: true);
      expect(r.alDia, isTrue);
      expect(r.resumenCorto, 'Todo estaba al día');
      expect(r.textoPendientes, isEmpty);
    });

    test('corrió con movimientos y cola vacía: completada', () {
      const r = SyncResultado(corrio: true, subidos: 3, bajados: 1);
      expect(r.alDia, isTrue);
      expect(r.resumenCorto, 'Sincronización completada');
    });
  });
}
