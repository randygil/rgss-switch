# nx-gc.rb — cuanto del fotograma se lo lleva el recolector de basura.
#
# Con el reloj fijo a 1785 MHz y los alijos de imagen y texto llenos, un
# fotograma de menu se queda asi:
#
#   marco 281 ms | cpu 226 ms | txt 312x 20 ms | sub 13x 35 ms | resto 196 ms
#
# El hilo esta ocupado el 80% del tiempo y 141 de los 196 ms de "resto" son CPU
# como minimo. O sea que ya no queda nada que culpar del lado de C++: es el
# interprete. Esta vez medido, no supuesto — durante dias "resto es Ruby" fue
# una suposicion que sobrevivio a dos experimentos que la contradecian.
#
# La sospecha concreta la da otro numero de la misma linea: "nue 238x". El juego
# construye doscientos treinta y ocho Bitmap por fotograma, y cada uno arrastra
# su objeto de Ruby. Doscientas asignaciones por fotograma a sesenta por segundo
# es presion de asignacion, y la presion de asignacion se paga en pasadas del
# recolector, que se comen el hilo entero mientras corren.
#
# Aqui no hay muestreo. GC.measure_total_time hace que el propio recolector
# lleve la cuenta de sus nanosegundos, y GC.stat da el numero de pasadas y de
# objetos asignados. Restar entre dos fotogramas es contabilidad exacta: es lo
# que le faltaba al muestreador de lib/nx-perfil.rb, que dio dos respuestas
# falsas seguidas —"92% en exist?" y luego "100%, 800 ms en exist?"— y hubo que
# apagar.
#
# Se usa GC.stat(:clave) y no GC.stat: la version sin argumento construye un
# Hash de treinta y tantas entradas en cada llamada, y medir la basura
# generando basura sesenta veces por segundo no es medir.
#
# El umbral y el tope de avisos son los mismos que los de nx/nx_tirones.c, y el
# corte es el mismo (Graphics.update), asi que las lineas [gc] y las [tiron]
# emparejan una a una.

module NXGC
  UMBRAL_SEG = 0.25
  MAX_AVISOS = 60

  @avisos = 0
  @previo = nil
  @gc_previo = 0
  @pasadas_previas = 0
  @objetos_previos = 0
  @pila_previa = nil
  @tramos = [0.0, 0, 0.0, 0]

  GC.measure_total_time = true if GC.respond_to?(:measure_total_time=)

  class << self
    def gc_ns
      GC.respond_to?(:total_time) ? GC.total_time : 0
    end

    # Solo caracteres imprimibles ASCII. Los nombres de script de este juego
    # llevan acentos y vienen de Scripts.rxdata, o sea de una codificacion que
    # no tiene por que ser valida en UTF-8; interpolar una cadena mal formada
    # levanta ArgumentError. Se hace por bytes y sin expresiones regulares para
    # no depender de la codificacion de nada.
    def limpia(x)
      x.to_s.b.each_byte.map { |b| (b >= 32 && b < 127) ? b.chr : "?" }.join
    end

    # De quien es el bucle que esta tardando. Graphics.update se llama desde el
    # bucle de la pantalla que toque, asi que la pila de aqui nombra el fichero
    # y la linea exactos y ahorra leer 770 scripts a ciegas.
    #
    # Solo se escribe cuando CAMBIA respecto a la anterior: en un menu la pila
    # es la misma fotograma tras fotograma y repetirla no anade nada.
    def pila
      marcos = caller_locations(3, 14)
      return if marcos.nil? || marcos.empty?
      texto = marcos.map do |m|
        "#{limpia(m.path)}:#{m.lineno} #{limpia(m.label)}"
      end
      return if texto == @pila_previa
      @pila_previa = texto
      NX.log("[pila] " + texto.join("  <-  "))
    end

    def informa(pared, gc_ms, pasadas, objetos)
      cad_seg, cad_obj, ent_seg, ent_obj = @tramos
      # Un cero de "no instalado" y un cero de "no cuesta nada" se leen igual en
      # el registro, y esta tarde ya me comi uno. Que lo diga.
      unless NXTramos.instalado
        NX.log("[gc] (tramos SIN INSTALAR: los ceros de abajo no son medidas)")
      end
      NX.log("[gc] marco %d ms | gc %d ms en %d pasadas | %d objetos | grafico %dms/%dobj | entrada %dms/%dobj | resto %dms/%dobj%s" % [
        (pared * 1000).round, gc_ms, pasadas, objetos,
        (cad_seg * 1000).round, cad_obj,
        (ent_seg * 1000).round, ent_obj,
        ((pared - cad_seg - ent_seg) * 1000).round, objetos - cad_obj - ent_obj,
        @avisos == MAX_AVISOS ? "  [ultimo aviso]" : ""
      ])
      pila
      # Las filas se cobraron en marca(), al cerrar el fotograma; aqui solo se
      # formatean. Cobrar otra vez devolveria una cuenta vacia.
      if defined?(NXMetodos) && NXMetodos.instalado
        detalle = NXMetodos.informe(@metodos_del_marco)
        NX.log("[metodos] " + detalle) if detalle
      end
    rescue StandardError
      nil   # Un instrumento nunca debe poder tumbar el juego que mide.
    end

    def marca
      ahora = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      gc = gc_ns
      pasadas = GC.stat(:count)
      objetos = GC.stat(:total_allocated_objects)

      @tramos = NXTramos.cobra
      # La cuenta por metodo es del fotograma que acaba de terminar; si este no
      # fue lento se tira, para que la del siguiente lento sea solo suya.
      @metodos_del_marco = (defined?(NXMetodos) && NXMetodos.instalado) ? NXMetodos.cobra : nil
      anterior = @previo
      gc_ant = @gc_previo
      pasadas_ant = @pasadas_previas
      objetos_ant = @objetos_previos

      # La contabilidad se cierra ANTES de informar, y esto es una correccion.
      # La primera version informaba primero, actualizaba despues y llevaba un
      # rescue alrededor de todo. Cuando el volcado de pila lanzo una excepcion
      # —un nombre de script con acentos en una codificacion que no era UTF-8—
      # el rescue se la comio y se llevo por delante la actualizacion. @previo
      # se quedo congelado y a partir de ahi "marco" empezo a crecer solo:
      # 1798, 1866, 1918... 2525 ms, numeros que no eran fotogramas sino la
      # suma de todos los anteriores. Estuve a punto de leerlos como si el juego
      # se estuviera degradando.
      #
      # Medir no puede depender de que informar salga bien. Son dos trabajos y
      # ahora estan en dos metodos, con el rescue solo alrededor del segundo.
      @previo = ahora
      @gc_previo = gc
      @pasadas_previas = pasadas
      @objetos_previos = objetos

      return unless anterior
      pared = ahora - anterior
      return if pared < UMBRAL_SEG || @avisos >= MAX_AVISOS

      @avisos += 1
      informa(pared, ((gc - gc_ant) / 1_000_000.0).round,
              pasadas - pasadas_ant, objetos - objetos_ant)
      # El fotograma que viene se mide sprite a sprite. Se arma aqui y no
      # siempre porque cronometrar doce sprites por separado cuesta, y no se
      # trata de cambiar lo que se esta midiendo.
      NXSprites.arma if objetos - objetos_ant > 20_000
    end
  end
end

# --------------------------------------------------------------------------
# Quien de los sprites se lleva los 84.000 objetos.
#
# El volcado de pila señalo la pantalla: [SV] Summary Screen, pbScene, y el
# bucle de esa pantalla no hace mas que Graphics.update, Input.update y
# pbUpdate. pbUpdate es una linea: pbUpdateSpriteHash(@sprites). O sea que todo
# el gasto esta en el update de alguno de esos sprites, y son una docena.
#
# Una docena de candidatos es poco para leerlos y mucho para adivinar, asi que
# se cronometran uno a uno. La medida es por asignaciones ademas de por tiempo
# porque el sintoma que estamos siguiendo son 84.000 objetos por fotograma, no
# los milisegundos: el objeto que los crea puede no ser el que mas tarda.
#
# Solo se mide cuando el fotograma ANTERIOR fue lento. En marcha normal esto no
# se ejecuta, asi que no cambia lo que mide.
module NXSprites
  MAX_AVISOS = 12

  @instalado = false
  @armado = false
  @avisos = 0

  class << self
    attr_reader :instalado

    def arma
      @armado = true if @avisos < MAX_AVISOS
    end

    def armado?
      @armado
    end

    def mide(windows)
      @armado = false
      reparto = []
      windows&.each do |clave, sprite|
        next unless sprite
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        o0 = GC.stat(:total_allocated_objects)
        nx_pbUpdateSpriteHash_sin_medir({ clave => sprite })
        reparto << [clave,
                    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0,
                    GC.stat(:total_allocated_objects) - o0]
      end

      return if @avisos >= MAX_AVISOS
      @avisos += 1
      caros = reparto.sort_by { |r| -r[2] }.first(6)
      NX.log("[sprites] " + caros.map { |clave, seg, obj|
        "%s %dms/%dobj" % [clave.to_s, (seg * 1000).round, obj]
      }.join("  "))
    rescue StandardError
      nil
    end

    def instala
      return true if @instalado
      return false unless Object.method_defined?(:pbUpdateSpriteHash) ||
                          Object.private_method_defined?(:pbUpdateSpriteHash)
      @instalado = true
      Object.class_eval do
        alias_method :nx_pbUpdateSpriteHash_sin_medir, :pbUpdateSpriteHash
        def pbUpdateSpriteHash(windows)
          return NXSprites.mide(windows) if NXSprites.armado?
          nx_pbUpdateSpriteHash_sin_medir(windows)
        end
      end
      # No hace falta nada mas para poder llamarlo desde mide(): el alias vive
      # en Object como metodo privado, NXSprites es un Object, y una llamada
      # con receptor implicito a un metodo privado es legal.
      NX.log("[sprites] cronometro por sprite puesto")
      true
    end
  end
end

# --------------------------------------------------------------------------
# En que tramo del fotograma se van los 84.000 objetos.
#
# Los sprites quedaron descartados: cronometrados uno a uno dan 6 objetos y
# 0 ms cada uno, treinta entre todos. Y el bucle de la pantalla de datos solo
# hace tres cosas: Graphics.update, Input.update y pbUpdate (que es el
# pbUpdateSpriteHash ya medido). Asi que o es la cadena de plugins colgada de
# Graphics.update, o es Input, o es el propio cuerpo del bucle.
#
# Aqui hay un detalle que importa para leer bien el resultado. Mi sonda es la
# mas INTERIOR de la cadena: el volcado de pila dice
#
#   nx-gc.rb update  <-  [Intro Versus] update  <-  [Lens of truth] update
#                     <-  [Discord] update  <-  el bucle de la pantalla
#
# o sea que los tres plugins envuelven a la mia y desde dentro no puedo verlos.
# Por eso se instala una segunda envoltura por FUERA, ya con el juego cargado.
# Restando las dos, lo que gastan los plugins queda aislado.
module NXTramos
  @instalado = false
  @cadena_seg = 0.0
  @cadena_obj = 0
  @entrada_seg = 0.0
  @entrada_obj = 0

  class << self
    attr_reader :instalado

    def suma_cadena(seg, obj)
      @cadena_seg += seg
      @cadena_obj += obj
    end

    def suma_entrada(seg, obj)
      @entrada_seg += seg
      @entrada_obj += obj
    end

    # Se lee y se pone a cero de una vez, en el mismo sitio donde se cierra el
    # resto de la contabilidad.
    def cobra
      r = [@cadena_seg, @cadena_obj, @entrada_seg, @entrada_obj]
      @cadena_seg = 0.0
      @cadena_obj = 0
      @entrada_seg = 0.0
      @entrada_obj = 0
      r
    end

    def instala
      return true if @instalado
      # Las dos preguntas, no solo la de privado. NXSprites se instala antes y
      # redefine pbUpdateSpriteHash con un def dentro de class_eval, que lo
      # deja PUBLICO. Con la guarda de solo-privado, esta de aqui no se
      # instalaba nunca y sus contadores se quedaban a cero — indistinguible de
      # haber medido cero.
      return false unless Object.method_defined?(:pbUpdateSpriteHash) ||
                          Object.private_method_defined?(:pbUpdateSpriteHash)
      @instalado = true

      module_eval_graphics
      module_eval_input
      NX.log("[tramos] envoltura exterior puesta")
      true
    end

    def module_eval_graphics
      Graphics.singleton_class.class_eval do
        alias_method :nx_update_cadena, :update
        def update
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          o0 = GC.stat(:total_allocated_objects)
          nx_update_cadena
          NXTramos.suma_cadena(
            Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0,
            GC.stat(:total_allocated_objects) - o0)
        end
      end
    end

    def module_eval_input
      Input.singleton_class.class_eval do
        alias_method :nx_input_sin_medir, :update
        def update
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          o0 = GC.stat(:total_allocated_objects)
          nx_input_sin_medir
          NXTramos.suma_entrada(
            Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0,
            GC.stat(:total_allocated_objects) - o0)
        end
      end
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_gc, :update

    def update
      NXGC.marca
      NXSprites.instala unless NXSprites.instalado
      NXTramos.instala unless NXTramos.instalado
      NXMetodos.instala if defined?(NXMetodos) && !NXMetodos.instalado
      nx_update_sin_gc
    end
  end
end

NX.log("[gc] contador de recolector puesto (medicion: #{GC.respond_to?(:total_time)})")
