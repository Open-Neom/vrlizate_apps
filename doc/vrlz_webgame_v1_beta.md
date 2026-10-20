# Webgame .vrlz — v1 beta

`vrlizate.webgame.v1` agrega un perfil explícito de código web compilado:
HTML, JavaScript y WASM. No ejecuta Dart AOT, plugins ni bibliotecas nativas
extraídos del paquete. Requiere un navegador sandbox del host y capacidades
`["web.sandbox"]`; declarar esa capacidad no crea por sí solo el sandbox.
Los perfiles estáticos anteriores conservan sus restricciones.

## Índice y entrega incremental

El `.vrlz` es un ZIP STORE con **solo manifest.json**, máximo 512 KiB. El mismo
`VrlzPackageLoader`, `VrlzWebCatalogLoader`, `VrlzDirectoryStore` y biblioteca lo
reconocen como `VrlzPackageKind.webgame`. No hay otro mecanismo de descubrimiento.
El índice contiene ID/título, revisión inmutable, entrada HTML, una URL base de
contenido, perfil de mando, procedencia/licencias y unidades. Cada archivo tiene
ruta canónica, longitud exacta, SHA-256 y MIME permitido. Ningún nombre representa
una ruta que se extraiga al sistema de archivos.

```dart
final package = await packageLoader.load(indexUrl);
final manifest = package.webGameManifest!;
final resources = VrlzWebGameLoader(
  manifest,
  cache: VrlzWebGameFileCache(appPrivateCachePath), // vrlizate_apps_io.dart
);
await resources.prefetchStartup();
final html = await resources.readFile(manifest.entrypoint);
// El servidor aislado del host entrega estos bytes y el MIME manifest.file(path).
final map = await resources.readFile('assets/maps/first_area.json');
resources.close();
```

`prefetchUnit(id)` es opcional. `readFile(path)` descarga un recurso únicamente
cuando se solicita, verifica su longitud/hash **antes de entregarlo** y permite
que las peticiones originales del juego pidan sus mapas y recursos. Una unidad
puede corresponder a un nivel si el desarrollador lo ha declarado: no se deduce
una historia ni un cambio de nivel por nombres de archivos. Si el juego original
precarga todo, este contenedor no cambia automáticamente ese comportamiento.

Límites: 128 unidades, 4.096 archivos, 64 MiB por archivo y 1 GiB total. Las peticiones simultáneas de una misma ruta comparten una descarga verificada. La concurrencia
HTTP es dos por defecto (máximo cuatro) y la cola admite 128 archivos (máximo
1.024). Cada respuesta tiene límite de bytes y plazo total; no sigue redirects.
Los bytes se leen con el transporte compartido de paquetes/catálogos.

`contentBaseUrl` es un directorio HTTPS terminado en `/`. El modo de desarrollo
admite HTTP **solo** para `127.0.0.1` o `::1` y requiere
`VrlzWebGameLoader(..., allowLocalHttp: true)`. Un índice no puede activar esa
opción. Credenciales y fragmentos se rechazan. Archivos fuera del índice, rutas
absolutas, segmentos `..`, percent-encoding, barras invertidas y alias de nombres
por mayúsculas/minúsculas se rechazan antes de pedir contenido.

## Caché y modo offline

`VrlzWebGameMemoryCache` y `VrlzWebGameFileCache` tienen cuota de bytes y reemplazo
LRU. La persistente usa nombres `<sha256>.chunk`, escritura temporal con rename,
cuota adicional de cantidad y revalidación del hash/longitud al leer. No sigue
symlinks de entradas ni elimina archivos ajenos al caché. El directorio debe ser
privado de la app, con la misma limitación de carreras de filesystem que tiene
`VrlzDirectoryStore`. `prune()` en la implementación IO aplica la cuota también
al abrir un caché previo. Los contadores se actualizan cuando se realizan sus
operaciones; construir un objeto no escanea disco.

`isUnitCached(id)` comprueba la integridad sin usar la red. Se puede reabrir sin
conexión cuando todos los archivos necesarios siguen en el caché: tener solo la
unidad startup no garantiza que fuentes, CanvasKit u otros recursos solicitados
después estén disponibles. `prefetchUnit` o las visitas reales pueden preparar
más contenido. Si el tamaño supera la cuota, LRU puede desalojar recursos y el
host debe mostrar ese estado honestamente. El guardado del juego es un contrato
del host separado del caché descartable.

## Mando, viewport y red

`controllerProfile` admite `dpad`, `platformer`, `pointer`, `chess`, `pinball`,
`rpg` y `driving`. `controls` es un mapa opcional desde claves de protocolo
`UP/DOWN/LEFT/RIGHT/A/X/Y/L/R/GRIP/START/SELECT` hacia valores acotados de
`KeyboardEvent.code`, como `ArrowUp`, `Enter`, `Space` o `KeyZ`. No contiene código
JS ni expresiones. **B permanece reservado para Home**; el host traduce y libera
los botones al pausar, salir o perder la conexión.

`viewportWidth`/`viewportHeight` son opcionales, por defecto 1280 × 720. Cada eje
está entre 240 y 1920 y el máximo conjunto es 1920 × 1080 píxeles. Permite, por
ejemplo, 720 × 960 para una interfaz vertical sin presentarla estirada.

`networkOrigins` es una lista opcional de hasta ocho orígenes HTTPS exactos para
`connect-src`. Por defecto está vacía. No acepta comodines, rutas, consultas,
credenciales ni esquemas de socket; declarar un origen no otorga permisos
nativos. El host decide qué catálogo/confianza autoriza esa red y debe aplicar
la política del navegador, bloquear navegación externa, puente nativo genérico,
permisos de cámara/micrófono/ubicación y service workers, y evitar cualquier
fetch que salte el lector verificado. Este SDK entrega recursos verificados;
la implementación del sandbox pertenece al host.

## Autoría y referencias

Son obligatorios `license`, `assetNotice`, `sourceUrl`, `licenseUrl` y
`sourceArchiveUrl`. Las URLs de procedencia usan HTTPS. En pruebas locales,
el archivo de fuentes puede usar el mismo origen HTTP de loopback que el
contenido; el transporte sigue requiriendo habilitación explícita de desarrollo.
El archivo de fuentes
publicado debe corresponder a la revisión y modificaciones distribuidas, con
scripts de compilación y avisos pertinentes. No basta con enlazar únicamente el
upstream sin las modificaciones de la adaptación. Estos campos son declaraciones
del editor: ni los hashes ni el esquema confirman derechos de arte/audio, marcas
o cumplimiento de licencias. El catálogo existente verifica el hash del índice,
que fija los hashes de sus recursos; no es una firma de autor.

## Empaquetador local

```sh
dart --packages=.dart_tool/package_config.json tool/pack_webgame.dart \
  /ruta/build/web /ruta/staging/game.vrlz \
  --content-output /ruta/staging/game-content \
  --content-base-url https://hosting.example/games/game/commit-123/ \
  --id org.example.game --title "Mi juego" --revision commit-123 \
  --controller-profile dpad --license MIT \
  --asset-notice-file /ruta/AVISOS.txt \
  --source-url https://github.com/autor/game \
  --license-url https://hosting.example/sources/game/LICENSE \
  --source-archive-url https://hosting.example/sources/game-commit-123.zip
```

Se requiere un build release con recursos del renderer locales
(`flutter build web --no-web-resources-cdn`). El comando copia a un staging nuevo,
normaliza `<base href="/">` a `./` en esa copia **antes** del hash, conserva el
build original y publica localmente el índice solo después de validar. Rechaza
symlinks y destinos existentes. No sube nada a hosting.

Por defecto agrupa entrada y JS/WASM/CSS raíz en `startup`, y el resto en
`resources` solicitado bajo demanda. Para niveles reales, `--units-json FILE`
acepta una lista de `{id, startup, paths}` que debe cubrir todos los archivos
exactamente una vez. `--controls-json`, `--network-origins-json`,
`--viewport-width` y `--viewport-height` completan opciones del host. Nada de
esto convierte un demo pequeño en la campaña original ni sustituye una prueba
completa de juego, guardado, controles, sandbox y rendimiento en teléfono.

### Optional browser requirements

`requirements` is an optional list containing at most three distinct values:
`wasm-gc`, `webgl2`, `cross-origin-isolation`. They describe browser capabilities,
not additional native permissions. The host checks them in its isolated origin
before navigating to the game entrypoint, and reports unsupported requirements
without claiming the game has loaded. For example, the original Dartchess int64
engine requires Dart WasmGC rather than an inaccurate JavaScript port.

Omitted requirements default to an empty list. Serialization omits an empty list,
so existing webgame v1 indices retain their bytes. Unknown names, duplicates,
non-list values and more than three entries are invalid. The packer accepts a
JSON list through `--requirements-json FILE`; no filenames or engine guesses
implicitly add requirements. This remains format v1 beta.
