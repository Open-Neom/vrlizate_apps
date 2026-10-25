# vrlizate_apps

Contenedor y validación de paquetes `.vrlz`, descubrimiento en directorio local, catálogos HTTPS y transporte por rangos de lugares `.vrlw` para **VRlizate**.

> Versión actual: **1.0.0**. Consulta [CHANGELOG.md](CHANGELOG.md) y la [especificación `.vrlz`](doc/vrlz_format.md).

## Puntos de entrada

| Librería | Responsabilidad |
| --- | --- |
| `vrlizate_apps.dart` | Modelos `.vrlz`, manifiestos, cargadores HTTPS, índices `catalog.json`, registro de mini-apps espaciales (`VrSpatialMiniAppRegistry`) y verificador de integridad (`VrPackageIntegrityVerifier`). |
| `vrlizate_apps_io.dart` | Escaneo e importación en directorio local (`VrlzDirectoryStore`); stub en web. |
| `vrlizate_apps_library.dart` | Controlador observable de fuentes (`VrlzLibraryController`), sin widgets. |
| `vrlizate_apps_viewer.dart` | Visores opcionales `VrlzSceneViewer` y `VrlzWorldViewer`; salida de audio ambiental inyectable `VrlwAudioOutput`. |

*(Los contratos y empaquetadores específicos de videojuegos `.vrlz` se encuentran también en el módulo especializado [`vrlizate_games`](../vrlizate_games/README.md)).*

## Perfiles de paquetes `.vrlz`

- **Escena estática (`v1`):** `ZIP STORE` con `manifest.json` y `scene.glb` autocontenido (sin código ejecutable).
- **Descriptor integrado (`vrlizate.builtin.v1`):** referencia un `demoId` compilado en el host.
- **Cartucho NES (`vrlizate.nes.v1`):** `manifest.json` + `game.nes` (iNES NROM 16/32 KiB PRG, 8 KiB CHR, SHA-256, licencia completa y `sourceUrl`).
- **Nivel Retro 2.5D (`vrlizate.retro2d.v1`):** `manifest.json` + `level.json` (niveles de casillas/entidades importables desde Tiled JSON).
- **Mundos conectados (`vrlizate.worlds.v1`):** lugares `.vrlw` conectados por portales locales, con PNG baseColor/UV0 embebidos, movimiento acotado, controles de proximidad y audio ambiental optativo dentro del subconjunto beta.
- **Juego web (v1 beta, `vrlizate.webgame.v1`):** índice pequeño de HTML/JS/WASM y recursos con hash/longitud, unidades bajo demanda, caché persistente LRU y perfiles de mando. Requiere un sandbox de navegador del host; no carga Dart AOT ni plugins descargados. Consulta [el contrato webgame](doc/vrlz_webgame_v1_beta.md).

### Texturas del perfil de mundos

El consumidor móvil admite hasta cuatro PNG baseColor por modelo GLB, de hasta
256 × 256 píxeles y 1 MiB de nivel base RGBA8 por modelo. La autoría actual genera
RGB8 opaco de 128 × 128. Se verifican bufferView, índices, UV0, CRC y expansión
IDAT acotada antes de registrar recursos. No se permiten URI, APNG, interlace ni
otros mapas embebidos. Las escenas VRZ/`vrlizate.scene.v1` siguen sin texturas.

El formato permanece **v1 beta**; hosts anteriores rechazan estos modelos y
requieren actualizar el SDK. Flutter Scene conserva REPEAT y el sampler
trilineal solicitado, con mipmaps sujetos al soporte del backend. El adaptador
comparte recursos entre entidades y ambos ojos, conserva las texturas unlit y
reutiliza los materiales con overrides. PNG iguales en GLB distintos todavía
pueden ocupar texturas distintas.

El límite de 1 MiB base estima unos 1,33 MiB por modelo con una cadena completa
de mipmaps. No es una medición GPU ni incluye toda la memoria del visor.
Consulta [límites y compatibilidad del perfil](doc/vrlz_format.md#png-embebido-en-modelos-de-mundos-v1-beta).

### Movimiento, controles y ambiente, v1 beta

El índice `.vrlw` admite hasta **ocho `motions` y ocho `interactions`**. El host
interpreta únicamente `spin`/`bob` y `toggleMotion`/`toggleAudio`; no descarga
código ni reproduce animaciones glTF. Antes de importar a GPU, cada motion debe
resolver un único nodo GLB con nombre, malla y transformación implícita identidad,
sin hijos y directamente en la escena activa. Se rechazan nodos ausentes,
duplicados, transformados o presentes solo en otra escena.

El adaptador admite **16 instancias de primitivas móviles residentes**, incluso
si están pausadas o lejos. Actualiza sus transformaciones a un máximo de **30 Hz**
y suspende las lejanas; conserva además los límites de 128 entidades, 256
primitivas y 80 000 triángulos residentes por escena/ojo. Esta frecuencia de
animación no es la frecuencia de renderizado ni una promesa de FPS.

Cada mundo admite **ocho recursos no sonoros más un WAV**: pueden ser ocho modelos
GLB con sus PNG embebidos; las texturas externas también consumen el presupuesto
no sonoro. El WAV exige PCM mono de 16 bits, **16 000 o 22 050 Hz**, como máximo
**256 KiB y ocho segundos**, con cabecera canónica y longitud exacta. OGG, MP3,
estéreo y otros formatos PCM se rechazan en este perfil móvil.

El audio requiere `VrlzWorldViewer(audioOutputFactory: ...)`: sin factory, no se
crea reproducción nativa. `VrlwWorldAudio` mezcla como máximo dos voces cercanas,
con ganancia/pan estéreo relativos al usuario y actualizaciones a 10 Hz; no es
HRTF. La aplicación VRlizate proporciona `NeomVrlwAudioOutput`, que reutiliza
`neom_sound`/SoLoud y no cierra el motor compartido. Audio, input y animación se
suspenden al perder foco, ocultar la ruta, cambiar de mundo o salir del visor.

La fase y los toggles son locales a esa instancia del visor y se conservan al
volver por un portal. No se escriben en `.vrlw`, en la partida persistente ni en
un estado multiusuario; al crear otro visor vuelven a los valores iniciales.
Consulta [el contrato completo](doc/vrlz_format.md#movimiento-controles-y-audio-de-mundos-v1-beta)
y la [guía de autoría de la biblioteca](https://github.com/Open-Neom/codebase_vrlw/blob/main/docs/LIVING_WORLDS_MOBILE.md).

## Uso rápido

### Directorio local e integración con el host

```dart
final library = VrlzLibraryController(
  openDirectory: () async => VrlzDirectoryStore(path),
  addExamples: installBundledExamples,
);
await library.refresh();
```

### Entrada a un lugar declarado desde Home

`VrlzWorldViewer(initialWorld: 'oasis', ...)` conserva el paquete conectado y
sus portales. Restaura primero las visitas y selecciona después ese alias: usa
su pose guardada o el spawn del manifiesto si todavía no se visitó. Omitir
`initialWorld` mantiene la reanudación del último mundo activo. El contrato sin
renderer equivalente es `VrlzWorldSession.selectWorld(alias)`, que devuelve
`false` para destinos desconocidos sin modificar la sesión. Esta selección es
una acción del host; no agrega rutas ejecutables ni permite destinos externos.

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

La ampliación de mundos del 25 de octubre de 2026 tiene 101 pruebas de Apps
superadas: 94 de bundle/sesión/persistencia/actividad/perfil/geometría y siete de
presupuesto móvil. Incluyen los 42 casos nuevos de actividad/perfil; no se suman
otra vez. Las pruebas de audio SDK/host se verifican por separado. Estas pruebas
comprueban lógica y admisión antes de GPU; no sustituyen una prueba visual móvil,
una medida de FPS o una comprobación acústica en dispositivo.

## Licencia

Apache License 2.0 — consulta [LICENSE](LICENSE).
