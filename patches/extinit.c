/*
 * extinit.c - Registro de extensiones enlazadas estaticamente.
 *
 * Con --with-static-linked-ext, Ruby no puede cargar .so en tiempo de
 * ejecucion: cada extension debe declararse aqui para que 'require' la
 * encuentre. El generador de Ruby produjo un Init_ext() vacio porque la
 * fase build-ext nunca llego a completarse, asi que lo escribimos a mano.
 *
 * zlib es imprescindible: los .rxdata de RPG Maker (mapas, scripts, datos)
 * estan comprimidos con Zlib::Deflate.
 */
#include "ruby/ruby.h"

#define init(func, name) {          \
    extern void func(void);         \
    ruby_init_ext(name".so", func); \
}

void ruby_init_ext(const char *name, void (*init)(void));

void Init_ext(void)
{
    init(Init_zlib,     "zlib");      /* .rxdata comprimidos */
    init(Init_stringio, "stringio");  /* usado por Essentials y por Marshal */
    init(Init_strscan,  "strscan");   /* analisis de PBS */
}
