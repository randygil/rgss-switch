/*
 * hello-ruby-nx - CRuby 3.1.7 como homebrew nativo de Nintendo Switch.
 * Hito H2 del porteo: banco de pruebas del interprete, aislado del motor.
 * Nacio con Pokemon Anil, que fue el primer juego, y sigue sirviendo para
 * comprobar que CRuby arranca en la consola sin arrastrar mkxp-z entero.
 *
 * Los resultados se emiten por TRES vias, para poder verificarlos tanto en
 * consola real como en emulador:
 *   1. printf  -> framebuffer (visible en pantalla)
 *   2. archivo -> /ruby-test-results.txt en la SD
 *   3. svcOutputDebugString -> log del emulador
 */
#include <switch.h>
#include <stdio.h>
#include <string.h>
#include <ruby.h>

static FILE *g_log = NULL;

static void emit(const char *line)
{
    printf("%s\n", line);
    if (g_log) { fprintf(g_log, "%s\n", line); fflush(g_log); }
    svcOutputDebugString(line, strlen(line));
    consoleUpdate(NULL);
}

static void emitf(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    emit(buf);
}

static VALUE safe_to_s(VALUE o) { return rb_obj_as_string(o); }

static int g_pass = 0, g_fail = 0;

static void run(const char *label, const char *code)
{
    int state = 0;
    VALUE v = rb_eval_string_protect(code, &state);
    if (state) {
        VALUE err = rb_errinfo();
        rb_set_errinfo(Qnil);
        const char *cname = "?";
        if (!NIL_P(err)) cname = rb_obj_classname(err);
        int s2 = 0;
        VALUE m = rb_protect(safe_to_s, err, &s2);
        emitf("  [FALLO] %-11s %s: %s", label, cname,
              (!s2 && RB_TYPE_P(m, T_STRING)) ? RSTRING_PTR(m) : "(mensaje no obtenible)");
        g_fail++;
    } else {
        int s2 = 0;
        VALUE s = rb_protect((VALUE(*)(VALUE))rb_obj_as_string, v, &s2);
        emitf("  [ OK  ] %-11s %s", label,
              (!s2 && !NIL_P(s)) ? StringValueCStr(s) : "(sin repr)");
        g_pass++;
    }
}

int main(int argc, char **argv)
{
    consoleInit(NULL);
    padConfigureInput(1, HidNpadStyleSet_NpadStandard);
    PadState pad;
    padInitializeDefault(&pad);

    g_log = fopen("/ruby-test-results.txt", "w");

    emit("=== CRuby 3.1.7 en Nintendo Switch (Horizon OS) ===");
    emit("");

    ruby_sysinit(&argc, &argv);
    {
        RUBY_INIT_STACK;
        ruby_init();

        /* --- SECUENCIA DE ARRANQUE COMPLETA -----------------------------
         * ruby_init() + ruby_init_loadpath() basta para el nucleo del
         * lenguaje, pero NO ejecuta ruby_opt_init() (ruby.c:1636), que es
         * quien hace:
         *     Init_ext();            <- extensiones estaticas (zlib, ...)
         *     rb_call_builtin_inits();
         *     ruby_init_prelude();   <- carga gc.rb, marshal.rb, io.rb...
         *
         * Sin eso, GC.start / GC.count / Marshal.load no existen (estan
         * definidos en Ruby, no en C) y require de extensiones da LoadError.
         * ruby_opt_init es static: solo se alcanza via ruby_options(), que
         * es justo lo que hace el main.c del propio Ruby.
         *
         * --disable-gems evita que el prelude intente cargar RubyGems desde
         * disco: aqui no hay stdlib en la SD.
         */
        static char a0[] = "ruby";
        static char a1[] = "--disable-gems";
        static char a2[] = "-e";
        static char a3[] = "";
        static char *rargv[] = { a0, a1, a2, a3 };
        void *node = ruby_options(4, rargv);
        int exec_state = 0;
        if (ruby_executable_node(node, &exec_state)) {
            ruby_exec_node(node);
        }

        run("version",   "RUBY_VERSION");
        run("plataforma","RUBY_PLATFORM");
        run("aritmetica","(1..100).reduce(:+)");
        run("cadenas",   "'rgss-switch'.reverse.upcase");
        run("bloques",   "[3,1,2].sort.map { |n| n * n }.inspect");
        run("hash",      "{a: 1, b: 2}.transform_values { |v| v * 10 }.inspect");
        run("struct",    "Struct.new(:x, :y).new(4, 5).to_a.inspect");
        run("excepcion", "begin; raise 'capturada'; rescue => e; e.message; end");
        /* Las decisivas primero: Essentials las usa para leer los .rxdata.
         * El GC va al FINAL porque se sospecha que dana la VM. */
        run("marshal",   "Marshal.load(Marshal.dump({s: [1,2], t: 'x'})).inspect");
        run("require",   "require 'zlib'");
        run("zlib",      "Zlib::Inflate.inflate(Zlib::Deflate.deflate('rxdata'))");
        run("stringio",  "require 'stringio'; io = StringIO.new; io.puts 'ok'; io.string.strip");
        run("strscan",   "require 'strscan'; StringScanner.new('ab').scan(/a/)");
        run("rxdata",    "Marshal.load(Marshal.dump(Zlib::Inflate.inflate(Zlib::Deflate.deflate('script'))))");
        run("alloc",     "(1..5000).map { |i| 'x' * 40 }.size");
        run("GC.count",  "GC.count");
        run("GC.stat",   "GC.stat[:count]");
        run("GC.start",  "GC.start; 'sobrevivio'");
        run("post-GC",   "(1..10).map { |i| i * 2 }.sum");

        /* --- Parches de compatibilidad mkxp-z ---------------------------
         * Estas tres FALLAN en un Ruby 3.x sin parchear. Son exactamente
         * los comportamientos de Ruby 1.8 que el codigo RGSS da por hechos.
         */
        run("privado",   "class Foo; private; def secreto; 'accesible'; end; end; Foo.new.secreto");
        run("protegido", "class Bar; protected; def prot; 'ok'; end; end; Bar.new.prot");
        run("superclase","class A1; end; class B1 < A1; end; class C1; end; "
                         "begin; eval('class B1 < C1; end'); 'permitido'; "
                         "rescue TypeError => e; 'RECHAZADO: ' + e.message; end");
        run("sprintf",   "$DEBUG = true; r = (sprintf('%d', 1, 2, 3) rescue 'RECHAZADO'); $DEBUG = false; r");

        emit("");
        emitf("=== RESULTADO: %d OK, %d fallos ===", g_pass, g_fail);
        emit("");

        if (g_log) { fclose(g_log); g_log = NULL; }

        printf("\n  Pulsa + para salir (autosalida en 20 s)\n");
        consoleUpdate(NULL);

        int frames = 0;
        while (appletMainLoop() && frames++ < 1200) {
            padUpdate(&pad);
            if (padGetButtonsDown(&pad) & HidNpadButton_Plus) break;
            consoleUpdate(NULL);
        }
        ruby_cleanup(0);
    }

    consoleExit(NULL);
    return 0;
}
