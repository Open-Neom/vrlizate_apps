import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_presenter.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_scene_ui.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_viewer_save_barrier.dart';
import 'package:vrlizate_apps/vrlizate_apps_expedition.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart';

final class _Store implements VrlzExpeditionPersistence {
  Uint8List? bytes;
  var writes = 0;
  bool fail = false;
  @override
  Future<Uint8List?> read(String expeditionId) async => bytes;
  @override
  Future<void> write(String expeditionId, Uint8List data) async {
    if (fail) throw StateError('simulated local write failure');
    writes++;
    bytes = Uint8List.fromList(data);
  }
}

VrlzExpeditionController _controller(
  _Store store, {
  bool longText = false,
}) => VrlzExpeditionController(
  definition: VrlzExpeditionDefinition(
    id: 'passport-test',
    experienceId: 'worlds-test',
    title: 'Expedición',
    revision: 1,
    worlds: {for (var i = 0; i < 28; i++) 'world-$i': 'Lugar $i'},
    missions: [
      VrlzExpeditionMission(
        id: 'first',
        world: 'world-0',
        title: 'Las primeras formas',
        instruction: longText
            ? '${List.filled(45, 'Observa las formas').join(' ')} FINAL-INSTRUCCION'
            : 'Camina hasta la galería y observa sus formas.',
        discovery: longText
            ? '${List.filled(45, 'Un lugar diverso').join(' ')} FINAL-DESCUBRIMIENTO'
            : 'Las formas comparten un mismo espacio.',
        position: [16, 1.6, 13],
        radius: 2.5,
      ),
      VrlzExpeditionMission(
        id: 'second',
        world: 'world-1',
        title: 'Explora otra sala',
        instruction: 'Viaja al siguiente lugar.',
        discovery: 'Cada lugar tiene personalidad.',
        position: [8, 1.6, 13],
      ),
    ],
  ),
  store: store,
);

VrInputEvent _event(
  VrInputType type, {
  Object? button,
  bool active = true,
  VrInputSource source = VrInputSource.gamepad,
}) => VrInputEvent(
  type: type,
  source: source,
  active: active,
  data: button == null ? null : {'button': button},
);

VrlzPassportIntent _handle(
  VrlzPassportInputPolicy policy,
  VrInputEvent event, {
  bool active = true,
  bool loading = false,
  bool exiting = false,
  bool ready = true,
  bool open = false,
}) => policy.handle(
  event,
  active: active,
  loading: loading,
  exiting: exiting,
  ready: ready,
  open: open,
);

void main() {
  test(
    'passport represents all 28 stamps and ordered objective without GPU work',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('world-0');
      controller.visit('world-27');
      final presentation = VrlzPassportPresentation(controller);
      expect(presentation.progress, 'Sellos 2/28 · Misiones 0/2');
      expect(presentation.nextWorld, 'world-0');
      expect(presentation.nextTitle, 'Las primeras formas');
      final stamps = presentation.pages.where(
        (p) => p.title == 'Sellos de lugares',
      );
      expect(stamps, hasLength(5));
      final body = stamps.map((p) => p.body).join('\n');
      expect(body, contains('✓ Lugar 0\n'));
      expect(body, contains('✓ Lugar 27'));
      expect(body, contains('○ Lugar 1\n'));
      for (var i = 0; i < 28; i++) {
        expect(
          body.split('\n').where((line) => line.endsWith(' Lugar $i')),
          hasLength(1),
        );
      }
      expect(
        presentation.pages.any((p) => p.title == 'Descubrimientos'),
        isTrue,
      );
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'discoveries and next destination update only on accepted nearby completion',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('world-0');
      final before = VrlzPassportPresentation.stamp(controller);
      expect(controller.complete('first', 'world-0', [1, 1.6, 1]), isFalse);
      expect(VrlzPassportPresentation.stamp(controller), before);
      expect(controller.complete('first', 'world-0', [16, 1.6, 13]), isTrue);
      final presentation = VrlzPassportPresentation(controller);
      expect(presentation.nextWorld, 'world-1');
      expect(presentation.progress, 'Sellos 1/28 · Misiones 1/2');
      expect(
        presentation.pages
            .where((p) => p.title.startsWith('Descubrimiento ·'))
            .single
            .body,
        contains('Las formas comparten un mismo espacio.'),
      );
      expect(VrlzPassportPresentation.stamp(controller), isNot(before));
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'bounded pages preserve long instructions and discoveries without dropping the end',
    () async {
      final controller = _controller(_Store(), longText: true);
      await controller.restore();
      controller.visit('world-0');
      var presentation = VrlzPassportPresentation(controller);
      final introduction = presentation.pages.where(
        (p) => p.title.startsWith('Pasaporte ·'),
      );
      expect(introduction.length, greaterThan(1));
      expect(introduction.every((p) => p.body.length <= 360), isTrue);
      expect(introduction.last.body, endsWith('FINAL-INSTRUCCION'));
      controller.complete('first', 'world-0', [16, 1.6, 13]);
      presentation = VrlzPassportPresentation(controller);
      final discoveries = presentation.pages.where(
        (p) => p.title.startsWith('Descubrimiento ·'),
      );
      expect(discoveries.length, greaterThan(1));
      expect(discoveries.every((p) => p.body.length <= 360), isTrue);
      expect(discoveries.last.body, endsWith('FINAL-DESCUBRIMIENTO'));
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'accepted discovery has an explicit confirmation page for automatic opening',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('world-0');
      expect(VrlzPassportPresentation(controller).discoveryPage('first'), -1);
      controller.complete('first', 'world-0', [16, 1.6, 13]);
      final presentation = VrlzPassportPresentation(controller);
      final page = presentation.discoveryPage('first');
      expect(page, greaterThanOrEqualTo(0));
      expect(
        presentation.pages[page].body,
        contains('Descubrimiento registrado.'),
      );
      expect(presentation.nextWorld, 'world-1');
      expect(
        presentation.saveStatus,
        isNot(contains('guardado correctamente')),
      );
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'completed campaign removes travel target but retains every discovery',
    () async {
      final controller = _controller(_Store());
      await controller.restore();
      controller.visit('world-0');
      controller.complete('first', 'world-0', [16, 1.6, 13]);
      controller.visit('world-1');
      controller.complete('second', 'world-1', [8, 1.6, 13]);
      final presentation = VrlzPassportPresentation(controller);
      expect(presentation.nextWorld, isNull);
      expect(presentation.pages.first.body, contains('Expedición completada'));
      expect(
        presentation.pages.where((p) => p.title.startsWith('Descubrimiento ·')),
        hasLength(2),
      );
      await controller.flush();
      controller.dispose();
    },
  );

  test(
    'save errors restamp presentation and remain explicit until durable retry',
    () async {
      final store = _Store()..fail = true;
      final controller = _controller(store);
      await controller.restore();
      controller.visit('world-0');
      final before = VrlzPassportPresentation.stamp(controller);
      expect(await controller.flush(), isFalse);
      expect(VrlzPassportPresentation.stamp(controller), isNot(before));
      expect(
        VrlzPassportPresentation(controller).pages.last.title,
        'Guardado pendiente',
      );
      store.fail = false;
      expect(await controller.flush(), isTrue);
      expect(
        VrlzPassportPresentation(
          controller,
        ).pages.any((p) => p.title == 'Guardado pendiente'),
        isFalse,
      );
      controller.dispose();
    },
  );

  test(
    'phone X edge and physical X trigger open the same spatial passport',
    () {
      final policy = VrlzPassportInputPolicy();
      expect(
        _handle(
          policy,
          _event(VrInputType.buttonX, source: VrInputSource.remotePhone),
        ),
        VrlzPassportIntent.open,
      );
      expect(
        _handle(
          policy,
          _event(VrInputType.buttonX, source: VrInputSource.remotePhone),
          open: true,
        ),
        VrlzPassportIntent.close,
      );
      expect(
        _handle(policy, _event(VrInputType.trigger, button: VrGamepadButton.x)),
        VrlzPassportIntent.open,
      );
      expect(
        _handle(
          policy,
          _event(VrInputType.trigger, button: VrGamepadButton.x),
          open: true,
        ),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(
          policy,
          _event(VrInputType.trigger, button: VrGamepadButton.x, active: false),
          active: false,
        ),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.trigger, button: 'x'), open: true),
        VrlzPassportIntent.close,
      );
    },
  );

  test('B/back closes passport first, then requests saved exit', () {
    final policy = VrlzPassportInputPolicy();
    for (final type in [VrInputType.back, VrInputType.buttonB]) {
      expect(
        _handle(policy, _event(type), open: true),
        VrlzPassportIntent.close,
      );
      expect(_handle(policy, _event(type)), VrlzPassportIntent.exit);
    }
  });

  test(
    'paused, loading, not-ready, releases and consumed events cannot open passport',
    () {
      final policy = VrlzPassportInputPolicy();
      expect(
        _handle(policy, _event(VrInputType.buttonX), active: false),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.buttonX), loading: true),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.buttonX), ready: false),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.buttonX), exiting: true),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.buttonX, active: false)),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.buttonX)..consume()),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.select)),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.trigger, button: VrGamepadButton.y)),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(
          policy,
          _event(VrInputType.trigger, button: VrGamepadButton.r2),
        ),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(policy, _event(VrInputType.back), active: false, open: true),
        VrlzPassportIntent.none,
      );
    },
  );

  test('reset releases a physical X hold when the route is hidden', () {
    final policy = VrlzPassportInputPolicy();
    expect(
      _handle(policy, _event(VrInputType.trigger, button: 'x')),
      VrlzPassportIntent.open,
    );
    policy.reset();
    expect(
      _handle(policy, _event(VrInputType.trigger, button: 'x')),
      VrlzPassportIntent.open,
    );
  });

  test(
    'objective node identity changes per mission so stale gaze cannot advance the next',
    () {
      expect(
        VrlzExpeditionSceneUi.objectiveName('first'),
        isNot(VrlzExpeditionSceneUi.objectiveName('second')),
      );
      expect(
        VrlzExpeditionSceneUi.objectiveName('first'),
        startsWith('${VrlzExpeditionSceneUi.missionName}_'),
      );
    },
  );

  test('unchanged pose still flushes accepted expedition progress', () async {
    final store = _Store();
    final controller = _controller(store);
    await controller.restore();
    controller.visit('world-0');
    final result = await VrlzViewerSaveBarrier.save(
      flushExpedition: controller.flush,
    );
    expect(result.saved, isTrue);
    expect(store.writes, 1);
    controller.complete('first', 'world-0', [16, 1.6, 13]);
    expect(
      (await VrlzViewerSaveBarrier.save(
        flushExpedition: controller.flush,
      )).saved,
      isTrue,
    );
    expect(store.writes, 2);
    controller.dispose();
  });

  test(
    'save barrier blocks exit on expedition failure and accepts durable retry',
    () async {
      final store = _Store()..fail = true;
      final controller = _controller(store);
      await controller.restore();
      controller.visit('world-0');
      var poseWrites = 0;
      final failed = await VrlzViewerSaveBarrier.save(
        writePose: () async {
          poseWrites++;
        },
        flushExpedition: controller.flush,
      );
      expect(failed.saved, isFalse);
      expect(failed.poseError, isNull);
      expect(poseWrites, 1);
      store.fail = false;
      expect(
        (await VrlzViewerSaveBarrier.save(
          flushExpedition: controller.flush,
        )).saved,
        isTrue,
      );
      controller.dispose();
    },
  );

  test(
    'pose failure still drains discoveries and remains a failed navigation save',
    () async {
      var expeditionFlushes = 0;
      final result = await VrlzViewerSaveBarrier.save(
        writePose: () async => throw StateError('simulated pose failure'),
        flushExpedition: () async {
          expeditionFlushes++;
          return true;
        },
      );
      expect(result.saved, isFalse);
      expect(result.poseError, isA<StateError>());
      expect(expeditionFlushes, 1);
    },
  );

  test(
    'viewer save without an expedition retains original pose-only behavior',
    () async {
      var writes = 0;
      final result = await VrlzViewerSaveBarrier.save(
        writePose: () async {
          writes++;
        },
      );
      expect(result.saved, isTrue);
      expect(writes, 1);
      expect((await VrlzViewerSaveBarrier.save()).saved, isTrue);
    },
  );
}
