import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;

import '../bundles/vrlz_package.dart';
import '../bundles/vrlz_world_bundle.dart';
import '../bundles/vrlz_world_manifest.dart';
import '../bundles/vrz_glb.dart';

/// A borrowed identity: no account or authentication state is owned here.
class VrCreatorIdentity {
  const VrCreatorIdentity({
    required this.uid,
    required this.profileId,
    required this.isCurrent,
    required this.getIdToken,
  });
  final String uid, profileId;
  final bool Function() isCurrent;
  final Future<String?> Function() getIdToken;
}

/// Deterministic resource budget summary computed for creator `.vrlz` packages.
final class VrCreatorPackageBudget {
  const VrCreatorPackageBudget({
    required this.kind,
    required this.archiveBytes,
    required this.maxArchiveBytes,
    required this.estimatedVramBytes,
    required this.maxEstimatedVramBytes,
    required this.maxTriangles,
    required this.maxTrianglesLimit,
    required this.entryCount,
    required this.maxEntryCount,
  });

  static const int maxSceneArchiveBytes = VrlzPackage.maxBytes;
  static const int maxWorldsArchiveBytes = VrlzWorldBundle.maxBytes;
  static const int maxRetroArchiveBytes = 256 * 1024;
  static const int maxSceneVramBytes = VrzGlbV2Limits.maxEstimatedVramBytes;
  static const int maxWorldsVramBytes = VrlzWorldBundle.maxWorldUnpackedBytesV2;
  static const int maxRetroVramBytes = 1024 * 1024;
  static const int maxSceneTriangles = 250000;
  static const int maxWorldModelTriangles = VrlzWorldBundle.maxModelTrianglesV2;

  final VrlzPackageKind kind;
  final int archiveBytes;
  final int maxArchiveBytes;
  final int estimatedVramBytes;
  final int maxEstimatedVramBytes;
  final int maxTriangles;
  final int maxTrianglesLimit;
  final int entryCount;
  final int maxEntryCount;

  bool get withinLimits =>
      archiveBytes > 0 &&
      archiveBytes <= maxArchiveBytes &&
      estimatedVramBytes >= 0 &&
      estimatedVramBytes <= maxEstimatedVramBytes &&
      maxTriangles >= 0 &&
      maxTriangles <= maxTrianglesLimit &&
      entryCount >= 1 &&
      entryCount <= maxEntryCount;

  void validateForSubmission() {
    if (!withinLimits) {
      throw const FormatException(
        'El paquete supera el presupuesto de archivo, VRAM o geometría.',
      );
    }
  }

  Map<String, Object> toJson() => {
    'archiveBytes': archiveBytes,
    'estimatedVramBytes': estimatedVramBytes,
    'maxTriangles': maxTriangles,
    'entryCount': entryCount,
  };
}

/// Validated `.vrlz` package payload with immutable SHA-256 digest and budget.
class VrCreatorPackage {
  VrCreatorPackage._(this.package, this.bytes, this.sha256, this.budget);

  factory VrCreatorPackage.validate(Uint8List bytes) {
    // Keep an immutable copy: the upload hash must identify the validated bytes.
    if (bytes.isEmpty || bytes.length > VrlzPackage.maxBytes) {
      throw const FormatException('El archivo supera el límite de 32 MiB.');
    }
    final rawCopy = Uint8List.fromList(bytes);
    var decoded = VrlzPackage.decode(rawCopy, allowRawVrlwV2: true);
    final Uint8List normalized;
    if (VrlzWorldBundle.hasRawVrlwMagic(rawCopy)) {
      // Promote standalone .vrlw places into a deterministic STORE .vrlz archive.
      normalized = Uint8List.fromList(decoded.encode()).asUnmodifiableView();
      decoded = VrlzPackage.decode(normalized);
    } else {
      normalized = rawCopy.asUnmodifiableView();
    }
    final budget = _computeBudget(decoded, normalized.length);
    if (decoded.isCreatorSubmittable) {
      budget.validateForSubmission();
    }
    return VrCreatorPackage._(
      decoded,
      normalized,
      crypto.sha256.convert(normalized).toString(),
      budget,
    );
  }

  static VrCreatorPackageBudget _computeBudget(
    VrlzPackage package,
    int archiveBytes,
  ) {
    switch (package.kind) {
      case VrlzPackageKind.scene:
        final stats = package.sceneBundle!.glbStats;
        return VrCreatorPackageBudget(
          kind: VrlzPackageKind.scene,
          archiveBytes: archiveBytes,
          maxArchiveBytes: VrCreatorPackageBudget.maxSceneArchiveBytes,
          estimatedVramBytes: stats.estimatedVramBytes,
          maxEstimatedVramBytes: VrCreatorPackageBudget.maxSceneVramBytes,
          maxTriangles: stats.submittedTriangles,
          maxTrianglesLimit: VrCreatorPackageBudget.maxSceneTriangles,
          entryCount: 1,
          maxEntryCount: 1,
        );
      case VrlzPackageKind.worlds:
        final worldBundle = package.worldBundle!;
        final metrics = worldBundle.inspectBudgetMetrics();
        return VrCreatorPackageBudget(
          kind: VrlzPackageKind.worlds,
          archiveBytes: archiveBytes,
          maxArchiveBytes: VrCreatorPackageBudget.maxWorldsArchiveBytes,
          estimatedVramBytes: metrics.peakVramBytes,
          maxEstimatedVramBytes: VrCreatorPackageBudget.maxWorldsVramBytes,
          maxTriangles: metrics.maxModelTriangles,
          maxTrianglesLimit: worldBundle.worldModelTriangleBudget,
          entryCount: worldBundle.manifest.worlds.length,
          maxEntryCount: VrlzWorldManifest.maxWorlds,
        );
      case VrlzPackageKind.retro:
        return VrCreatorPackageBudget(
          kind: VrlzPackageKind.retro,
          archiveBytes: archiveBytes,
          maxArchiveBytes: VrCreatorPackageBudget.maxRetroArchiveBytes,
          estimatedVramBytes: archiveBytes,
          maxEstimatedVramBytes: VrCreatorPackageBudget.maxRetroVramBytes,
          maxTriangles: 0,
          maxTrianglesLimit: 0,
          entryCount: 1,
          maxEntryCount: 1,
        );
      case VrlzPackageKind.builtin:
      case VrlzPackageKind.nes:
      case VrlzPackageKind.webgame:
        return VrCreatorPackageBudget(
          kind: package.kind,
          archiveBytes: archiveBytes,
          maxArchiveBytes: VrlzPackage.maxBytes,
          estimatedVramBytes: 0,
          maxEstimatedVramBytes: 0,
          maxTriangles: 0,
          maxTrianglesLimit: 0,
          entryCount: 1,
          maxEntryCount: 1,
        );
    }
  }

  final VrlzPackage package;
  final Uint8List bytes;
  final String sha256;
  final VrCreatorPackageBudget budget;
}

/// Commercial access tier declared for a creator `.vrlz` submission.
enum VrCreatorAccess { free, purchase, subscription }

/// Offer metadata validated prior to issuing a signed creator upload ticket.
class VrCreatorOffer {
  const VrCreatorOffer({
    this.access = VrCreatorAccess.free,
    this.amountMinor = 0,
    this.currency = 'MXN',
  });
  final VrCreatorAccess access;
  final int amountMinor;
  final String currency;

  Map<String, Object> toJson() {
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency) ||
        amountMinor < 0 ||
        amountMinor > 100000000 ||
        (access != VrCreatorAccess.purchase && amountMinor != 0) ||
        (access == VrCreatorAccess.purchase && amountMinor == 0)) {
      throw ArgumentError('Oferta de distribución inválida.');
    }
    return {
      'access': access.name,
      'amountMinor': amountMinor,
      'currency': currency,
    };
  }
}

/// Server receipt returned after a quarantined creator package upload finalizes.
class VrCreatorReceipt {
  const VrCreatorReceipt({required this.id, required this.status});
  final String id, status;
}

/// Contract v1 for an explicitly configured creator backend.
///
/// The server issues a short-lived upload ticket after checking account,
/// ownership, quota, budget and offer. Finalization validates quarantined bytes
/// before review. This client cannot grant publication, payouts or paid access.
class VrCreatorService {
  VrCreatorService({
    required this.identity,
    this.endpoint,
    Set<String> uploadOrigins = const {},
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : uploadOrigins = Set.unmodifiable(uploadOrigins),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _clock = clock ?? DateTime.now {
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout);
    if (endpoint != null && !_safeEndpoint(endpoint!)) {
      throw ArgumentError('El servicio de creadores requiere HTTPS.');
    }
    for (final origin in uploadOrigins) {
      final uri = Uri.tryParse(origin);
      if (uri == null || !_safeEndpoint(uri) || uri.origin != origin) {
        throw ArgumentError('Origen de subida inválido.');
      }
    }
  }

  final VrCreatorIdentity? Function() identity;
  final Uri? endpoint;
  final Set<String> uploadOrigins;
  final Duration timeout;
  final http.Client _client;
  final bool _ownsClient;
  final DateTime Function() _clock;
  bool _closed = false, _uploading = false;
  final _pending = <Completer<void>>{};

  bool get configured =>
      !_closed && endpoint != null && uploadOrigins.isNotEmpty;

  static bool _safeEndpoint(Uri uri) =>
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.port == 443 &&
      uri.userInfo.isEmpty &&
      !uri.hasFragment &&
      !uri.hasQuery;

  void _check(VrCreatorIdentity account) {
    if (_closed || !account.isCurrent()) {
      throw StateError('La sesión cambió. Vuelve a entrar antes de continuar.');
    }
  }

  Future<Map<String, dynamic>> _call(
    VrCreatorIdentity account,
    String action,
    Map<String, Object> data,
  ) async {
    _check(account);
    final token = await account.getIdToken().timeout(timeout);
    _check(account);
    if (token == null || token.isEmpty) throw StateError('Inicia sesión.');
    final request = http.Request('POST', endpoint!)
      ..followRedirects = false
      ..headers.addAll({
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      })
      ..body = jsonEncode({'schemaVersion': 1, 'action': action, ...data});
    final response = await _send(request);
    final bytes = response.bodyBytes;
    _check(account);
    if (response.statusCode != 200) {
      throw StateError(
        'El servidor no autorizó la operación (${response.statusCode}).',
      );
    }
    final result = jsonDecode(utf8.decode(bytes));
    if (result is! Map<String, dynamic> || result['schemaVersion'] != 1) {
      throw const FormatException('Respuesta de publicación incompatible.');
    }
    return result;
  }

  Future<http.Response> _send(http.Request request) async {
    final abort = Completer<void>();
    _pending.add(abort);
    final cancellable =
        http.AbortableRequest(
            request.method,
            request.url,
            abortTrigger: abort.future,
          )
          ..followRedirects = false
          ..headers.addAll(request.headers)
          ..bodyBytes = request.bodyBytes;
    try {
      return await (() async {
        final response = await _client.send(cancellable);
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (_closed || abort.isCompleted) {
            throw StateError('Operación cancelada.');
          }
          if (bytes.length + chunk.length > 65536) {
            throw StateError('Respuesta demasiado grande.');
          }
          bytes.addAll(chunk);
        }
        return http.Response.bytes(bytes, response.statusCode);
      })().timeout(timeout);
    } finally {
      if (!abort.isCompleted) abort.complete();
      _pending.remove(abort);
    }
  }

  Future<VrCreatorReceipt> submit(
    VrCreatorPackage selected, {
    VrCreatorOffer offer = const VrCreatorOffer(),
    void Function(double)? onProgress,
  }) async {
    if (!configured) {
      throw StateError(
        'La publicación de experiencias aún no está disponible.',
      );
    }
    if (_uploading) throw StateError('Ya hay una subida en curso.');
    if (!selected.package.isCreatorSubmittable) {
      throw StateError(
        'Solo puedes enviar paquetes propios con presupuesto válido (escena, mundos o retro), no referencias a demos de la plataforma.',
      );
    }
    selected.budget.validateForSubmission();
    final account = identity();
    if (account == null || account.uid.isEmpty || account.profileId.isEmpty) {
      throw StateError('Inicia sesión con un perfil para subir experiencias.');
    }
    _check(account);
    _uploading = true;
    try {
      final ticket = await _call(account, 'beginUpload', {
        'profileId': account.profileId,
        'packageId': selected.package.id,
        'title': selected.package.title,
        'description': selected.package.description,
        'kind': selected.package.kind.name,
        'sha256': selected.sha256,
        'sizeBytes': selected.bytes.length,
        'offer': offer.toJson(),
        'budget': selected.budget.toJson(),
      });
      final uploadId = ticket['uploadId'];
      final url = Uri.tryParse(
        ticket['uploadUrl'] is String ? ticket['uploadUrl'] : '',
      );
      final expires = ticket['expiresAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(ticket['expiresAt'])
          : null;
      if (uploadId is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{16,128}$').hasMatch(uploadId) ||
          ticket['ownerUid'] != account.uid ||
          ticket['profileId'] != account.profileId ||
          ticket['sha256'] != selected.sha256 ||
          ticket['sizeBytes'] != selected.bytes.length ||
          url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.hasFragment ||
          !uploadOrigins.contains(url.origin) ||
          expires == null ||
          !expires.isAfter(_clock()) ||
          expires.isAfter(_clock().add(const Duration(minutes: 15)))) {
        throw const FormatException(
          'El permiso de subida no es válido para este archivo y cuenta.',
        );
      }
      _check(account);
      onProgress?.call(0);
      // The signed storage URL receives bytes, never the bearer token.
      final request = http.Request('PUT', url)
        ..followRedirects = false
        ..headers['Content-Type'] = 'application/octet-stream'
        ..bodyBytes = selected.bytes;
      final uploaded = await _send(request);
      _check(account);
      if (uploaded.statusCode < 200 ||
          uploaded.statusCode >= 300 ||
          !expires.isAfter(_clock())) {
        throw StateError(
          'La subida no se completó. El archivo no fue publicado.',
        );
      }
      onProgress?.call(1);
      final receipt = await _call(account, 'finalizeUpload', {
        'uploadId': uploadId,
        'profileId': account.profileId,
        'sha256': selected.sha256,
      });
      if (receipt['uploadId'] != uploadId ||
          receipt['ownerUid'] != account.uid ||
          receipt['profileId'] != account.profileId ||
          receipt['packageId'] != selected.package.id ||
          receipt['status'] != 'pendingReview') {
        throw const FormatException(
          'El servidor no confirmó la recepción para revisión.',
        );
      }
      return VrCreatorReceipt(id: uploadId, status: 'pendingReview');
    } finally {
      _uploading = false;
    }
  }

  void close() {
    _closed = true;
    for (final abort in _pending) {
      if (!abort.isCompleted) abort.complete();
    }
    if (_ownsClient) _client.close();
  }
}
