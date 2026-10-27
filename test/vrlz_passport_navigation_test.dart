import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/src/viewer/vrlz_expedition_presenter.dart';
import 'package:vrlizate_scene/vrlizate_scene.dart';

VrInputEvent _axes(
  double x,
  double y, {
  VrInputSource source = VrInputSource.remotePhone,
  Object? stick,
  bool active = true,
}) => VrInputEvent(
  type: VrInputType.navigate,
  source: source,
  active: active,
  data: {
    if (stick != null) 'stick': stick,
    'x': x,
    'y': y,
    if (source == VrInputSource.remotePhone) ...{
      'stickX': x,
      'stickY': y,
      'moveAtEdge': true,
      'lookX': .8,
      'lookY': .7,
    },
  },
);

VrlzPassportIntent _handle(
  VrlzPassportInputPolicy policy,
  VrInputEvent event, {
  bool open = true,
  bool active = true,
  bool loading = false,
  bool ready = true,
  bool exiting = false,
  bool hasFocus = false,
}) => policy.handle(
  event,
  active: active,
  loading: loading,
  ready: ready,
  exiting: exiting,
  open: open,
  hasFocus: hasFocus,
);

void main() {
  test(
    'route suspension requires neutral before held navigation can resume',
    () {
      final p = VrlzPassportInputPolicy();
      expect(_handle(p, _axes(1, 0)), VrlzPassportIntent.nextPage);
      p.reset(requireNeutral: true);
      // VrPortableWorldPage releases remote axes synthetically during pause.
      // The policy must await a real centered sample after the viewer resumes.
      expect(
        _handle(p, _axes(0, 0, active: false), active: false),
        VrlzPassportIntent.none,
      );
      for (var i = 0; i < 60; i++) {
        expect(_handle(p, _axes(1, 0)), VrlzPassportIntent.none);
      }
      _handle(p, _axes(0, 0, active: false));
      expect(_handle(p, _axes(1, 0)), VrlzPassportIntent.nextPage);
    },
  );

  test(
    'retained phone aim survives navigation and A; a new aim clears focus',
    () {
      final p = VrlzPassportInputPolicy();
      final focus = VrlzPassportFocus()..replace(['route-1', 'route-2']);
      final payload = <String, dynamic>{
        'relativeToHead': true,
        'laserX': .4,
        'laserY': .2,
      };
      VrInputEvent pointer() => VrInputEvent(
        type: VrInputType.pointerMove,
        source: VrInputSource.remotePhone,
        data: payload,
      );
      VrlzPassportIntent dispatch(VrInputEvent event, {bool open = true}) {
        final intent = _handle(
          p,
          event,
          open: open,
          hasFocus: focus.focused != null,
        );
        if (intent == VrlzPassportIntent.clearFocus) focus.clear();
        if (intent == VrlzPassportIntent.nextControl) focus.move(1);
        return intent;
      }

      dispatch(pointer(), open: false);
      // Actual App packet ordering: retained pointer, then axes, then A edge.
      dispatch(pointer());
      dispatch(_axes(0, -1));
      expect(focus.focused, 'route-1');
      for (var i = 0; i < 60; i++) {
        dispatch(pointer());
        dispatch(_axes(0, -1));
        expect(focus.focused, 'route-1');
      }
      dispatch(pointer());
      dispatch(_axes(0, 0, active: false));
      dispatch(pointer());
      expect(
        dispatch(
          VrInputEvent(
            type: VrInputType.select,
            source: VrInputSource.remotePhone,
          ),
        ),
        VrlzPassportIntent.activateFocused,
      );
      // Payloads are pooled/mutable. The policy retained numeric values only.
      payload['laserX'] = .6;
      expect(dispatch(pointer()), VrlzPassportIntent.clearFocus);
      expect(focus.focused, isNull);
      expect(
        dispatch(
          VrInputEvent(
            type: VrInputType.select,
            source: VrInputSource.remotePhone,
          ),
        ),
        VrlzPassportIntent.none,
      );
    },
  );

  for (final source in [VrInputSource.remotePhone, VrInputSource.gamepad]) {
    test('$source pages and focus require neutral between gestures', () {
      final p = VrlzPassportInputPolicy();
      VrInputEvent axes(double x, double y) => _axes(
        x,
        y,
        source: source,
        stick: source == VrInputSource.gamepad ? VrGamepadStick.left : null,
      );
      expect(_handle(p, axes(.2, .2)), VrlzPassportIntent.none);
      expect(_handle(p, axes(1, 0)), VrlzPassportIntent.nextPage);
      for (var i = 0; i < 120; i++) {
        expect(_handle(p, axes(1, 0)), VrlzPassportIntent.none);
      }
      expect(_handle(p, axes(-1, 0)), VrlzPassportIntent.none);
      _handle(p, axes(0, 0));
      expect(_handle(p, axes(-1, 0)), VrlzPassportIntent.previousPage);
      _handle(p, axes(0, 0));
      expect(_handle(p, axes(0, 1)), VrlzPassportIntent.previousControl);
      _handle(p, axes(0, 0));
      expect(_handle(p, axes(0, -1)), VrlzPassportIntent.nextControl);
    });
  }

  test(
    'walking hold does not page on opening; right stick never navigates',
    () {
      final p = VrlzPassportInputPolicy();
      expect(_handle(p, _axes(1, 0), open: false), VrlzPassportIntent.none);
      expect(_handle(p, _axes(1, 0)), VrlzPassportIntent.none);
      _handle(p, _axes(0, 0, active: false));
      expect(_handle(p, _axes(1, 0)), VrlzPassportIntent.nextPage);
      expect(
        _handle(p, _axes(0, -1, stick: VrGamepadStick.right)),
        VrlzPassportIntent.none,
      );
      expect(_handle(p, _axes(0, -1, stick: 'right')), VrlzPassportIntent.none);
      expect(
        _handle(p, _axes(double.nan, double.infinity)),
        VrlzPassportIntent.none,
      );
    },
  );

  test('focus is bounded, explicit and discarded on page replacement', () {
    final focus = VrlzPassportFocus()..replace(['route-1', 'route-2', 'close']);
    expect(focus.focused, isNull);
    focus.move(1);
    expect(focus.focused, 'route-1');
    focus.move(1);
    expect(focus.focused, 'route-2');
    focus.move(10);
    expect(focus.focused, 'close');
    focus.move(1);
    expect(focus.focused, 'close');
    focus.move(-10);
    expect(focus.focused, 'route-1');
    focus.clear();
    focus.move(-1);
    expect(focus.focused, 'close');
    focus.replace(['next']);
    expect(focus.focused, isNull);
    focus.replace([]);
    focus.move(1);
    expect(focus.focused, isNull);
  });

  test(
    'A uses explicit focus; gaze, temple tap and R2 retain spatial picking',
    () {
      final p = VrlzPassportInputPolicy();
      for (final source in VrInputSource.values) {
        final event = VrInputEvent(type: VrInputType.select, source: source);
        expect(_handle(p, event), VrlzPassportIntent.none);
        expect(
          _handle(p, event, hasFocus: true),
          [
                VrInputSource.gamepad,
                VrInputSource.remotePhone,
                VrInputSource.externalPeripheral,
              ].contains(source)
              ? VrlzPassportIntent.activateFocused
              : VrlzPassportIntent.none,
        );
      }
      expect(
        _handle(
          p,
          VrInputEvent(
            type: VrInputType.trigger,
            source: VrInputSource.gamepad,
            data: {'button': VrGamepadButton.r2},
          ),
          hasFocus: true,
        ),
        VrlzPassportIntent.none,
      );
      expect(
        _handle(
          p,
          VrInputEvent(
            type: VrInputType.pointerMove,
            source: VrInputSource.remotePhone,
          ),
        ),
        VrlzPassportIntent.clearFocus,
      );
      expect(
        _handle(
          p,
          VrInputEvent(
            type: VrInputType.pointerMove,
            source: VrInputSource.remotePhone,
            active: false,
          ),
        ),
        VrlzPassportIntent.none,
      );
    },
  );

  test('paused, loading, consumed and not-ready input cannot act on focus', () {
    final p = VrlzPassportInputPolicy();
    VrInputEvent a() =>
        VrInputEvent(type: VrInputType.select, source: VrInputSource.gamepad);
    expect(
      _handle(p, a(), hasFocus: true, active: false),
      VrlzPassportIntent.none,
    );
    expect(
      _handle(p, a(), hasFocus: true, loading: true),
      VrlzPassportIntent.none,
    );
    expect(
      _handle(p, a(), hasFocus: true, ready: false),
      VrlzPassportIntent.none,
    );
    expect(
      _handle(p, a(), hasFocus: true, exiting: true),
      VrlzPassportIntent.none,
    );
    expect(_handle(p, a()..consume(), hasFocus: true), VrlzPassportIntent.none);
    _handle(p, _axes(1, 0));
    _handle(p, _axes(0, 0, active: false), active: false);
    expect(_handle(p, _axes(1, 0)), VrlzPassportIntent.nextPage);
  });
}
