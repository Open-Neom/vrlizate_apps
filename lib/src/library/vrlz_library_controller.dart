import 'package:flutter/foundation.dart';

import '../../vrlizate_apps.dart';
import '../../vrlizate_apps_io.dart';

/// Renderer-independent card state. A web index is unverified until [kind] is set.
@immutable
class VrlzLibraryItem {
  const VrlzLibraryItem({
    required this.key,
    required this.id,
    required this.title,
    required this.description,
    this.kind,
    this.demoId,
  });

  final String key, id, title, description;
  final VrlzPackageKind? kind;
  final String? demoId;
}

/// Coordinates package sources without building widgets or launching routes.
///
/// The host explicitly refreshes at entry/resume and owns experience dispatch.
/// Source switches invalidate pending results; they do not close borrowed
/// loaders or claim to cancel an import already committed to the filesystem.
class VrlzLibraryController extends ChangeNotifier {
  VrlzLibraryController({
    required Future<VrlzDirectoryStore> Function() openDirectory,
    Future<void> Function(VrlzDirectoryStore)? addExamples,
    VrlzPackageLoader? packageLoader,
    VrlzWebCatalogLoader? catalogLoader,
  }) : _openDirectory = openDirectory,
       _addExamples = addExamples,
       _packageLoader = packageLoader ?? VrlzPackageLoader(),
       _catalogLoader = catalogLoader ?? VrlzWebCatalogLoader(),
       _ownsPackageLoader = packageLoader == null,
       _ownsCatalogLoader = catalogLoader == null;

  final Future<VrlzDirectoryStore> Function() _openDirectory;
  final Future<void> Function(VrlzDirectoryStore)? _addExamples;
  final VrlzPackageLoader _packageLoader;
  final VrlzWebCatalogLoader _catalogLoader;
  final bool _ownsPackageLoader, _ownsCatalogLoader;
  Future<VrlzDirectoryStore>? _directory;
  Uri? _webUri;
  List<VrlzLibraryItem> _items = const [];
  List<String> _issues = const [];
  Map<String, VrlzDirectoryEntry> _localEntries = const {};
  Map<String, VrlzWebCatalogEntry> _webEntries = const {};
  String _location = '';
  String? _error;
  bool _busy = false, _isComplete = false, _disposed = false;
  int _generation = 0;

  List<VrlzLibraryItem> get items => _items;
  String get location => _location;
  List<String> get issues => _issues;
  String? get error => _error;
  bool get busy => _busy;
  bool get isWeb => _webUri != null;
  bool get isComplete => _isComplete;
  bool get canInstallExamples => _addExamples != null;

  /// Repeated refresh requests during an operation are coalesced by ignoring
  /// the duplicate. The host can refresh again once [busy] becomes false.
  Future<void> refresh() => _run((generation) async {
    final uri = _webUri;
    if (uri != null) {
      await _scanWeb(uri, generation);
    } else {
      final store = await _directoryStore();
      _ensureCurrent(generation);
      await _scanLocal(store, generation);
    }
  });

  Future<void> useWebCatalog(Uri uri) {
    if (_disposed) return Future.value();
    _webUri = uri;
    _resetSource(uri.toString());
    return _run((generation) => _scanWeb(uri, generation), replace: true);
  }

  Future<void> useLocalDirectory() {
    if (_disposed) return Future.value();
    _webUri = null;
    _directory = null;
    _resetSource('');
    return _run((generation) async {
      final store = await _directoryStore();
      _ensureCurrent(generation);
      await _scanLocal(store, generation);
    }, replace: true);
  }

  /// Validates an HTTPS package, explicitly installs it, then selects local data.
  Future<void> importFromUrl(Uri uri) => _run((generation) async {
    final package = await _packageLoader.load(uri);
    _ensureCurrent(generation);
    final store = await _directoryStore();
    _ensureCurrent(generation);
    await store.importBytes(package.encode());
    _ensureCurrent(generation);
    _webUri = null;
    _resetSource(store.directoryPath);
    await _scanLocal(store, generation);
  });

  /// Sample installation is a host capability and happens only on this call.
  Future<void> installExamples() => _run((generation) async {
    final install = _addExamples;
    if (install == null) {
      throw StateError('This host does not provide sample packages.');
    }
    final store = await _directoryStore();
    _ensureCurrent(generation);
    await install(store);
    _ensureCurrent(generation);
    _webUri = null;
    _resetSource(store.directoryPath);
    await _scanLocal(store, generation);
  });

  /// Returns validated data to the host. Never performs runtime dispatch here.
  /// Unlike refresh actions, load failures also propagate to the awaiting host.
  Future<VrlzPackage> load(String key) async {
    if (_disposed) throw StateError('The package library is disposed.');
    if (_busy) throw StateError('The package library is busy.');
    final local = _localEntries[key];
    final web = _webEntries[key];
    final generation = _begin();
    try {
      _ensureCurrent(generation);
      if (local == null && web == null) {
        throw StateError(
          'This selection is stale. Refresh the package library.',
        );
      }
      if (local != null && !_isComplete) {
        throw StateError(
          'The directory scan is incomplete. Refresh it before opening a package.',
        );
      }
      final VrlzPackage package;
      if (web != null) {
        package = await _catalogLoader.loadPackage(web);
      } else {
        final store = await _directoryStore();
        _ensureCurrent(generation);
        package = await store.load(local!);
      }
      _ensureCurrent(generation);
      _items = List.unmodifiable([
        for (final item in _items)
          if (item.key == key)
            VrlzLibraryItem(
              key: key,
              id: package.id,
              title: package.title,
              description: package.description,
              kind: package.kind,
              demoId: package.demoId,
            )
          else
            item,
      ]);
      return package;
    } catch (error) {
      if (_current(generation)) _error = error.toString();
      rethrow;
    } finally {
      _finish(generation);
    }
  }

  Future<VrlzDirectoryStore> _directoryStore() async {
    final operation = _directory ??= Future.sync(_openDirectory);
    try {
      return await operation;
    } catch (_) {
      if (identical(_directory, operation)) _directory = null;
      rethrow;
    }
  }

  Future<void> _scanLocal(VrlzDirectoryStore store, int generation) async {
    final snapshot = await store.scan();
    _ensureCurrent(generation);
    _location = snapshot.rootPath;
    _localEntries = Map.unmodifiable({
      for (final entry in snapshot.entries) 'local:${entry.path}': entry,
    });
    _webEntries = const {};
    _items = List.unmodifiable([
      for (final entry in _localEntries.entries)
        VrlzLibraryItem(
          key: entry.key,
          id: entry.value.metadata.id,
          title: entry.value.metadata.title,
          description: entry.value.metadata.description,
          kind: entry.value.metadata.kind,
          demoId: entry.value.metadata.demoId,
        ),
    ]);
    _issues = List.unmodifiable(
      snapshot.issues.map(
        (issue) => issue.fileName.isEmpty
            ? issue.message
            : '${issue.fileName}: ${issue.message}',
      ),
    );
    _isComplete = snapshot.isComplete;
  }

  Future<void> _scanWeb(Uri uri, int generation) async {
    final catalog = await _catalogLoader.load(uri);
    _ensureCurrent(generation);
    _location = catalog.source.toString();
    _webEntries = Map.unmodifiable({
      for (final entry in catalog.entries)
        'web:${Uri.encodeComponent(entry.id)}:${entry.url}': entry,
    });
    _localEntries = const {};
    _items = List.unmodifiable([
      for (final entry in _webEntries.entries)
        VrlzLibraryItem(
          key: entry.key,
          id: entry.value.id,
          title: entry.value.title,
          description: '',
        ),
    ]);
    _issues = const [];
    _isComplete = true;
  }

  Future<void> _run(
    Future<void> Function(int generation) action, {
    bool replace = false,
  }) async {
    if (_disposed || (_busy && !replace)) return;
    final generation = _begin();
    try {
      _ensureCurrent(generation);
      await action(generation);
    } catch (error) {
      if (_current(generation)) {
        _error = error.toString();
        _isComplete = false;
      }
    } finally {
      _finish(generation);
    }
  }

  int _begin() {
    final generation = ++_generation;
    _busy = true;
    _error = null;
    _notify();
    return generation;
  }

  void _finish(int generation) {
    if (!_current(generation)) return;
    _busy = false;
    _notify();
  }

  void _resetSource(String location) {
    _location = location;
    _items = const [];
    _issues = const [];
    _localEntries = const {};
    _webEntries = const {};
    _isComplete = false;
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _ensureCurrent(int generation) {
    if (!_current(generation)) {
      throw StateError(
        'The library source changed or its controller was disposed.',
      );
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    if (_ownsPackageLoader) _packageLoader.close();
    if (_ownsCatalogLoader) _catalogLoader.close();
    super.dispose();
  }
}
