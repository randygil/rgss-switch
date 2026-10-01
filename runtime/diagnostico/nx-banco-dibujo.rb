# nx-banco-dibujo.rb — banco del dibujo en Bitmap: texto, set_pixel y recolector.
#
# Mide y comprueba, sin mando y en un solo arranque, los tres caminos del
# motor que toca la bitacora §5.75:
#
#   texto     draw_text por el atlas de cadenas y por el alijo de cajas de
#             antes, con fallo de alijo (cadenas que nunca se habian visto) y
#             con acierto; y que los dos caminos dejan los MISMOS bytes, con
#             tamanos, colores, alineaciones, cadenas estrujadas, texto
#             semitransparente y destino con contenido (el camino del
#             sombreador) o sin el (el pegado directo).
#   pixeles   set_pixel en rafaga justo despues de clear, con la copia en RAM
#             hecha a ceros y leyendola de la GPU como antes; el hexagono de
#             estadisticas del resumen (Marin Better Bitmaps) si el juego lo
#             trae; y otra vez, que los bytes son los mismos.
#   gc        GC.stat en el momento de medir: pasadas, menores, mayores,
#             casillas y tiempo del recolector desde el arranque.
#
# El antes y el despues salen del MISMO binario: en modo diagnostico
# (diagnostico.txt en la carpeta del juego) el motor mira las variables
# RGSS_SIN_ATLAS y RGSS_SIN_CEROS, y este banco las pone y las quita. Sin modo
# diagnostico las variables no hacen nada y el banco lo dice (las comparaciones
# saldrian iguales por no comparar nada).
#
# Se pone en preloadScript (en la consola, en lib/) y espera a que el juego
# llegue a la pantalla de titulo. Escribe banco-dibujo.log junto al juego y
# SALE al terminar, sin guardar nada. Con banco-dibujo.casos junto al juego,
# ademas, caso a caso (lento: dos lecturas de la GPU por caso, tres minutos en
# Ryujinx); con banco-dibujo.fotos, PNG de los casos que salgan distintos.
#
# Cuidado al leer las comparaciones en Ryujinx: alli, de vez en cuando, una
# caja de texto recien creada por el fondo de texturas sale vacia aunque se
# acabe de subir (la misma cadena, en otra partida, sale bien). Es el camino
# de antes, el de las cajas, y es del emulador: se reconoce porque la caja
# sale vacia y el atlas no, y porque no se repite de una partida a otra
# (bitacora §5.75).

module NXBD
  RAIZ = Dir.pwd
  @f = File.open(File.join(RAIZ, "banco-dibujo.log"), "w")
  @f.sync = true
  @marcos = 0
  @hecho = false

  class << self
    def log(s)
      @f.puts(s)
    end

    def ahora
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def ms(t0)
      (ahora - t0) * 1000.0
    end

    def gc_linea(etq)
      t = GC.stat(:time).to_f
      log(format("[gc] %s: %d pasadas (%d menores, %d mayores) | %d casillas vivas de %d | %.1f ms de recolector en total",
                 etq, GC.stat(:count), GC.stat(:minor_gc_count), GC.stat(:major_gc_count),
                 GC.stat(:heap_live_slots), GC.stat(:heap_available_slots), t))
    end

    def con_entorno(var, valor)
      antes = ENV[var]
      valor ? ENV[var] = "1" : ENV.delete(var)
      yield
    ensure
      antes ? ENV[var] = antes : ENV.delete(var)
    end

    def fuente(b, tam, negrita)
      if defined?(pbSetSystemFont)
        pbSetSystemFont(b)
      end
      b.font.size = tam
      b.font.bold = negrita
    end

    #--- texto ---------------------------------------------------------------
    CADENAS = ["POCION", "Superpocion", "Pokeball", "Ataque", "Defensa",
               "At. Esp.", "Def. Esp.", "Velocidad", "PS", "Nv. 34",
               "Bulbasaur", "Ivysaur", "Venusaur", "Charmander", "Pidgey",
               "¿Quieres guardar la partida?", "Sí", "No", "Añil", "Pokédex",
               "MOCHILA", "Equipo", "Opciones", "Salir", "1/151",
               "Una cadena bastante larga que no cabe en la caja estrecha",
               "x", "W", "i", "  dos  espacios  ", "12345678901234567890"]

    # Pinta una rejilla de casos en b. Devuelve cuantas llamadas hizo.
    def rejilla(b, fondo)
      b.clear
      if fondo
        b.fill_rect(0, 0, b.width, b.height / 2, Color.new(40, 80, 120, 255))
        b.gradient_fill_rect(0, b.height / 2, b.width, b.height / 2,
                             Color.new(200, 30, 30, 128), Color.new(30, 200, 30, 255))
      end
      n = 0
      y = 0
      [[20, false], [26, true], [32, false]].each do |tam, neg|
        fuente(b, tam, neg)
        [Color.new(248, 248, 248), Color.new(72, 72, 72), Color.new(255, 0, 0, 128),
         Color.new(0, 112, 248, 255)].each_with_index do |col, ci|
          b.font.color = col
          CADENAS.each_with_index do |s, i|
            x = (i % 4) * 128
            yy = (y + (i / 4) * 6 + ci * 2) % (b.height - 32)
            ancho = (i % 3 == 0) ? 40 : 128     # estrecha: estruja las largas
            b.draw_text(x, yy, ancho, 32, s, i % 3)
            n += 1
          end
        end
        y += 90
      end
      n
    end

    def compara_texto
      log("[texto] diagnostico: #{File.exist?(File.join(RAIZ, 'diagnostico.txt')) ? 'si' : 'NO (las variables no hacen nada)'}")
      b = Bitmap.new(512, 384)
      [false, true].each do |fondo|
        ref = nil
        [[true, "cajas"], [false, "atlas"], [false, "atlas (acierto)"], [true, "cajas (acierto)"]].each do |sin, etq|
          datos = nil
          con_entorno("RGSS_SIN_ATLAS", sin) do
            rejilla(b, fondo)
            Graphics.nxbd_update
            rejilla(b, fondo)
            datos = b.raw_data
          end
          if ref.nil?
            ref = datos
            log("[texto] #{fondo ? 'con fondo' : 'sin fondo'}: referencia = #{etq}")
          else
            dif = 0
            if datos != ref
              a = ref.unpack("N*"); c = datos.unpack("N*")
              a.each_index { |k| dif += 1 if a[k] != c[k] }
            end
            log("[texto] #{fondo ? 'con fondo' : 'sin fondo'}: #{etq} -> #{dif} pixeles distintos de #{ref.bytesize / 4}")
          end
        end
      end
      b.dispose
    end

    # Caso a caso, en un Bitmap pequeno: cual de los casos de la rejilla sale
    # distinto entre los dos caminos, y donde.
    def casos_texto
      b = Bitmap.new(160, 48)
      malos = 0
      resueltos = 0
      total = 0
      [false, true].each do |fondo|
        [[20, false], [32, false]].each do |tam, neg|
          [Color.new(248, 248, 248), Color.new(255, 0, 0, 128)].each do |col|
            CADENAS.each_with_index do |s, i|
              [40, 128].each do |ancho|
                [0, 2].each do |al|
                  datos = [true, false].map do |sin|
                    con_entorno("RGSS_SIN_ATLAS", sin) do
                      b.clear
                      b.fill_rect(0, 0, 160, 48, Color.new(40, 80, 120, 255)) if fondo
                      fuente(b, tam, neg)
                      b.font.color = col
                      b.draw_text(8, 8, ancho, 32, s, al)
                    end
                    b.raw_data
                  end
                  total += 1
                  next if datos[0] == datos[1]
                  # Otra vez despues de un Graphics.update: en Ryujinx una
                  # textura recien subida no siempre se ve en el primer
                  # dibujo (ver bitacora §5.75). Si tras el fotograma sale
                  # igual, la diferencia era del emulador y no del camino.
                  Graphics.nxbd_update
                  datos2 = [true, false].map do |sin|
                    con_entorno("RGSS_SIN_ATLAS", sin) do
                      b.clear
                      b.fill_rect(0, 0, 160, 48, Color.new(40, 80, 120, 255)) if fondo
                      fuente(b, tam, neg)
                      b.font.color = col
                      b.draw_text(8, 8, ancho, 32, s, al)
                    end
                    b.raw_data
                  end
                  log(format("[caso]   tras un fotograma: cajas %s, atlas %s, %s",
                             datos2[0] == datos[0] ? "igual que antes" : "CAMBIA",
                             datos2[1] == datos[1] ? "igual que antes" : "CAMBIA",
                             datos2[0] == datos2[1] ? "y ahora los dos coinciden" : "y siguen distintos"))
                  if datos2[0] == datos2[1]
                    resueltos += 1
                    next
                  end
                  malos += 1
                  if malos == 1 && File.exist?(File.join(RAIZ, "banco-dibujo.fotos"))
                    # El primer caso distinto, en PNG por los dos caminos, y
                    # repetido: si al repetirlo sale igual, es cosa del momento
                    # (el emulador), no del camino.
                    3.times do |rep|
                      [true, false].each do |sin|
                        con_entorno("RGSS_SIN_ATLAS", sin) do
                          b.clear
                          b.fill_rect(0, 0, 160, 48, Color.new(40, 80, 120, 255)) if fondo
                          fuente(b, tam, neg)
                          b.font.color = col
                          b.draw_text(8, 8, ancho, 32, s, al)
                        end
                        b.to_file(File.join(RAIZ, "caso-#{rep}-#{sin ? 'cajas' : 'atlas'}.png"))
                      end
                    end
                  end
                  next if malos > 40
                  a = datos[0].unpack("L*"); c = datos[1].unpack("L*")
                  xs = []; ys = []; ej = nil
                  a.each_index do |k|
                    next if a[k] == c[k]
                    xs << k % 160; ys << k / 160
                    ej ||= format("(%d,%d) cajas %08x atlas %08x", k % 160, k / 160, a[k], c[k])
                  end
                  tw = b.text_size(s).width
                  log(format("[caso] fondo=%s tam=%d neg=%s alfa=%d ancho=%d al=%d ancho_txt=%d %-12s -> %d px en x %d..%d y %d..%d; %s",
                             fondo, tam, neg, col.alpha, ancho, al, tw, s[0, 12].inspect, xs.size, xs.min, xs.max, ys.min, ys.max, ej))
                end
              end
            end
          end
        end
      end
      log("[caso] #{total} casos: #{malos} distintos, #{resueltos} que solo diferian en el primer dibujo")
      b.dispose
    end

    def tiempos_texto
      b = Bitmap.new(512, 384)
      fuente(b, 26, false)
      b.font.color = Color.new(248, 248, 248)
      [[true, "cajas"], [false, "atlas"]].each do |sin, etq|
        con_entorno("RGSS_SIN_ATLAS", sin) do
          base = "#{etq}-#{rand(1_000_000)}"
          n = 300
          b.clear
          t0 = ahora
          n.times { |i| b.draw_text((i % 4) * 128, (i * 7) % 352, 128, 32, "#{base} objeto #{i}") }
          fallo = ms(t0) / n
          t0 = ahora
          n.times { |i| b.draw_text((i % 4) * 128, (i * 7) % 352, 128, 32, "#{base} objeto #{i}") }
          acierto = ms(t0) / n
          Graphics.nxbd_update
          t0 = ahora
          n.times { |i| b.draw_text((i % 4) * 128, (i * 7) % 352, 128, 32, "#{base} objeto #{i}") }
          acierto2 = ms(t0) / n
          log(format("[texto] %-6s fallo de alijo %.3f ms/llamada | acierto %.3f | acierto tras un fotograma %.3f ms/llamada (%d cadenas)", etq, fallo, acierto, acierto2, n))
        end
      end
      b.dispose
    end

    # Mas cadenas de las que caben en las ocho hojas: el atlas tiene que
    # vaciar hojas, y lo que se dibuja despues sigue saliendo igual.
    def desborde_texto
      b = Bitmap.new(512, 384)
      fuente(b, 26, false)
      b.font.color = Color.new(248, 248, 248)
      t0 = ahora
      n = 6000
      con_entorno("RGSS_SIN_ATLAS", false) do
        n.times { |i| b.draw_text(0, 0, 512, 32, "desborde #{i} #{'x' * (i % 40)}") }
      end
      log(format("[texto] desborde: %d cadenas nuevas por el atlas, %.3f ms/llamada", n, ms(t0) / n))
      ref = nil
      [true, false].each do |sin|
        con_entorno("RGSS_SIN_ATLAS", sin) do
          rejilla(b, true)
          Graphics.nxbd_update
          rejilla(b, true)
          if ref.nil? then ref = b.raw_data
          else log("[texto] desborde: rejilla despues de vaciar hojas -> #{b.raw_data == ref ? 'igual' : 'DISTINTA'}")
          end
        end
      end
      b.dispose
    end

    #--- set_pixel -----------------------------------------------------------
    def rafaga(b, semilla)
      r = Random.new(semilla)
      2000.times do
        b.set_pixel(r.rand(b.width), r.rand(b.height),
                    Color.new(r.rand(256), r.rand(256), r.rand(256), r.rand(256)))
      end
    end

    def pixeles
      b = Bitmap.new(512, 384)
      ref = nil
      [[true, "leyendo la GPU"], [false, "a ceros"]].each do |sin, etq|
        con_entorno("RGSS_SIN_CEROS", sin) do
          # Calentar: la primera vez cuesta crear la copia en RAM.
          b.clear; rafaga(b, 1); b.fill_rect(0, 0, 1, 1, Color.new(0, 0, 0, 0))
          vueltas = 10
          t0 = ahora
          vueltas.times do |v|
            b.clear
            rafaga(b, v)
            b.fill_rect(0, 0, 2, 2, Color.new(9, 9, 9, 255))   # obliga a subir
          end
          t = ms(t0) / vueltas
          datos = b.raw_data
          px = b.get_pixel(5, 5)
          log(format("[pixeles] clear + 2000 set_pixel + fill_rect, %-15s %.2f ms por vuelta", etq, t))
          if ref.nil? then ref = [datos, px.red, px.green, px.blue, px.alpha]
          else
            log("[pixeles] mismos bytes que leyendo la GPU: #{datos == ref[0] ? 'si' : 'NO'}; get_pixel(5,5) igual: #{[px.red, px.green, px.blue, px.alpha] == ref[1..4] ? 'si' : 'NO'}")
          end
        end
      end
      # get_pixel justo despues de clear: cero, sin leer nada.
      b.clear
      c = b.get_pixel(100, 100)
      log("[pixeles] get_pixel tras clear: #{[c.red, c.green, c.blue, c.alpha].inspect}")
      b.dispose

      return unless Bitmap.method_defined?(:draw_hexagon_with_values)
      stats = [120, 80, 95, 60, 110, 150]
      ref = nil
      [[true, "leyendo la GPU"], [false, "a ceros"]].each do |sin, etq|
        con_entorno("RGSS_SIN_CEROS", sin) do
          h = Bitmap.new(512, 384)
          h.clear
          h.draw_hexagon_with_values(181, 77, 42, 48, Color.new(72, 204, 240, 191), 300, stats.dup, 12, true, false)
          vueltas = 5
          t0 = ahora
          vueltas.times do
            h.clear
            h.draw_hexagon_with_values(181, 77, 42, 48, Color.new(72, 204, 240, 191), 300, stats.dup, 12, true, false)
            h.fill_rect(0, 0, 1, 1, Color.new(0, 0, 0, 0))   # lo que haga el siguiente dibujo: sube lo pendiente
          end
          log(format("[pixeles] hexagono del resumen, %-15s %.2f ms por dibujo", etq, ms(t0) / vueltas))
          d = h.raw_data
          if ref.nil? then ref = d
          else log("[pixeles] hexagono: mismos bytes: #{d == ref ? 'si' : 'NO'}")
          end
          h.dispose
        end
      end
    end

    # Lo que la pantalla de carga de Anil hace antes de pintar el menu
    # (PokeUpdater, ver juegos/pokemon-anil/lib/nx-actualiza.rb).
    def actualiza
      return unless defined?(PokeUpdater) && PokeUpdater.respond_to?(:check_for_updates)
      t0 = ahora
      PokeUpdater.check_for_updates
      log(format("[actualiza] PokeUpdater.check_for_updates: %.0f ms%s", ms(t0),
                 defined?(NXActualiza) ? " (con nx-actualiza)" : ""))
    rescue StandardError => e
      log("[actualiza] #{e.class}: #{e.message}")
    end

    # Una cadena concreta por los dos caminos, en PNG (banco-dibujo.fotos).
    def foto_cadena(etq, s, tam, col)
      return unless File.exist?(File.join(RAIZ, "banco-dibujo.fotos"))
      b = Bitmap.new(160, 48)
      [true, false].each do |sin|
        con_entorno("RGSS_SIN_ATLAS", sin) do
          b.clear
          fuente(b, tam, false)
          b.font.color = col
          b.draw_text(8, 8, 128, 32, s, 0)
        end
        b.to_file(File.join(RAIZ, "caso-#{etq}-#{sin ? 'cajas' : 'atlas'}.png"))
      end
      log("[foto] #{etq}: #{s.inspect} tam #{tam} text_size #{b.text_size(s).width}x#{b.text_size(s).height}")
      b.dispose
    end

    def corre
      @hecho = true
      foto_cadena("a0", "Defensa", 20, Color.new(248, 248, 248))
      foto_cadena("a1", "Ataque", 20, Color.new(248, 248, 248))
      gc_linea("al empezar (titulo)")
      actualiza
      t0 = ahora
      begin
        compara_texto
        foto_cadena("b0", "Defensa", 20, Color.new(248, 248, 248))
        foto_cadena("b1", "Defensa", 20, Color.new(248, 248, 247))
        tiempos_texto
        tiempos_texto
        tiempos_texto
        pixeles
        desborde_texto
        casos_texto if File.exist?(File.join(RAIZ, "banco-dibujo.casos"))
      rescue Exception => e
        log("[error] #{e.class}: #{e.message}")
        (e.backtrace || [])[0, 8].each { |l| log("    #{l}") }
      end
      log(format("[fin] %.0f ms", ms(t0)))
      gc_linea("al terminar")
      @f.close
      Kernel.exit!(0)
    end

    def marco
      @marcos += 1
      return if @hecho
      return if @marcos < 120
      return unless defined?(pbSetSystemFont)
      corre
    end
  end
end

GC.measure_total_time = true if GC.respond_to?(:measure_total_time=)

module Graphics
  class << self
    alias_method :nxbd_update, :update
    def update(*a)
      r = nxbd_update(*a)
      NXBD.marco
      r
    end
  end
end
