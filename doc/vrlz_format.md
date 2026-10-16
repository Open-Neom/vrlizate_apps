# VRLZ: escenas, demos integradas, cartuchos NES y juegos retro 2.5D

El perfil de escena VRLZ v1 es un contenedor de **datos** para el runtime `vrlizate.scene.v1` incluido en la aplicación anfitriona. Permite publicar una escena 3D en un hosting HTTPS, descargarla, validarla y abrirla sin reconstruir la aplicación. No incorpora ni ejecuta Dart, JavaScript, bibliotecas nativas o plugins descargados. El visor y sus controles ya están compilados en VRlizate Apps.

Estos perfiles forman la base de `vrlizate_apps`. No representa todavía un formato de aplicaciones Flutter completas. El perfil de escena no admite scripts, permisos, autenticación propia, animaciones, texturas, audio ni red desde la escena. El perfil NES experimental interpreta las instrucciones del cartucho dentro de un emulador incluido por el host; no ejecuta Dart descargado ni instala bibliotecas nativas.

## Cuatro perfiles explícitos

La extensión canónica es **`.vrlz`**. El módulo `vrlizate_apps` posee el formato, el transporte y la detección; Home solo presenta la biblioteca. El lector conserva los bytes del perfil de escena original, antes llamado `.vrz`, sin migrar ni reinterpretar su manifiesto.

| Tipo | formatVersion | runtime | Entradas ZIP |
| --- | --- | --- | --- |
| Escena portable | 1 | `vrlizate.scene.v1` | `manifest.json`, `scene.glb` |
| Demo integrada | 2 | `vrlizate.builtin.v1` | Solo `manifest.json` |
| Cartucho NES experimental | 3 | `vrlizate.nes.v1` | `manifest.json`, `game.nes` |
| Juego retro 2.5D experimental | 4 | `vrlizate.retro2d.v1` | `manifest.json`, `level.json` |

El par versión/runtime decide el perfil antes de validar su contenido. Un error de GLB, checksum o manifiesto de escena se rechaza; no se intenta abrir como demo integrada. Formatos futuros o pares cruzados también se rechazan.

## Contenedor

Un archivo `.vrlz` es un ZIP convencional. El perfil de escena contiene **exactamente** estas dos entradas:

```text
manifest.json
scene.glb
```

El perfil de demo integrada contiene **solo `manifest.json`**; NES contiene **`manifest.json` y `game.nes`**, y retro 2.5D contiene **`manifest.json` y `level.json`**. Todas las entradas usan el método ZIP **STORE (0), sin compresión**. Se rechazan DEFLATE, ZIP64, múltiples discos, cifrado, descriptores de datos, comentarios, campos extra, enlaces simbólicos, directorios y cualquier otra entrada. Los nombres deben coincidir exactamente: no se admiten rutas, duplicados ni diferencias entre las cabeceras locales y el directorio central. Se verifica el CRC-32 de los bytes reales de cada entrada, además del SHA-256 del payload que corresponde al perfil.

El tamaño máximo general del archivo completo es **32 MiB**, reducido a **128 KiB** para NES y **256 KiB** para retro 2.5D; el manifiesto tiene un límite de **64 KiB**. Se procesa en memoria y nunca se extrae al sistema de archivos. El lector no usa descompresión: un ZIP comprimido pequeño no puede inflarse a un contenido arbitrariamente grande. No usa un lector que silenciosamente sustituya entradas duplicadas.

SHA-256 y CRC detectan alteraciones e incoherencias; **no autentican al autor**. Cualquiera puede construir un paquete válido y sus propias sumas. HTTPS protege el transporte. Firmas, catálogo de confianza y actualizaciones verificadas requerirían otro contrato explícito.

## Manifiesto de escena portable (v1)

```json
{
  "formatVersion": 1,
  "id": "org.vrlizate.stereo-gallery",
  "title": "Galería VRLizate",
  "description": "Una escena de demostración.",
  "runtime": "vrlizate.scene.v1",
  "entrypoint": "scene.glb",
  "capabilities": ["scene.gltf2"],
  "sha256": {"scene.glb": "<64 caracteres hexadecimales minúsculos>"},
  "camera": {"position": [0, 1.6, 6], "target": [0, 1, -6]}
}
```

La suma del ejemplo es un marcador: el empaquetador calcula el valor real. Se rechazan versiones, runtimes, capacidades y campos raíz desconocidos. El identificador es un nombre con espacio de nombres, en minúsculas, de hasta 128 caracteres; cumple `^[a-z][a-z0-9]*(?:[._-][a-z0-9]+)+$`. El título es obligatorio, no vacío, de hasta 80 caracteres. La descripción es opcional, de hasta 512 caracteres.

`camera` es opcional; sus valores predeterminados son los del ejemplo. Usa coordenadas de origen glTF: sistema de mano derecha, +Y arriba. Cada vector contiene tres números finitos entre −10000 y +10000. La dirección debe ser distinta y no vertical respecto a +Y. El visor usa estos valores como posición inicial y objetivo inicial. No son código ni una cámara exportada dentro del GLB.

## Manifiesto de demo integrada (v2)

```json
{
  "formatVersion": 2,
  "id": "org.vrlizate.flutter-scene-room",
  "title": "Cuarto integrado",
  "description": "Abre una demo incluida en esta aplicación.",
  "runtime": "vrlizate.builtin.v1",
  "entrypoint": "flutter_scene_room",
  "capabilities": ["host.builtin"],
  "sha256": {}
}
```

`entrypoint` es un **identificador de demo compilada en el host**, no una ruta, URL, nombre de clase ni script. Debe tener 1–128 caracteres ASCII y cumplir completamente `^[a-z][a-z0-9]*(?:[_-][a-z0-9]+)*$`. `id`, `title` y `description` tienen los mismos límites del perfil de escena. Solo se acepta la capacidad `host.builtin`, una vez; `sha256` debe existir como objeto vacío porque no hay payload externo. No se aceptan cámara, GLB, scripts, recursos adicionales ni otros campos raíz.

Un identificador bien formado no demuestra que esa demo exista en el receptor. **El host debe resolverlo en su catálogo explícito de IDs permitidos** y ofrecer una recuperación clara si no está disponible. Nunca se usa para descargar una implementación ni construir dinámicamente código o rutas. Compartir este archivo comparte los metadatos y la selección de una demo: no traslada código, assets ni funciones ausentes del host.

## Manifiesto de cartucho NES (v3, experimental)

```json
{
  "formatVersion": 3,
  "id": "org.example.homebrew",
  "title": "Mi juego",
  "description": "Un cartucho homebrew con distribución autorizada.",
  "runtime": "vrlizate.nes.v1",
  "entrypoint": "game.nes",
  "capabilities": ["emulator.nes"],
  "sha256": {"game.nes": "<64 caracteres hexadecimales minúsculos>"},
  "license": "<Texto completo de licencia y avisos aplicables>",
  "sourceUrl": "https://example.org/homebrew/source"
}
```

El ZIP STORE contiene exactamente `manifest.json` y `game.nes`, con un máximo
de **128 KiB** para el contenedor. Se conservan los controles comunes de ZIP,
JSON, CRC, ID y textos. `sha256` contiene exactamente el hash del cartucho.
`license` exige un aviso de al menos 32 caracteres, máximo 16 KiB UTF-8 y sin
caracteres de control salvo tabulación/salto de línea. Este campo conserva la
declaración del editor; no prueba que posea los derechos ni valida jurídicamente
la licencia. `sourceUrl` exige HTTPS absoluto, hasta 2048 caracteres y sin
credenciales, fragmentos o espacios; no se consulta al abrir el paquete.

El cartucho requiere cabecera iNES 1.0 de 16 bytes, mapper **NROM (0)**, PRG de
16 o 32 KiB y CHR de 8 KiB. Solo se permite la bandera de mirroring horizontal o
vertical. Se rechazan trainer, batería/SRAM, cuatro pantallas, NES 2.0, otras
consolas, extensiones regionales y bytes reservados distintos de cero. La
longitud debe coincidir exactamente; no se admite contenido agregado después de
CHR. El mayor cartucho permitido mide **40 976 bytes**.

Este perfil no incluye BIOS, cores `.so`, plugins, scripts, snapshots ni saves.
El core, sus licencias y actualizaciones pertenecen a la distribución del host;
el estado de juego se conserva aparte, ligado al hash de ROM y versión del core.
El host declara explícitamente si soporta el runtime y ofrece «runtime no
instalado» cuando no lo incluye. La plantilla mínima de Home no lo incluye.
La ROM se interpreta dentro del emulador, sin puente directo a APIs del host.
Estos límites reducen la superficie aceptada, pero no certifican la ausencia de
fallos en un core nativo ni implican aceptación automática en una tienda.

`VrlzPackage.encodeNes({romBytes, id, title, description, license, sourceUrl})`
crea el contenedor desde un proyecto independiente del SDK. El lector expone
`package.nesBundle`, con `romBytes` (copia), `source` y `manifest`; este último
ofrece `romSha256`, `license`, `sourceUrl` y metadatos comunes. La reproducción
en pantalla gigante VR es responsabilidad del host: este formato no convierte
automáticamente sprites 2D en geometría ni en vistas estereoscópicas distintas.

La herramienta genérica admite `--nes juego.nes salida.vrlz`, junto con `--id`,
`--title`, `--license-file` y `--source-url`. No modifica la ROM ni incluye datos
de sesión. Un parche IPS/BPS no es un cartucho y este perfil no contiene un
aplicador de parches; sus entradas ZIP se rechazan en lugar de inferir un runtime.

## Juego retro 2.5D (v4, experimental)

```json
{
  "formatVersion": 4,
  "id": "org.example.original-game",
  "title": "Mi juego original",
  "description": "Plataformas con profundidad estereoscópica.",
  "runtime": "vrlizate.retro2d.v1",
  "entrypoint": "level.json",
  "capabilities": ["game.retro2d"],
  "sha256": {"level.json": "<64 caracteres hexadecimales minúsculos>"},
  "license": "<Texto completo de licencia y avisos aplicables>"
}
```

El paquete STORE tiene exactamente dos archivos y mide como máximo **256 KiB**.
El manifiesto conserva los límites de ID/título/descripción y licencia completa
(32 caracteres mínimo, 16 KiB UTF-8 máximo) del perfil NES, sin `sourceUrl`.
No acepta código, ROM, texturas, audio, bibliotecas ni URLs externas. El archivo
`level.json` tiene exactamente `name`, `theme`, `mode`, `rows`:

```json
{
  "name": "Jardín de prueba",
  "theme": "garden",
  "mode": "platformer",
  "rows": [
    "................", "................", "................",
    "................", "................", "................",
    "..S..*..E.K..G..", "################"
  ]
}
```

`name` es un texto no vacío de hasta 80 caracteres; `theme` es `garden` o `neon`;
`mode` es `platformer` o `blaster`. El nivel rectangular mide entre 16 y 128
columnas y entre 8 y 24 filas. Solo admite los símbolos ASCII de esta tabla:

| Símbolo | Semántica | Límite |
| --- | --- | --- |
| `.` | Espacio vacío | Tamaño del nivel |
| `#` | Suelo/plataforma sólida | Tamaño del nivel |
| `^` | Peligro | Tamaño del nivel |
| `*` | Gema opcional | 128 |
| `S` | Inicio | Exactamente 1 |
| `G` | Salida | Exactamente 1 |
| `E` | Enemigo | 32 |
| `B` | Jefe | 1 |
| `K` | Checkpoint | 8 |

Inicio y salida deben estar dentro del mapa, con `#` inmediatamente debajo y
`.` o `*` inmediatamente arriba. Las filas van de arriba hacia abajo; el centro
X de una casilla es `columna + 0.5` y los pies de un actor situado ahí tienen
Y `alto - 1 - fila`. El validador asegura formato/límites y puntos seguros de
inicio/salida; **no demuestra que cualquier nivel sea completado**. Los autores
deben comprobar la ruta, los saltos y la dificultad con el runtime.

`VrlzPackage.encodeRetro({level, id, title, description, license})` genera el
paquete desde `VrlzRetroLevel.fromJson`. `package.retroBundle` ofrece `level`,
`source` y `manifest` (incluye `levelSha256`); `rows` es inmutable. `encode()`
conserva su contenido y notices. Directorio, importación, índice y HTTPS usan las
APIs existentes. El host debe comprobar que implementa el runtime antes de abrir.
La plantilla mínima de Home lo lista como no instalado.

El simulador, controles, modelos 3D, cámara, audio y persistencia son servicios
compilados en el anfitrión. Cambiar el paquete modifica el nivel y su tema/modo;
no instala nuevas mecánicas ni un ejecutable Flutter. Las experiencias
`sunny_gardens` y `neon_bastion` son proyectos Dart independientes que ejercitan
este flujo con contenido original y licencia MIT.

### Autoría con Tiled

`VrlzTiledImporter.importLevel(tiledJson, name: ..., theme: ..., mode: ...)`
convierte el siguiente subconjunto del [JSON de Tiled](https://doc.mapeditor.org/en/stable/reference/json-map-format/):

- Mapa `type: map`, `orientation: orthogonal`, `infinite: false`, tamaño de
  casilla entero de 1–256 píxeles y dimensiones dentro del perfil.
- Un tileset **embebido** con `firstgid: 1`, `tilecount: 1`. Sus metadatos
  visuales son exclusivos del editor; el importador no lee imágenes ni rutas.
- Exactamente dos capas: `terrain` (`tilelayer`) con arreglo JSON plano de GIDs
  enteros **0 vacío / 1 sólido** y `entities` (`objectgroup`) con objetos punto.
- Los puntos declaran `class` (Tiled 1.9), `type` o, como alternativa, `name`:
  `spawn`, `exit`, `gem`, `enemy`, `boss`, `checkpoint`, `spike`. El primer campo
  no vacío decide la entidad. `x`/`y` son múltiplos de `tilewidth`/`tileheight`:
  `(columna × anchoCasilla, fila × altoCasilla)`.
- No admite compresión/base64, GIDs volteados, grupos, offsets, capas ocultas,
  objetos rotados/ocultos, puntos fuera de la cuadrícula ni superposiciones.
  Rechaza TSX y plantillas externas; no ejecuta scripts.

Esta integración facilita crear nuevos juegos dentro del runtime. **No extrae
ni convierte mapas, personajes o sprites de Mega Man o Super Mario.** Las
mecánicas generales de plataformas/disparos permiten experiencias propias,
con autoría, identidad visual y contenido independientes.

## Subconjunto GLB admitido

`scene.glb` debe ser GLB 2.0, con longitud declarada exacta y exactamente dos bloques alineados: JSON y BIN. Debe tener un único buffer incorporado. No se admiten claves `uri`, ni siquiera `data:`: el formato completo glTF sí admite recursos externos, pero el perfil de escena v1 no los admite. Tampoco se aceptan imágenes, texturas, samplers, skins, animaciones, cámaras glTF, morph targets, accessors dispersos ni decodificadores de extensiones. La única extensión admitida es `KHR_materials_unlit`.

Se admiten mallas de triángulos, índices enteros válidos y atributos `POSITION`, `NORMAL`, `TANGENT`, `TEXCOORD_0` y `COLOR_0`. POSITION, NORMAL y TANGENT usan float32. Materiales PBR sin texturas y materiales unlit pueden contener factores numéricos válidos. La apariencia final depende del renderizador anfitrión y de su iluminación; el perfil de escena v1 no ofrece paridad fotométrica entre motores.

Límites adicionales del validador:

| Recurso | Límite |
| --- | --- |
| JSON del GLB | 2 MiB; anidación máxima 64 |
| Buffer views / accessors | 4096 de cada uno |
| Componentes de accessors inspeccionados | 4 000 000 en total |
| Materiales / mallas / primitivas | 256 / 512 / 2048 |
| Nodos / profundidad de jerarquía | 2048 / 32 |
| Escenas | 1–8 |
| Triángulos / vértices referenciados por nodos | 250 000 de cada uno, contando instancias |
| Valores geométricos float / componentes de matriz mundial | Finitos, valor absoluto ≤ 1 000 000 |
| Traslación / escala TRS | Traslación ≤ 10000; escala absoluta entre 0.0001 y 100 |

Se comprueban los rangos de buffers, strides y accessors; los índices no pueden apuntar fuera de la malla. Se rechazan ciclos, nodos con varios padres, raíces inválidas, transformaciones no finitas y cuaterniones no normalizados. Las matrices deben ser afines y no coexistir con TRS. La validación reduce entradas malformadas y consumo excesivo, pero no constituye una garantía de ausencia de defectos en los parsers o controladores gráficos del anfitrión.

Las imágenes están excluidas expresamente para evitar que imágenes codificadas pequeñas provoquen asignaciones enormes al descomprimirse. Soportarlas en otra versión requiere presupuestos de dimensiones, píxeles, memoria y formatos, además del límite del ZIP.

## API y transporte

```dart
import 'package:vrlizate_apps/vrlizate_apps.dart';

final loader = VrlzPackageLoader();
try {
  final package = await loader.load(Uri.parse('https://example.org/item.vrlz'));
  switch (package.kind) {
    case VrlzPackageKind.scene:
      final scene = package.sceneBundle!;
      // El host presenta scene.sceneBytes con scene.manifest.cameraPosition.
      break;
    case VrlzPackageKind.builtin:
      final demoId = package.demoId!;
      // El host comprueba demoId en su catálogo permitido antes de abrirlo.
      break;
    case VrlzPackageKind.nes:
      final cartridge = package.nesBundle!;
      // El host comprueba el runtime NES y carga cartridge.romBytes en su core.
      break;
    case VrlzPackageKind.retro:
      final game = package.retroBundle!;
      // El host comprueba el runtime retro y simula/renderiza game.level.
      break;
  }
  final bytesToStore = package.encode(); // ZIP validado, sin procedencia URL.
} finally {
  loader.close();
}
```

`VrlzPackage.decode(Uint8List, {Uri? source})` valida bytes ya disponibles, por ejemplo una importación local. Expone `kind`, `id`, `title`, `description`, `source` y únicamente el contenido propio de su tipo: `sceneBundle`, `builtinManifest`/`demoId`, `nesBundle` o `retroBundle`. La extensión del nombre no decide el runtime. `encode()` reconstruye un STORE válido preservando metadatos y cámara, sin retener otra copia de los bytes originales descargados. Puede canonicalizar el JSON y el ZIP, por lo que su SHA-256 de archivo completo puede cambiar respecto del origen.

Las APIs `VrzBundle.decode/encode` y `VrzBundleLoader` siguen disponibles para consumidores **solo de escenas v1**. Rechazan los descriptores builtin, cartuchos NES y niveles retro. `VrlzPackage.encodeBuiltin({id, title, demoId, description})` crea el descriptor v2. Todos los resultados exponen metadatos inmutables; cada acceso a `sceneBytes` o `romBytes` devuelve una copia. `source` registra la dirección final del transporte y no forma parte del archivo.

`VrlzPackageLoader.load(Uri)` y `VrzBundleLoader.load(Uri)` requieren HTTPS y rechazan credenciales y fragmentos en la URL. Usa GET, una fecha límite de red de 30 segundos y como máximo tres redirecciones; vuelve a validar cada destino. Solo acepta HTTP 200. Cuenta siempre los bytes reales durante la descarga. En clientes nativos compara Content-Length si el cuerpo no declara codificación HTTP; cuando el transporte entrega gzip/br ya decodificado, esa cabecera puede medir otros bytes. En navegador no usa Content-Length para aceptar o rechazar tamaños, porque CORS puede ocultar Content-Encoding mientras fetch descomprime; el límite del stream real y la validación del contenido siguen siendo obligatorios. Los límites configurables solo pueden reducir el máximo de tamaño y redirecciones. Un error de transporte, timeout o error de formato impide abrir la escena.

`close()` es idempotente: cancela las operaciones activas y prohíbe futuras cargas. Un `http.Client` inyectado pertenece al llamador y no se cierra, pero se abortan las peticiones de este loader y se cancelan sus streams. El cliente predeterminado sí se cierra. No hay extracción, caché persistente, credenciales de URL ni permisos concedidos por el manifiesto.

En web, el hosting debe permitir CORS para el origen de la aplicación. Hay que proporcionar las URLs HTTPS finales del índice y los paquetes: BrowserClient/fetch con redirecciones automáticas desactivadas puede rechazar una redirección antes de exponerla al loader; en ese entorno no se promete la misma navegación de hasta tres redirecciones que en el cliente nativo. La disponibilidad del visor 3D en cada plataforma depende además del motor y del host compilado. Servir un `.vrlz` no añade soporte gráfico o XR a plataformas donde el anfitrión no lo tenga.

El host Android necesita `android.permission.INTERNET`; un host macOS con sandbox necesita `com.apple.security.network.client` en sus entitlements aplicables. Estas son capacidades de la aplicación instalada, no permisos adquiridos por el paquete descargado. El formato no exige un proveedor de hosting específico; puede servirse como `application/zip` o `application/octet-stream`.

## Catálogos web explícitos

La detección web carga un **índice JSON publicado por el hosting**. No presupone que un servidor permita listar carpetas HTTP ni analiza páginas HTML para encontrar archivos.

```json
{
  "formatVersion": 1,
  "packages": [
    {
      "id": "org.example.cuarto",
      "title": "Cuarto integrado",
      "url": "cuarto.vrlz",
      "sha256": "<SHA-256 del archivo .vrlz completo, 64 hex minúsculas>"
    }
  ]
}
```

`VrlzWebCatalog.decode(bytes, source: uri)` acepta hasta **256 KiB y 128 entradas**. Las entradas requieren exactamente `id`, `title`, `url` y `sha256`; se rechazan campos adicionales, versiones desconocidas e identificadores o URLs duplicados. El ID usa el mismo patrón y límite del manifiesto, el título permite hasta 80 caracteres no vacíos y la URL hasta 2048 caracteres. Se normalizan los segmentos de ruta al comprobar duplicados.

Las URLs relativas se resuelven contra la **dirección final del índice después de sus redirecciones**. Pueden apuntar al mismo dominio o a otro dominio HTTPS; no pueden contener credenciales ni fragmentos. Un catálogo puede estar vacío. Los títulos del índice son metadatos para mostrar, no reemplazan los del paquete ni habilitan demos del host.

```dart
final catalogLoader = VrlzWebCatalogLoader();
try {
  final catalog = await catalogLoader.load(
    Uri.parse('https://example.org/catalog/index.json'),
  );
  for (final entry in catalog.entries) {
    // El host puede mostrar entry.id, entry.title y entry.url antes de descargar.
  }
  if (catalog.entries.isNotEmpty) {
    final package = await catalogLoader.loadPackage(catalog.entries.first);
    // Se verificaron el SHA-256 del archivo completo, su formato y su ID.
  }
} finally {
  catalogLoader.close();
}
```

`VrlzWebCatalogLoader.load` solicita JSON y conserva las mismas reglas de HTTPS, deadline, redirecciones, streams y ownership del transporte de paquetes. Su `maxDownloadBytes` solo puede reducir el límite de 256 KiB del índice. `loadPackage(entry)` usa el presupuesto separado de **32 MiB**; compara SHA-256 antes de decodificar y exige que el `id` real sea el anunciado. Un error impide devolver el paquete al host. `close()` cancela tanto índices como paquetes pendientes; un cliente HTTP inyectado sigue perteneciendo al llamador.

El checksum del índice detecta archivos cambiados o incorrectos respecto del índice. No equivale a una firma del autor: quien controla el índice puede cambiar también sus hashes. Si el host vuelve a serializar el paquete mediante `encode()` para importarlo a su carpeta, sus bytes canónicos pueden tener otro checksum; debe verificar primero la descarga original con `loadPackage`.

## Generar el índice desde una carpeta

Desde la raíz de `vrlizate_apps`, después de resolver dependencias:

```sh
dart --packages=.dart_tool/package_config.json tool/index_vrlz.dart /ruta/paquetes
```

El comando usa `VrlzDirectoryStore.scan()` sin recursión y escribe `/ruta/paquetes/catalog.json`. Cada entrada contiene el ID y título validados, el nombre de archivo codificado como componente URI relativo y el SHA-256 de **los bytes completos del archivo existente**. Los nombres con espacios, `#`, `%` o `:` se codifican; no cambian los archivos `.vrlz`.

```sh
dart --packages=.dart_tool/package_config.json tool/index_vrlz.dart /ruta/paquetes \
  --output /ruta/staging/catalog.json --force
```

`--output` elige otra ruta local y `--force` permite reemplazar un índice existente. Sin `--force`, la creación es exclusiva. La escritura usa un archivo temporal que se publica al completarse; los fallos de escaneo o validación no modifican la salida existente. Se rechazan salidas que sean enlaces simbólicos, directorios o archivos `.vrlz`.

El índice se genera **solo con un escaneo completo y sin ninguna incidencia**. Un paquete inválido, un ID duplicado, un enlace `.vrlz`, un archivo ilegible o un presupuesto excedido impiden publicarlo; no se omiten silenciosamente esas entradas. Se aplican los límites predeterminados del scanner: 128 paquetes, 32 MiB por archivo, 256 MiB totales y 4096 entradas directas de directorio. Una carpeta vacía produce un índice vacío válido.

Este comando no configura hosting ni sube archivos. Al publicar, el índice y sus paquetes deben quedar en el **mismo directorio de URL**, aunque `--output` se haya usado para preparar el índice en otra carpeta local. Si cambia cualquier `.vrlz`, regenera el índice para actualizar su checksum. Usa las URLs HTTPS finales y configura CORS cuando el receptor sea un navegador.

## Crear un paquete

Desde la raíz del paquete, después de resolver sus dependencias:

```sh
dart run tool/pack_vrlz.dart escena.glb galeria.vrlz \
  --id org.example.galeria --title "Mi galería" \
  --description "Escena portable" \
  --camera-position 0,1.6,6 --camera-target 0,1,-6
```

El empaquetador produce el manifiesto y su SHA-256, escribe STORE y ejecuta el mismo validador usado al cargar. No convierte GLB incompatibles ni sobrescribe un archivo existente. El asset `stereo_gallery.vrlz` de la aplicación de ejemplo se empaqueta a partir de la escena de comparación propia de VRLizate.


Para una demo ya integrada en el host:

```sh
dart run tool/pack_vrlz.dart --builtin flutter_scene_room cuarto.vrlz \
  --id org.example.cuarto --title "Cuarto integrado" \
  --description "Una experiencia incluida en el anfitrión"
```

El comando nuevo exige extensión `.vrlz`. `tool/pack_vrz.dart` se mantiene como alias de compatibilidad y permite salidas `.vrz` solo para escenas v1; no hace falta reescribir esos paquetes para que el lector nuevo acepte sus bytes.

## Límite entre datos y aplicaciones descargables

Flutter compila Dart de las aplicaciones móviles release a código nativo AOT. Sus componentes diferidos Android forman parte de la distribución compilada mediante el Android App Bundle: no son un sistema para cargar paquetes Flutter o plugins arbitrarios desde una URL. Las bibliotecas nativas también dependen de la plataforma y arquitectura. Por eso el perfil de escena v1 descarga datos para una capacidad ya presente en el anfitrión.

Una futura aplicación declarativa podría añadir escenas, navegación, eventos y acciones mediante un intérprete limitado y versionado incluido en Apps. HTML/JavaScript en WebView sería otro runtime, con aislamiento, origen, puente de APIs y reglas de tienda propios; no equivale a cargar widgets Flutter nativos. Apple establece restricciones sobre código descargado y contempla determinadas miniapps HTML5/JavaScript bajo condiciones adicionales; Google Play restringe la descarga externa de ejecutables nativos y trata de manera diferente cierto código interpretado. La aceptación en tiendas requiere evaluar la implementación concreta y las reglas vigentes, no solo la extensión `.vrlz`.

Posibles ampliaciones futuras —DEFLATE, texturas, recursos adicionales, firma del autor, UI declarativa o un runtime web— necesitan una nueva versión/capacidad, límites y pruebas. Un lector v1 debe rechazarlas hasta que su anfitrión las implemente.

## Referencias oficiales

- [glTF 2.0 y contenedor GLB, Khronos](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html): estructura del recurso que VRZ restringe.
- [Compilación release de Flutter](https://docs.flutter.dev/resources/faq) y [componentes diferidos Android](https://docs.flutter.dev/perf/deferred-components): límites del código compilado y su distribución.
- [Compilación Dart](https://dart.dev/tools/dart-compile): formatos de salida y plataformas objetivo.
- [Networking en Flutter](https://docs.flutter.dev/data-and-backend/networking): permisos Android y entitlements macOS.
- [ZIP path traversal, Android Security](https://developer.android.com/privacy-and-security/risks/zip-path-traversal): motivación para rechazar rutas y evitar extracción.
- [Apple App Review Guidelines, 2.5.2 y 4.7](https://developer.apple.com/app-store/review/guidelines/): reglas de código descargado y miniapps.
- [Política de Google Play sobre abuso de dispositivos y redes](https://support.google.com/googleplay/android-developer/answer/18258653?hl=en): distribución de ejecutables y código interpretado.
- [Contenido local en Android WebView](https://developer.android.com/develop/ui/views/layout/webapps/load-local-content): referencia para un eventual runtime web con origen controlado.
