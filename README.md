# vrlizate_apps

Paquetes de experiencias `.vrlz`, descubrimiento local y catálogos HTTPS para
VRlizate. Este módulo no depende de Home ni navega hacia juegos: devuelve datos
validados al anfitrión. El host elige las fuentes, la UI y los runtimes que admite.

| Componente | Responsabilidad |
| --- | --- |
| `vrlizate_apps.dart` | Paquetes, manifiestos, cargadores HTTPS e índice web |
| `vrlizate_apps_io.dart` | Directorio local, importación y snapshots; stub en web |
| `vrlizate_apps_library.dart` | Estado observable y coordinación de fuentes, sin widgets |
| `vrlizate_apps_viewer.dart` | Visor opcional de escenas estáticas en Flutter Scene |
| `vrlizate_home` (otro paquete) | Presentación de listas y acciones suministradas por el host |
| `VRlizate_app` | Permisos, rutas, servicios y lista de demos compilados disponibles |

## Cuatro tipos de paquete

- **Escena v1**: ZIP STORE con `manifest.json` y `scene.glb`, geometría/materiales
  básicos o unlit y cámara inicial. Modelo estático autocontenido. El subconjunto
  actual excluye texturas, animaciones, recursos externos y código ejecutable.
- **Demo integrada v2**: ZIP con manifiesto `vrlizate.builtin.v1`. Referencia un
  `demoId` que el host debe tener compilado. No empaqueta su implementación Dart
  ni bibliotecas nativas, no reduce el ejecutable y no instala juegos arbitrarios.
- **Cartucho NES v3, experimental**: ZIP STORE con `manifest.json` y `game.nes`.
  Incluye una ROM iNES NROM, SHA-256, aviso completo de licencia y URL HTTPS de
  las fuentes. El host interpreta el cartucho usando su core ya compilado;
  este paquete no distribuye un core, un APK ni una aplicación Flutter AOT.
  Solo admite PRG de 16/32 KiB y CHR de 8 KiB, sin trainer ni batería.
  Un host sin el runtime `vrlizate.nes.v1` debe indicar que no está instalado.
- **Juego retro 2.5D v4, experimental**: ZIP STORE con `manifest.json` y
  `level.json`. Nivel original de plataformas o disparos, entre 16 × 8 y
  128 × 24 casillas, hasta 256 KiB de contenedor, con licencia completa y SHA-256.
  El runtime `vrlizate.retro2d.v1` del host convierte estas reglas limitadas en
  una experiencia 2.5D; no descarga código Dart ni reutiliza ROM comerciales.

Un proyecto independiente del SDK crea el cartucho NES mediante
`VrlzPackage.encodeNes(romBytes: ..., id: ..., title: ..., license: ...,
sourceUrl: ...)`. `license` conserva el texto completo y los avisos aplicables,
no solo el identificador SPDX. La validación comprueba el formato y la integridad;
no certifica derechos de distribución. El cartucho conserva su imagen 2D:
la pantalla gigante y el entorno VR corresponden al runtime del anfitrión.

También se puede empaquetar un homebrew o demo autorizado sin escribir un
exportador Dart propio:

```sh
dart run tool/pack_vrlz.dart --nes mi_demo.nes dist/mi_demo.vrlz \
  --id org.mi-comunidad.mi-demo --title "Mi demo" \
  --description "Un prototipo de la comunidad" \
  --license-file LICENSES.txt --source-url https://example.org/mi-demo
dart run tool/index_vrlz.dart dist
```

`LICENSES.txt` debe conservar los avisos del juego y sus componentes, incluidos
arte y audio. El empaquetador rechaza cartuchos fuera del perfil NROM, opciones
de otro runtime y archivos de salida existentes. Se mantiene el API Dart para
los proyectos independientes del SDK. Distribuir un paquete con licencia
declarada no demuestra la titularidad de su contenido.

El hub puede incorporar estos juegos instalados a su biblioteca espacial:
`VRlizate_app` escanea al entrar, reanudar y volver de una experiencia; la vista
Home recibe tarjetas y callbacks. NES requiere el runtime Android del piloto.
Los parches IPS/BPS, la selección de ROM base y los emuladores SNES/Sega todavía
no forman parte de este perfil: no se pueden renombrar a `.vrlz` y abrirlos.

Los proyectos independientes `vrlizate_examples/sunny_gardens` y
`vrlizate_examples/neon_bastion` usan `VrlzPackage.encodeRetro(level: ..., id: ...,
title: ..., license: ...)`. Incluyen mapas originales editables con Tiled y
exportador Dart. `VrlzTiledImporter.importLevel` transforma un subconjunto
explícito de Tiled JSON en `VrlzRetroLevel`; no analiza ni convierte ROMs.
El estado y el renderizado pertenecen al host; el paquete conserva su contenido.

La extensión pública es `.vrlz`. Algunos modelos/visores conservan nombres
internos `Vrz*` del prototipo v1; el visor también se exporta como
`VrlzSceneViewer`. No es un registro exclusivo de extensión ni un motor gráfico.

## Directorio local

```dart
final store = VrlzDirectoryStore(directoryChosenByHost);
final snapshot = await store.scan();
// Escanear no crea carpetas ni importa ejemplos.
final package = await store.load(snapshot.entries.first);
```

Solo inspecciona archivos `.vrlz` directamente dentro de la carpeta elegida.
Rechaza enlaces simbólicos, paquetes inválidos, IDs duplicados y excesos de
presupuesto (por defecto 128 paquetes, 32 MiB por archivo, 256 MiB de lectura y
4096 entradas de directorio). Un problema de archivo no oculta los demás; un
escaneo incompleto debe impedir lanzamiento hasta resolverlo. El controlador ya
aplica ese bloqueo. `load` vuelve a verificar los bytes y detecta cambios desde
el escaneo. Los snapshots retienen metadatos, no todos los modelos 3D en memoria.

`importBytes` valida antes de escribir, no sobrescribe archivos/IDs existentes y
publica desde un archivo temporal. Un marcador exclusivo coordina importaciones
entre isolates/procesos. Si un proceso muere mientras importa, conserva ese
marcador; el administrador solo debe eliminar `.vrlizate-import.lock` después de
confirmar que no hay otra importación activa. No se recuperan locks por timeout.
La carpeta pertenece al host: en móvil suele
estar en su sandbox. Apps no solicita acceso general al almacenamiento ni recorre
Downloads. La app puede aportar posteriormente un selector de documentos.

## Catálogo alojado en HTTPS

Una URL de carpeta no implica un listado HTTP. El servidor publica un índice:

```json
{
  "formatVersion": 1,
  "packages": [
    {
      "id": "org.example.gallery",
      "title": "Galería",
      "url": "gallery.vrlz",
      "sha256": "HASH_SHA256_DE_LOS_BYTES_DEL_ARCHIVO_COMPLETO"
    }
  ]
}
```

El hash real tiene 64 dígitos hexadecimales. `VrlzWebCatalogLoader.load` valida el
índice (máximo 256 KiB, 128 entradas) y resuelve URLs relativas. `loadPackage`
verifica SHA-256 del contenedor y coincidencia de ID antes de devolver contenido.
El título del índice es metadato de catálogo; tipo/capacidades solo se conocen
al verificar el paquete. Integridad no equivale a autenticación del autor.

En navegador se requieren CORS y URLs HTTPS finales: fetch puede rechazar
redirecciones antes de que el cliente inspeccione la respuesta. La importación a
carpetas es una capacidad nativa; el catálogo HTTPS no depende de `dart:io`.
Ofrecer este API no certifica que todos los demos/servicios del host compilen en
web. No hay hosting, publicación ni descarga automática al instalar el módulo.

## Lugares `.vrlw` por regiones

`VrlwHttpSource` añade transporte HTTPS para el formato experimental de lugares
de `vrlizate_world`. Exige rangos 206 exactos, un ETag fuerte estable y límites
de bytes/tiempo; no descarga el archivo completo cuando el servidor ignora el
rango. El lector abre cabecera e índice y el proveedor solicita solo las
regiones necesarias, reutilizando opcionalmente bloques comprimidos en caché.

Los perfiles y catálogos `.vrlz` anteriores se mantienen. El descubrimiento de
esa biblioteca no importa automáticamente `.vrlw`; el host elige la fuente,
fija el índice de confianza y registra los prototipos admitidos. El piloto del
bosque está integrado como asset en OpenWorld; no hay un hosting publicado ni
un selector general de lugares todavía. Consulta la
[especificación VRLW](../vrlizate_world/doc/vrlw_format.md), incluidos requisitos
de CORS y la diferencia entre contenido comprimido y código ejecutable.

## Integración con la interfaz

```dart
final library = VrlzLibraryController(
  openDirectory: () async => VrlzDirectoryStore(path),
  addExamples: installBundledExamples, // opcional, acción explícita
);
await library.refresh();
// El host adapta library.items a tarjetas Home.
// Al pulsar: await library.load(item.key), valida demoId/plataforma y navega.
```

El host llama `refresh` al entrar/reanudar/regresar o por acción del usuario.
No se inicia un watcher de disco. Cambiar de fuente invalida respuestas tardías;
el estado evita operaciones duplicadas. Dispose cierra únicamente loaders propios.
Los loaders inyectados son prestados. El host conserva servicios y navegación.

## Herramientas

Desde la carpeta del paquete, después de `flutter pub get`:

```sh
dart --packages=.dart_tool/package_config.json tool/pack_vrlz.dart scene.glb gallery.vrlz \
  --id org.example.gallery --title "Galería"
dart --packages=.dart_tool/package_config.json tool/index_vrlz.dart /ruta/experiencias
```

El empaquetador también admite descriptores builtin; consultar `--help`. En
`VRlizate_app`, `tool/export_vrlz_demos.dart` genera los 30 descriptores canónicos.
El generador de índices exige una carpeta completamente válida y usa hashes de
los archivos existentes. Publicar juntos `catalog.json` y los `.vrlz` permite
consultarlos desde la app; requiere un hosting configurado por el propietario.

[Especificación completa](doc/vrlz_format.md). [Licencia Apache-2.0](LICENSE).
Estado: prototipo local 0.1.0, sin publicación en pub.dev ni remoto Git configurado.

## Validación

```sh
flutter test
dart analyze lib test tool
```

Ejecutar tareas Flutter en serie con los otros paquetes por la caché compartida de
shaders de Flutter Scene. Las pruebas cubren formato adversarial, streaming HTTP,
catálogos, filesystem y coordinación; no miden FPS ni prueban GPU en smartphone.
