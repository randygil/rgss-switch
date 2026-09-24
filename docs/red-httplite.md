# La red en la consola: `HTTPLite` por HTTP y HTTPS

mkxp-z trae un módulo `HTTPLite` (`binding/http-binding.cpp` → `src/net/net.cpp`)
con `get`, `post`, `post_body` y `JSON`. Es lo que usan los plugins que hablan
con un servidor, como el de guardado en la nube (JSON por HTTPS contra un
servidor NestJS, cuerpos de varios megas en base64). **En Switch no funcionaba
nada de eso**, y por dos motivos a la vez:

1. **No había sockets.** En Horizon los sockets son del servicio `bsd:u`, y
   hasta que alguien llama a `socketInitialize()` `socket()` devuelve -1 y
   `getaddrinfo()` no resuelve. Nadie la llamaba, así que ni `http://` llegaba.
2. **No había TLS.** `net.cpp` iba sobre cpp-httplib, que sólo sabe HTTPS con
   OpenSSL, y en Switch no hay OpenSSL: todo `https://` moría en
   `Failed to create HTTP client`.

## Qué cambió

| Dónde | Qué |
|---|---|
| `mkxp-z-nx/nx/nx_red.c` | `userAppInit` abre los sockets (`socketInitializeDefault`) y `userAppExit` los cierra. **No es fatal**: si falla, el juego arranca igual y el error de cada petición lo cita. Deja `[red] sockets de libnx listos (bsd:u)` en `mkxp-boot.log`. Cuesta unos 2 MB de memoria de transferencia. |
| `patches/mkxpz-net-curl.patch` | `net.cpp` reescrito sobre la **libcurl 7.69.1 de portlibs**, cuyo TLS es el servicio `ssl` del sistema (certificados raíz de la consola). La interfaz de `net.h` no cambia, y por tanto tampoco la API de Ruby. |
| `mkxp-z-nx/Makefile` | `-lcurl` delante de `-lz` y `-DCURL_STATICLIB`. |
| `runtime/diagnostico/nx-red.rb` | La sonda que lo prueba todo (abajo). |

Cómo se comporta ahora `HTTPLite`:

- **Verificación del certificado ENCENDIDA** (par y nombre). El original de
  mkxp-z la apagaba; aquí el almacén es el de la consola y no hay motivo para
  aceptar cualquier cosa. Un servidor propio necesita un certificado de verdad
  (Let's Encrypt sirve); uno autofirmado se rechaza.
- **Plazos**: 10 s para conectar, 60 s para la petición entera. Una subida que
  tarde más se corta con `MKXPError` (código 28 de curl).
- **Cuerpos binarios** en los dos sentidos. `post_body` ya no corta el cuerpo en
  el primer byte 0.
- Cabeceras propias (`Authorization`, etc.) en las tres llamadas; `Content-Type`
  la pone `post_body` salvo que venga en las cabeceras. Se manda
  `User-Agent: mkxp-z/2.4.2 (rgss-switch)` si no se da otro, y se acepta gzip
  (el cuerpo llega ya descomprimido).
- Redirecciones: `get` y `post` las siguen sólo si el tercer argumento es
  `true` (como en mkxp-z); `post_body` las sigue siempre (también como en
  mkxp-z).
- La respuesta es el mismo `Hash`: `:status`, `:body`, `:headers` (sólo las de
  la respuesta final). El cuerpo sale UTF-8 si `Content-Type` es JSON, texto,
  HTML...; ahora se reconoce aunque el servidor la mande en minúsculas.
- Los errores son `MKXPError` con el mismo formato:
  `Failed to GET <url> (<código de curl>: <texto>)`. Ejemplos medidos:
  `7: Failed to connect ...` (puerto cerrado), `6: Couldn't resolve host ...`
  (sin DNS), `28` (plazo agotado).
- La petición corre con el GVL suelto, y ya **no toca Ruby sin él**: el
  original armaba el `Hash` y lanzaba la excepción dentro de
  `rb_thread_call_without_gvl`.

## Ficheros: `File.rename` no pisa

Medido en el emulador con la misma sonda: `Dir.mkdir` (también anidado),
escribir, `File.delete` y `Dir.rmdir` en una subcarpeta de la del juego van
bien, y `File.rename` a un nombre libre también. Pero **`File.rename` encima de
un fichero que ya existe falla con `Errno::EEXIST`**: el sistema de ficheros de
Horizon no reemplaza el destino como hace POSIX. Un plugin que escriba
`partida.tmp` y luego la renombre sobre `partida.json` tiene que borrar antes
`partida.json` (y asumir que entre las dos operaciones no hay atomicidad).

## Cómo se prueba

1. Un servidor de prueba en el PC con cuatro rutas: `/eco` (devuelve en JSON el
   método, la URL, las cabeceras y la longitud del cuerpo, con
   `content-type` en minúsculas), `/binario` (los 256 valores de byte),
   `/espejo` (devuelve el cuerpo tal cual) y `/redir` (302 a `/eco`):
   `node runtime/diagnostico/nx-red-servidor.js`, que escucha en
   `0.0.0.0:8787` y apunta cada petición en la consola.
2. Una carpeta de juego de prueba con su propio slug —nunca la de un juego con
   partidas—: `Game.ini`, un `Data/Scripts.rxdata` de un solo script
   (`loop { Graphics.update }`), `Graphics/` y `Audio/` aunque vayan vacías (la
   pantalla de aviso las pide), `lib/` con los shims y la stdlib de cualquier
   otro juego ya empaquetado, `nx-red.rb` en `lib/` y en `preloadScript` detrás
   de `lib/nx-compat.rb`.
3. En el emulador, `enable_internet_access` a `true` en
   `%APPDATA%\Ryujinx\Config.json` (con `false` Ryujinx no resuelve nombres y
   todo `https://` falla con el código 6; la red local sí va). En la consola,
   `red-servidor.txt` en la carpeta del juego con `http://<IP del PC>:8787`.
4. `./iterate.sh <slug>` y leer las líneas `[red]` de `mkxp-ruby.log`. Termina
   en `[red] FIN n/m`.

Resultado en Ryujinx el 24 de septiembre de 2026 (b26): **16/16**. GET con
cabeceras y JSON en UTF-8, binario de 256 bytes idéntico, 2,7 MB de JSON en
base64 ida y vuelta en ~1,1 s, cuerpo con bytes 0, formulario, redirección
seguida y sin seguir, puerto cerrado como excepción en ~2 s, HTTPS GET a
google.com, httpbin.org y example.com, HTTPS POST a httpbin.org, y los
ficheros de arriba.

## Lo que queda por ver en una consola de verdad

- **Que un certificado inválido se rechaza.** Es la prueba 9 de la sonda, y
  sólo corre si existe `red-certificados-malos.txt` en la carpeta del juego,
  porque **en Ryujinx cierra el emulador**: su servicio `ssl` va sobre el
  `SslStream` de .NET, que sí verifica, pero el fallo sale como una excepción
  sin recoger (`AuthenticationException: ... UntrustedRoot`) en vez de volver
  como error. Ojo con esto al probar en el emulador contra un servidor con
  certificado autofirmado. Además, curl-libnx pide al servicio
  `SkipDefaultVerify = true` junto con `PeerCa | HostName | DateCheck`; el
  emulador ignora las dos cosas y sólo la consola dice cuál manda.
- Que la conexión Wi-Fi real (nifm) y la resolución de nombres del sistema van
  igual que en el emulador, que usa la pila de red del PC.
- Una subida de varios megas por Wi-Fi: si pasa de 60 s, el plazo la corta.
- Como applet (hbmenu desde el álbum, ~448 MB), que los 2 MB de los sockets no
  cambian nada.
