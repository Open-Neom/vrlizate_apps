## Sin publicar

- Transporte HTTPS por rangos para lugares `.vrlw`, con ETag fuerte, control de
  tamaño/tiempo y validación de respuestas parciales; reutiliza el lector y la
  caché de `vrlizate_world` sin modificar los perfiles `.vrlz`.

- Empaquetado comunitario de NES con `tool/pack_vrlz.dart --nes`, aviso completo
  de licencia y procedencia HTTPS. Rechaza perfiles no admitidos, opciones
  incompatibles y sobrescritura de paquetes existentes.

- Perfil experimental retro 2.5D v4 (`vrlizate.retro2d.v1`),
  `VrlzPackage.encodeRetro`, `retroBundle`, manifiesto con licencia e integridad,
  nivel inmutable de casillas y validación de límites/entidades.
- Importador acotado de Tiled JSON ortogonal finito para autoría independiente;
  exactamente terreno y entidades, sin cargar archivos externos ni scripts.
- Reutiliza descubrimiento/importación/HTTPS para juegos originales y mantiene
  los otros perfiles. Home mínimo informa cuando carece de runtime retro.

- Perfil experimental NES v3 (`vrlizate.nes.v1`) para cartuchos iNES NROM
  independientes del host: `VrlzPackage.encodeNes`, `nesBundle` y metadatos.
- Validación estricta de ROM, SHA-256, licencia completa, fuente HTTPS y conjunto
  de archivos; reutiliza importación, descubrimiento e índices existentes.
- No incorpora ni descarga cores nativos; el anfitrión decide si tiene instalado
  el runtime. Los perfiles de escena v1 y demo integrada v2 se conservan.

## 0.1.0

- Formato `.vrlz`: escenas portátiles y referencias a demos integrados.
- Descubrimiento local, importación explícita y catálogos HTTPS verificados.
- Controlador de biblioteca independiente de Home y de la navegación.
- Visor opcional y herramientas de empaquetado/índice.
- APIs extraídas del prototipo de Home para mantener separada la presentación.
