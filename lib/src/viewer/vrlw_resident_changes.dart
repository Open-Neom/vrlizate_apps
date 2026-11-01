import 'package:vrlizate_world/vrlizate_world.dart';

/// Cache status notifications do not necessarily change the rendered world.
/// Region data is immutable for the lifetime of its cache entry; identity also
/// detects a replacement at the same coordinate without deep entity scans.
final class VrlwResidentChanges<T> {
  Map<VrRegionKey, VrRegionData<T>> _resident = const {};

  void clear() => _resident = const {};

  bool update(VrRegionSnapshot<T> snapshot) {
    final next = snapshot.resident;
    final changed =
        next.length != _resident.length ||
        next.entries.any(
          (entry) => !identical(_resident[entry.key], entry.value),
        );
    if (changed) _resident = next;
    // Surface load errors even when no geometry has been admitted or evicted.
    return changed || snapshot.errors.isNotEmpty;
  }
}
