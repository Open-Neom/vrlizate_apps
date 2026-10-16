import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vrlizate_apps/vrlizate_apps.dart';
import 'package:vrlizate_apps/vrlizate_apps_viewer.dart';

void main() {
  late VrzBundle example;

  setUpAll(() {
    example = VrzBundle.decode(
      File('test/fixtures/stereo_gallery.vrlz').readAsBytesSync(),
    );
  });

  testWidgets('rejects invalid addresses before calling the loader', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VrzLauncher(
          loadBundle: (_) async {
            calls++;
            return example;
          },
        ),
      ),
    );
    for (final url in [
      'http://example.org/a.vrz',
      'file:///a.vrz',
      'https://user:pass@example.org/a.vrz',
    ]) {
      await tester.enterText(find.byKey(const ValueKey('vrz_url')), url);
      await tester.tap(find.byKey(const ValueKey('vrz_open_url')));
      await tester.pump();
      expect(find.textContaining('HTTPS válida'), findsOneWidget);
    }
    expect(calls, 0);
  });

  testWidgets(
    'waits for validation, launches once and enables opening on return',
    (tester) async {
      final navigator = GlobalKey<NavigatorState>();
      final pending = Completer<VrzBundle>();
      var loads = 0;
      final launches = <VrzBundle>[];
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: VrzLauncher(
            loadBundle: (url) {
              expect(url.toString(), 'https://example.org/gallery.vrz');
              loads++;
              return pending.future;
            },
            viewerBuilder: (bundle) {
              launches.add(bundle);
              return Scaffold(body: Text(bundle.manifest.title));
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('vrz_url')),
        'https://example.org/gallery.vrz',
      );
      await tester.tap(find.byKey(const ValueKey('vrz_open_url')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vrz_open_url')));
      expect(loads, 1);
      expect(launches, isEmpty);
      pending.complete(example);
      await tester.pumpAndSettle();
      expect(launches, [example]);
      expect(find.text(example.manifest.title), findsOneWidget);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('vrz_open_url')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offline sample can recover after a failed load', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: VrzLauncher(
          loadExample: () async {
            if (attempts++ == 0) throw const FormatException('Invalid sample');
            return example;
          },
          viewerBuilder: (bundle) =>
              Scaffold(body: Text(bundle.manifest.title)),
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('vrz_open_example')));
    await tester.tap(find.byKey(const ValueKey('vrz_open_example')));
    await tester.pumpAndSettle();
    expect(find.textContaining('No se pudo abrir'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('vrz_open_example')));
    await tester.pumpAndSettle();
    expect(find.text(example.manifest.title), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving during a load never pushes a stale viewer', (
    tester,
  ) async {
    final pending = Completer<VrzBundle>();
    var launched = false;
    await tester.pumpWidget(
      MaterialApp(
        home: VrzLauncher(
          loadExample: () => pending.future,
          viewerBuilder: (_) {
            launched = true;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.ensureVisible(find.byKey(const ValueKey('vrz_open_example')));
    await tester.tap(find.byKey(const ValueKey('vrz_open_example')));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    pending.complete(example);
    await tester.pumpAndSettle();
    expect(launched, isFalse);
    expect(tester.takeException(), isNull);
  });
}
