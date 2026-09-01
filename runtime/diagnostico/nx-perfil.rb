# nx-perfil.rb — quien se come el "resto" del cronometro de tirones.
#
# nx/nx_tirones.c reparte cada fotograma lento entre cinco embudos de C++
# (leer, descodificar, subir textura, leer pixeles, texto, blit) y llama
# "resto" a lo que no cae en ninguno. Si el resto domina, la culpa es del
# interprete, y ningun arreglo de graficos va a servir de nada.
#
# Pero "es Ruby" tampoco es una respuesta accionable. Hacen falta dos datos
# mas, y ninguno se puede sacar desde C:
#
#   1. Cuanto de ese resto es el recolector de basura. Un menu que crea diez
#      mil objetos paga una pausa entera, y eso se arregla de una manera muy
#      distinta a un metodo lento.
#   2. Que metodo esta corriendo cuando se atasca.
#
# Lo segundo se saca muestreando: un hilo aparte que cada 15 ms le pide la pila
# al hilo del juego y apunta el marco de arriba. Es un perfilador estadistico
# de doce lineas, y funciona por la misma razon por la que funcionan los de
# verdad: si un metodo se lleva el 80% del tiempo, se lleva el 80% de las
# muestras.
#
# Tiene un punto ciego que conviene tener presente: mientras el hilo del juego
# esta dentro de una llamada de C larga no suelta el GVL, asi que el muestreador
# no corre y esos tramos no salen aqui. No es un problema —son justo los tramos
# que ya cubren los embudos de C++— pero explica por que las muestras pueden
# sumar menos que el resto.
#
# Solo para diagnostico: no se carga en produccion.

module NXPerf
  UMBRAL   = 0.250   # el mismo que nx_tirones.c, para poder cruzar registros
  # 50 ms y no 15: en la consola el muestreador compite por el GVL con el hilo
  # del juego, y un instrumento que altera lo que mide no sirve. Veinte muestras
  # por segundo bastan de sobra para repartir un tiron de un segundo.
  MUESTREO = 0.050
  CIMAS    = 6       # cuantos metodos se listan por tiron

  @cuenta = Hash.new(0.0)
  @ultima = nil
  @ultimo = nil
  @cerrojo = Mutex.new

  class << self
    attr_reader :cerrojo

    # Cada muestra NO vale uno: vale el tiempo transcurrido desde la anterior.
    #
    # Contando muestras, el reparto sale al reves de la realidad. El muestreador
    # solo corre cuando el hilo del juego suelta el GVL, y FileTest.exist? lo
    # suelta en CADA llamada al sistema: sesenta oportunidades de muestreo en
    # los 130 ms que dura, contra las cinco o seis que da el reloj del
    # planificador en los 475 ms de Ruby puro que vienen despues. Asi salio en
    # la consola un "92% en exist?" que medido con el cronometro era el 20%.
    #
    # Pesando cada muestra por su intervalo el sesgo desaparece: sesenta
    # muestras apretadas en 130 ms suman 130 ms, y seis muestras espaciadas
    # sobre 475 ms suman 475.
    def apunta(pila)
      ahora = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @cerrojo.synchronize do
        trozo = @ultimo ? ahora - @ultimo : 0.0
        @ultimo = ahora
        next if pila.nil? || pila.empty?
        @cuenta[pila.first] += trozo
        @ultima = pila
      end
    end

    # Vacia el reparto sin mirarlo. Se llama al abrir cada fotograma: sin esto
    # las muestras se acumulan desde el tiron anterior y los porcentajes
    # describen los diez segundos que van entre uno y otro en vez del tiron.
    def vacia
      @cerrojo.synchronize do
        @cuenta = Hash.new(0.0)
        @ultima = nil
        @ultimo = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    def informe(donde, seg, gc, pasadas)
      cobra   # vacia el reparto aunque ya no se liste
      fsn, fss = NXFS.cobra
      rl, rn, rs = defined?(NXRutas) ? NXRutas.cobra : [0, 0, 0.0]
      NX.log(format("[perfil] %s %d ms | gc %d ms en %d pasadas"                     " | fs %d llamadas %d ms | rutas %dx %d ms (%d nuevas)"                     "",
                    donde, (seg * 1000).to_i, gc.to_i, pasadas,
                    fsn, (fss * 1000).to_i,
                    rl, (rs * 1000).to_i, rn))
      # Sin muestreador no hay reparto que listar: la linea de arriba lo dice
      # todo, y lo que no dice lo dicen los embudos de nx/nx_tirones.c.
    end

    # Devuelve el reparto y lo vacia, para que cada tiron hable solo de si mismo.
    def cobra
      @cerrojo.synchronize do
        top = @cuenta.sort_by { |_, t| -t }.first(CIMAS)
        total = @cuenta.values.sum
        pila = @ultima
        @cuenta = Hash.new(0.0)
        @ultima = nil
        @ultimo = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        [top, total, pila]
      end
    end
  end
end

# El reloj de basura cambio de sitio entre versiones de Ruby; se prueban las
# tres formas y se recuerda cual contesta.
module NXPerf
  @gc_ms =
    if GC.respond_to?(:total_time)                       then ->{ GC.total_time / 1_000_000.0 }
    elsif (GC.stat[:time] rescue nil)                    then ->{ GC.stat[:time].to_f }
    else                                                      ->{ 0.0 }
    end
  def self.gc_ms; @gc_ms.call; end
end

NX.log("[perfil] reloj de GC: #{begin NXPerf.gc_ms; 'disponible' rescue 'no'; end}")

# Las llamadas al sistema de ficheros que hace el propio Ruby.
#
# Esto es el agujero que dejaban los embudos de C++. mkxp-z NO redefine
# FileTest.exist? ni File.open: van a newlib y de ahi al devoptab de la SD, o
# sea una llamada al sistema de Horizon cada una. Medido en §5.48, cada una
# cuesta 0,85 ms en la consola —contra el microsegundo que cuesta en un PC—,
# asi que aqui no se puede confiar en el reloj del emulador: lo que vale es la
# CUENTA, que si es la misma en las dos maquinas.
#
# Y hay razon para sospechar: pbGetFileChar (0025_FileTests.rb) pregunta por
# "./Game.rgssad" —que nunca existe— antes de cada comprobacion, y luego abre
# el fichero y lee UN byte. pbResolveBitmap lo llama una vez por cada ruta
# candidata de cada imagen.
module NXFS
  @cuenta = 0
  @seg = 0.0
  class << self
    attr_accessor :cuenta, :seg
    def anota(t0)
      @cuenta += 1
      @seg += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    end
    def cobra
      c, s = @cuenta, @seg
      @cuenta = 0
      @seg = 0.0
      [c, s]
    end
  end
end

class << FileTest
  alias_method :nx_exist_sin_contar, :exist?
  def exist?(*a)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin   nx_exist_sin_contar(*a)
    ensure  NXFS.anota(t0)
    end
  end
end

class << File
  alias_method :nx_open_sin_contar, :open
  def open(*a, &b)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin   nx_open_sin_contar(*a, &b)
    ensure  NXFS.anota(t0)
    end
  end

  alias_method :nx_exist_sin_contar, :exist?
  def exist?(*a)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin   nx_exist_sin_contar(*a)
    ensure  NXFS.anota(t0)
    end
  end
end

# EL MUESTREADOR ESTA APAGADO, y conviene explicar por que antes de que a
# alguien le parezca buena idea volver a encenderlo.
#
# Dio dos respuestas seguidas, las dos falsas, y por dos sesgos distintos:
#
#   1. Contando muestras dijo "92% en exist?". Solo corre cuando el hilo del
#      juego suelta el GVL, y exist? lo suelta en cada llamada al sistema: se
#      llevaba sesenta oportunidades de muestreo en 130 ms contra seis en los
#      475 ms de Ruby puro siguientes.
#   2. Pesando cada muestra por su intervalo dijo "100%, 800 ms en exist?" en un
#      fotograma donde el cronometro directo media 60 llamadas y 123 ms. Pesar
#      arreglo el conteo pero empeoro la atribucion: si todas las despertadas
#      caen dentro de exist?, todos los intervalos se le cuelgan a exist?,
#      incluido el tiempo de Ruby que hay entre ellos.
#
# El sesgo no se quita ajustando la frecuencia: es estructural. Un muestreador
# de Ruby honesto necesitaria despertar en puntos independientes de donde suelta
# el GVL el hilo medido, y desde otro hilo de Ruby eso no se puede.
#
# Lo que si es fiable son los cronometros directos —los embudos de C++, y aqui
# el contador de llamadas al sistema y el de resoluciones de ruta—, porque miden
# lo que envuelven y nada mas. Se quedan; el muestreo se va.
#
# De paso deja de competir por el GVL con el hilo que medimos.

module Graphics
  class << self
    alias_method :nx_update_sin_perfil, :update

    # Hay DOS huecos donde se puede ir el tiempo y no son el mismo sitio:
    #
    #   a) dentro de Graphics.update  -> dibujar, esperar al vsync: C++
    #   b) entre dos Graphics.update  -> el guion del juego: Ruby
    #
    # La primera version solo cronometraba (a) y por eso no vio nada: los
    # fotogramas caros de verdad —el que hace 7691 blt— gastan el tiempo en (b),
    # con update ya devuelto. Ahora se miden los dos y se dice cual fue.
    def update
      ahora = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if @nx_fin && (ahora - @nx_fin) >= NXPerf::UMBRAL
        NXPerf.informe("guion", ahora - @nx_fin, @nx_gc, @nx_cuenta)
      end

      NXPerf.vacia
      NXFS.cobra
      NXRutas.cobra if defined?(NXRutas)
      g0 = NXPerf.gc_ms
      c0 = GC.count

      nx_update_sin_perfil

      fin = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if (fin - ahora) >= NXPerf::UMBRAL
        NXPerf.informe("dibujo", fin - ahora, NXPerf.gc_ms - g0, GC.count - c0)
      end

      NXPerf.vacia
      NXFS.cobra
      NXRutas.cobra if defined?(NXRutas)
      @nx_gc = NXPerf.gc_ms
      @nx_cuenta = GC.count
      @nx_fin = fin
    end
  end
end

NX.log("[perfil] cronometros directos puestos (sin muestreo)")
