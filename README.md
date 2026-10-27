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

## Local expeditions (v1 beta)

Import `vrlizate_apps_expedition.dart` for the optional Flutter
`VrlzExpeditionController`; the main barrel remains usable from pure Dart.
Inject `VrlzExpeditionPersistence`, restore before presenting the world, and
flush before releasing the identity/storage lease. A true action result changes
memory; a successful `flush()` confirms durable storage.

Definitions are bounded to **256 KiB**, 32 worlds, 128 main missions, 40 side
stories and 80 conditional world changes. Progress remains **32 KiB**. Authoring
also validates a conservative encoded progress bound, exposed as
`estimatedSnapshotUpperBoundBytes`: it reserves all stamps, completed main/story
records and optional pending/focus fields, even if mutually exclusive branches
cannot all coexist. A definition whose identifiers could exceed the save budget
is rejected before play; shorten those identifiers instead of enlarging saves.
This is a JSON size bound, not a memory or GPU measurement.

An authored mission may contain a `VrlzExpeditionGiver` and
`VrlzExpeditionObject` together, plus an optional `rewardId`. Its flow is:

1. Visit the named world and `accept(id, world, position)` near the giver.
2. `interact(id, world, position)` near the object after acceptance.
3. Return to the giver and `complete(id, world, position)`.

The portable viewer renders one current pair using SDK avatar geometry and
shared input. A opens a conversation with an explicit Accept/Deliver action;
X opens the passport and B closes it before exiting. Object kinds are bounded
strings `collect`, `examine`, `activate`. Giver position is at the feet; object
position is its centre. Radii are checked against the viewer's eye position.
The renderer checks visibility on interaction, including instanced geometry.

While the passport is open, the left stick/D-pad or arrow keys changes pages
horizontally and focuses visible controls vertically. Each deliberate gesture
requires returning to neutral before another step. A (Enter/Space on a keyboard)
activates the focused control; without explicit focus it keeps spatial ray
selection. Moving the laser clears focus, while repeating a retained phone aim
does not. X/B close the panel. Instructions are displayed in the spatial footer.

Passport movement/look gates pause stick locomotion and rotation while leaving
head tracking and pointing available. Closing on a held axis requires neutral
before that axis can move the world again; closing on centered axes does not
swallow the next gesture. Focus clears on page replacement or lifecycle changes,
and rebuilding pages cannot invoke stale actions. Available stories appear before
saved history pages. Story actions are limited to two per page; additional
unlocked continuations receive their own pages. The
phone transport and SDK A/X/B protocol remain unchanged.

Schema-1 snapshots optionally include `pendingMission: {missionId, stage}` with
`accepted` or `collected`. Old completed missions stay completed; missions
without giver/object keep their previous proximity flow. `rewardIds` is derived
from completed mission IDs, not a separately writable inventory. Hosts resolve
known cosmetic IDs and enforce account/profile scope; local progress is not a
server-verified entitlement. The scene owns neither accounts nor storage.

CPU tests cover sequencing, restore, errors and selection policies; they do not
establish mobile GPU performance. NPC and UI geometry is additional to the
world's streaming budget. Text is rebuilt on state changes, not every frame.

### Optional stories and alternate routes

A definition can add up to 40 `VrlzExpeditionSideQuest` entries without changing
main mission IDs. Each unlocks after a completed `afterMissionId`, has a giver
in its origin `world`, and offers exactly two `VrlzExpeditionChoice` entries.
Each choice provides dialogue, a label, a discovery, one to three known distinct
route worlds, and an object in the final world. The origin cannot appear in the
route: it is the return/delivery destination.

`focusSideQuest(id)` selects a story; `focusSideQuest(null)` returns to the main
objective without erasing either pending task. Near the giver,
`chooseSideQuest(id, choiceId, world, eye)` commits the decision. Subsequent
`visit(world)` calls record ordered route checkpoints even for previously stamped
worlds. `interactSideQuest` requires every checkpoint and proximity to the final
object; `completeSideQuest` requires returning to the origin giver. A choice
cannot be replaced after acceptance. There may be one pending side story and
one pending main assignment; completed side stories remain readable.

Schema-1 saves optionally add `focusedSideQuestId` and a `sideQuests` map of
`{choiceId, visitedStops, collected, completedAt?}`. Existing passports remain
valid. Restore rejects unknown choices, invalid prefixes, missing prerequisites,
multiple pending stories and inconsistent dates without replacing the save.
The viewer derives NPC/object visibility and one contextual route gate from this
state. It revalidates the destination and active lifecycle after waiting for
storage, and uses the existing save barrier and world loader. Worlds, geometry,
input and persistence services are reused rather than duplicated per branch.

### Connected stories and conditional dialogue

`VrlzExpeditionSideQuest.requires` optionally adds up to eight
`VrlzExpeditionStoryRequirement(questId, choiceIds)` entries. All requirements
must match; each accepts one or both choices of a **delivered** story. Selecting
a choice or collecting its object does not satisfy a requirement. The main
`afterMissionId` prerequisite still applies.

`dialogueVariants` optionally contains up to sixteen
`VrlzExpeditionDialogueVariant(requires, dialogue)` entries, each with one to
eight requirements. The first matching variant wins; otherwise the giver's
original dialogue is used. Put more specific variants first. Dialogue rules
only read delivered history and do not grant progress themselves.

`controller.isSideQuestUnlocked(quest)` and `sideQuestDialogue(quest)` derive
their answers from the existing passport. Focus, choice acceptance and restore
use the same unlock rules. Definitions reject unknown references/choices,
duplicate requirements, cyclic unlock dependencies and contradictory choices
among a chapter's ancestors. Restoring a continuation
requires its delivered antecedents and consistent completion dates, independent
of JSON map order. There are no additional snapshot fields or mutable unlock
flags, and an older save can unlock newly added stories on its next read.

The viewer uses resolved dialogue and lists only available stories as actionable.
Its progress summary counts completed and available stories, without treating
mutually exclusive branches as missing completion. Completed entries show the
continuations connected to that history that are currently available. Only the
tracked NPC/object and route gate are prepared; this adds no render loop or
world/texture copies. Preserve published choice IDs and meaning when adding
content; changes to existing prerequisites require an explicit save migration.

### Visible world consequences

An expedition can supply up to 80 optional `worldChanges` entries. Each
`VrlzExpeditionWorldChange` has a unique `id`, a known `world`, one to eight
delivered-story `requires`, and at least one component:

- `VrlzExpeditionWorldProp`: `kind`, `label`, `description`, feet `position` and
  inspection `radius`. Kinds are `planter`, `archive`, `beacon` and `shelter`.
- `VrlzExpeditionWorldAccess`: `label`, known `destination`, centre `position`
  and interaction `radius`. Destination must differ from the origin world.
- `reaction`: an existing `VrlzExpeditionGiver` record, including the original
  character ID so the viewer can avoid displaying the same NPC twice.

`controller.worldChange(world)` returns the first compatible entry for that
world, or null. Put later chapters before earlier consequences to replace them.
This limits the active consequence to one prop, one shortcut and one reaction
per world. The same strict reference/condition validation applies; no scripts,
asset URLs or additional mutable progress flags are accepted.

The viewer applies changes to the loaded scene using shared geometry, the
existing avatar renderer and spatial UI. Inspection is read-only; shortcuts use
the world loader and save barrier with proximity, visibility and fresh-state
checks. Existing portals and quest objectives remain available. Consequences
are reconstructed on return or restart from the same identity-scoped passport,
including saves created before `worldChanges` existed. The container format,
world binaries and snapshot schema do not change.

These are local narrative consequences. They do not imply shared multiplayer
world edits, a cloud inventory, physical collision or measured mobile FPS.
