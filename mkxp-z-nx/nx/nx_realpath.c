/*
 * nx_realpath.c — realpath() sin prefijo de dispositivo.
 *
 * En Horizon el directorio de trabajo es "sdmc:/switch/pokemon-anil". Ruby
 * decide si una ruta es absoluta con rb_is_absolute_path, que en compilaciones
 * POSIX es literalmente *p == '/'. Con el prefijo del dispositivo delante, la
 * respuesta es "no", y eso rompe require():
 *
 *   1. rb_construct_expanded_load_path pasa cada entrada de $LOAD_PATH por
 *      realpath(). newlib devuelve la forma canonica CON dispositivo, asi que
 *      "lib" acaba siendo "sdmc:/switch/pokemon-anil/lib".
 *   2. rb_find_file_ext expande esa entrada otra vez para buscar el fichero.
 *      Como no empieza por "/", le antepone el directorio actual.
 *   3. Resultado: abre
 *      "sdmc:/switch/pokemon-anil/sdmc:/switch/pokemon-anil/lib/set.rb".
 *
 * Poner la ruta absoluta a mano en mkxp.json no sirve: realpath vuelve a
 * meter el "sdmc:" en el paso 1. Hay que quitarlo aqui.
 *
 * Quitarlo no pierde informacion: newlib resuelve las rutas sin dispositivo
 * contra el dispositivo por omision, que en homebrew es la propia SD. Se
 * comprobo midiendo: open("/switch/pokemon-anil/lib/socket.rb") devuelve un
 * descriptor valido igual que la forma con "sdmc:".
 */
#include <ctype.h>
#include <stdlib.h>
#include <string.h>

char *__real_realpath(const char *path, char *resolved);

char *__wrap_realpath(const char *path, char *resolved)
{
    char *r = __real_realpath(path, resolved);
    char *sep;
    size_t i;

    if (!r)
        return r;

    /* Un prefijo de dispositivo es <nombre>:/ con el nombre alfanumerico. */
    sep = strchr(r, ':');
    if (!sep || sep == r || sep[1] != '/')
        return r;

    for (i = 0; r + i < sep; i++) {
        if (!isalnum((unsigned char)r[i]) && r[i] != '_' && r[i] != '-')
            return r;
    }

    memmove(r, sep + 1, strlen(sep + 1) + 1);
    return r;
}
