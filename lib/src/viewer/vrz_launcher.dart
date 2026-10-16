import 'package:flutter/material.dart';

import '../../vrlizate_apps.dart';
import 'vrz_scene_viewer.dart';

/// Host-independent entry for a scene bundle fetched from an HTTPS address.
/// An optional bundled example works offline and exercises the same decoder.
class VrzLauncher extends StatefulWidget {
  const VrzLauncher({
    super.key,
    this.theme,
    this.loadExample,
    this.loadBundle,
    this.viewerBuilder,
  });

  final ThemeData? theme;
  final Future<VrzBundle> Function()? loadExample;
  final Future<VrzBundle> Function(Uri)? loadBundle;
  final Widget Function(VrzBundle)? viewerBuilder;

  @override
  State<VrzLauncher> createState() => _VrzLauncherState();
}

class _VrzLauncherState extends State<VrzLauncher> {
  final _address = TextEditingController();
  final _loader = VrzBundleLoader();
  bool _opening = false;
  String? _error;

  Future<void> _open(Future<VrzBundle> Function() load) async {
    if (_opening) return;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final bundle = await load();
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              widget.viewerBuilder?.call(bundle) ??
              VrzSceneViewer(bundle: bundle),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'No se pudo abrir el paquete. $error');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  void _openAddress() {
    final address = Uri.tryParse(_address.text.trim());
    if (address == null ||
        address.scheme != 'https' ||
        address.host.isEmpty ||
        address.userInfo.isNotEmpty ||
        address.fragment.isNotEmpty) {
      setState(
        () => _error = 'Escribe una dirección HTTPS válida del archivo .vrlz.',
      );
      return;
    }
    _open(() => widget.loadBundle?.call(address) ?? _loader.load(address));
  }

  @override
  void dispose() {
    _address.dispose();
    _loader.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: widget.theme ?? Theme.of(context),
    child: Scaffold(
      appBar: AppBar(title: const Text('Abrir una escena .vrlz')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 680),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.view_in_ar_outlined,
                    color:
                        (widget.theme ?? Theme.of(context)).colorScheme.primary,
                    size: 56,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Un espacio que puedes llevar contigo',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: (widget.theme ?? Theme.of(context))
                          .colorScheme
                          .onSurface,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Abre una escena 3D autocontenida desde su dirección. '
                    'La versión inicial .vrlz incluye el modelo, sus materiales y la cámara de entrada.',
                    style: TextStyle(
                      color: (widget.theme ?? Theme.of(context))
                          .colorScheme
                          .onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    key: const ValueKey('vrz_url'),
                    controller: _address,
                    enabled: !_opening,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _openAddress(),
                    decoration: const InputDecoration(
                      labelText: 'Dirección HTTPS',
                      hintText: 'https://tu-dominio.com/escenas/espacio.vrlz',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const ValueKey('vrz_open_url'),
                    onPressed: _opening ? null : _openAddress,
                    icon: _opening
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.open_in_new),
                    label: Text(_opening ? 'Abriendo…' : 'Abrir escena'),
                  ),
                  if (widget.loadExample != null) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const ValueKey('vrz_open_example'),
                      onPressed: _opening
                          ? null
                          : () => _open(widget.loadExample!),
                      icon: const Icon(Icons.inventory_2_outlined),
                      label: const Text(
                        'Probar paquete incluido · sin conexión',
                      ),
                    ),
                  ],
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 24),
                  Text(
                    'Compatible con escenas estáticas .vrlz v1. '
                    'Las experiencias interactivas siguen disponibles en el catálogo.',
                    style: TextStyle(
                      color: (widget.theme ?? Theme.of(context))
                          .colorScheme
                          .onSurfaceVariant,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// Preferred name for new callers.
typedef VrlzLauncher = VrzLauncher;
