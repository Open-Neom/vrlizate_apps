# vrlizate_apps

Contenedor y validación de paquetes `.vrlz`, descubrimiento en directorio local, catálogos HTTPS y transporte por rangos de lugares `.vrlw` para **VRlizate**.

> Versión actual: **1.0.0**. Consulta [CHANGELOG.md](CHANGELOG.md) y la [especificación `.vrlz`](doc/vrlz_format.md).

## Puntos de entrada

| Librería | Responsabilidad |
| --- | --- |
| `vrlizate_apps.dart` | Modelos `.vrlz`, manifiestos, cargadores HTTPS, índices `catalog.json`, registro de mini-apps espaciales (`VrSpatialMiniAppRegistry`) y verificador de integridad (`VrPackageIntegrityVerifier`). |
| `vrlizate_apps_io.dart` | Escaneo e importación en directorio local (`VrlzDirectoryStore`); stub en web. |
| `vrlizate_apps_library.dart` | Controlador observable de fuentes (`VrlzLibraryController`), sin widgets. |
| `vrlizate_apps_viewer.dart` | Visor 3D opcional de escenas estáticas (`VrlzSceneViewer`). |

*(Los contratos y empaquetadores específicos de videojuegos `.vrlz` se encuentran también en el módulo especializado [`vrlizate_games`](../vrlizate_games/README.md)).*

## Perfiles de paquetes `.vrlz`

- **Escena estática (`v1`):** `ZIP STORE` con `manifest.json` y `scene.glb` autocontenido (sin código ejecutable).
- **Descriptor integrado (`vrlizate.builtin.v1`):** referencia un `demoId` compilado en el host.
- **Cartucho NES (`vrlizate.nes.v1`):** `manifest.json` + `game.nes` (iNES NROM 16/32 KiB PRG, 8 KiB CHR, SHA-256, licencia completa y `sourceUrl`).
- **Nivel Retro 2.5D (`vrlizate.retro2d.v1`):** `manifest.json` + `level.json` (niveles de casillas/entidades importables desde Tiled JSON).
- **Mundos conectados (`vrlizate.worlds.v1`):** lugares `.vrlw` conectados por portales locales con recursos GLB/RGBA8 estáticos.

## Uso rápido

### Directorio local e integración con el host

```dart
final library = VrlzLibraryController(
  openDirectory: () async => VrlzDirectoryStore(path),
  addExamples: installBundledExamples,
);
await library.refresh();
```

###Transporte HTTPS por rangos para lugares `.vrlw`

`VrlwHttpSource` exige respuestas `206 Partial Content` exactas y `ETag` fuerte para solicitar únicamente cabecera, índice y regiones activas junto con `vrlizate_world`.

### Herramientas CLI

```sh
dart run tool/pack_vrlz.dart scene.glb gallery.vrlz \
  --id org.example.gallery --title "Galería"
dart run tool/index_vrlz.dart /ruta/experiencias
```

## Verificación

```sh
flutter test
dart analyze lib test tool
```

## Licencia

Apache License 2.0 — consulta [LICENSE](LICENSE).
