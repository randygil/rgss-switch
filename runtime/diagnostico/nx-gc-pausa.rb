# nx-gc-pausa.rb — cuanto para el recolector, medido con el reloj de pared.
#
# GC.total_time y GC.stat(:time) salen a cero en la consola y en Ryujinx: el
# recolector se cronometra con el reloj de CPU del proceso
# (CLOCK_PROCESS_CPUTIME_ID), que Horizon no tiene. Asi que no hay forma de
# preguntarle a Ruby cuanto tarda una pasada, y nx-mapa.rb dice siempre
# "0.0 ms".
#
# Esto lo mide desde fuera: el tiempo de Ruby de cada fotograma (del final de
# un Graphics.update al principio del siguiente), separando los fotogramas en
# los que GC.count cambio de los que no. Lo que una pasada cuesta es la
# diferencia entre los dos. Cada 600 fotogramas, una linea [gcpausa] en
# mkxp-ruby.log (o en gc-pausa.log junto al juego si no hay NX.log).

module NXGCPausa
  CADA = 600
  @fin_prev = nil
  @gc_prev = GC.count
  @normales = []
  @con_gc = []
  @menores = 0
  @mayores = 0

  class << self
    def reloj
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def log(s)
      if defined?(NX) && NX.respond_to?(:log)
        NX.log(s)
      else
        @f ||= File.open(File.join(Dir.pwd, "gc-pausa.log"), "a").tap { |f| f.sync = true }
        @f.puts(s)
      end
    end

    def antes
      t = reloj
      if @fin_prev
        ms = (t - @fin_prev) * 1000.0
        c = GC.count
        if c != @gc_prev
          @con_gc << ms
          @menores += GC.stat(:minor_gc_count) - (@menor_prev || 0) if @menor_prev
          @gc_prev = c
        else
          @normales << ms
        end
      end
      @menor_prev = GC.stat(:minor_gc_count)
      informa if @normales.size + @con_gc.size >= CADA
    end

    def despues
      @fin_prev = reloj
    end

    def mediana(a)
      return 0.0 if a.empty?
      b = a.sort
      b[b.size / 2]
    end

    def informa
      n = mediana(@normales)
      g = @con_gc
      extra = g.empty? ? 0.0 : (g.sum / g.size) - n
      log(format("[gcpausa] %d fotogramas: Ruby %.2f ms/f de mediana sin pasada | %d con pasada (%d menores): media %.2f, peor %.2f ms -> la pasada cuesta ~%.1f ms | %s en vivo, %d casillas",
                 @normales.size + g.size, n, g.size, @menores,
                 g.empty? ? 0.0 : g.sum / g.size, g.max || 0.0, extra,
                 $scene.class, GC.stat(:heap_available_slots)))
      @normales = []
      @con_gc = []
      @menores = 0
    end
  end
end

module Graphics
  class << self
    alias_method :nx_update_sin_gcpausa, :update
    def update(*a)
      NXGCPausa.antes
      r = nx_update_sin_gcpausa(*a)
      NXGCPausa.despues
      r
    end
  end
end
