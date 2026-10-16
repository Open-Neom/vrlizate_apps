import 'pack_vrlz.dart' as vrlz;

/// Legacy scene-pack command. Prefer pack_vrlz.dart and the .vrlz extension.
Future<void> main(List<String> arguments) =>
    vrlz.packVrlz(arguments, allowLegacyExtension: true);
