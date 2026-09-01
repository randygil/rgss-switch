# nx-metodos.rb — cuanto cuesta cada metodo de la pantalla que tarda.
#
# A estas alturas el reparto ya esta cerrado por fuera: en la vista de datos un
# cambio de pestana son 400-900 ms y 84.000 objetos, y todo eso cae en UNA
# llamada, drawPage(@page). Ni Graphics.update (7 ms, 1 objeto, plugins
# incluidos), ni Input.update (0), ni los sprites (30 objetos entre los doce).
#
# drawPage llama a una veintena de metodos conocidos. Veinte es demasiado para
# adivinar —hoy llevo cuatro adivinanzas falladas y una que hubo que rectificar
# al reves— y poco para cronometrar. Asi que se envuelven todos los metodos
# propios de las clases de esas pantallas y se anota, por metodo, cuantas veces
# se llamo, cuanto tardo y cuantos objetos creo. El reparto es INCLUSIVO, como
# el del lado C++: drawPage sumara lo de todos sus hijos. Eso no molesta para
# ordenar y si sirve para ver el arbol.
#
# La cuenta se pone a cero en cada Graphics.update y se imprime con la linea
# [gc] del fotograma lento, asi que lo que sale es exactamente un drawPage.
#
# Se envuelven tambien los metodos de dibujo de Marin Better Bitmaps y el
# set_pixel de Bitmap, porque leer el codigo dice que cada set_pixel es una
# subida de 1x1 a la GPU, y hay que saber cuantos son. Leerlo no es medirlo.

module NXMetodos
  CUENTA = Hash.new { |h, k| h[k] = [0, 0.0, 0] }   # llamadas, segundos, objetos

  @instalado = false
  @pendientes = nil

  class << self
    attr_reader :instalado

    def envuelve(klass, nombres, etiqueta)
      nombres.each do |m|
        next if m.to_s.start_with?("nx_")
        begin
          orig = klass.instance_method(m)
        rescue NameError
          next
        end
        clave = "#{etiqueta}##{m}"
        klass.send(:define_method, m) do |*args, **kw, &blk|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          o0 = GC.stat(:total_allocated_objects)
          begin
            orig.bind_call(self, *args, **kw, &blk)
          ensure
            c = NXMetodos::CUENTA[clave]
            c[0] += 1
            c[1] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
            c[2] += GC.stat(:total_allocated_objects) - o0
          end
        end
      end
    end

    def envuelve_clase(nombre, etiqueta = nombre)
      return false unless Object.const_defined?(nombre)
      klass = Object.const_get(nombre)
      envuelve(klass, klass.instance_methods(false) + klass.private_instance_methods(false), etiqueta)
      true
    end

    def instala
      return true if @instalado
      # Todas a la vez o ninguna: el summary se define en el nucleo, pero las
      # reaperturas de los plugins llegan despues y son las que importan.
      # Publico O privado: NXSprites redefine pbUpdateSpriteHash y lo deja
      # publico, y con la pregunta de solo-privado esto no se instalaba nunca.
      # Es la segunda vez que me pasa hoy con la misma linea.
      return false unless Object.const_defined?(:PokemonSummary_Scene) &&
                          Object.const_defined?(:PokemonBag_Scene) &&
                          (Object.method_defined?(:pbUpdateSpriteHash) ||
                           Object.private_method_defined?(:pbUpdateSpriteHash))
      @instalado = true

      envuelve_clase(:PokemonSummary_Scene, "Sum")
      envuelve_clase(:PokemonBag_Scene, "Bag")
      envuelve_clase(:Window_PokemonBag, "WBag")
      envuelve_clase(:Window_DrawableCommand, "WCmd")
      envuelve_clase(:PokemonPartyPanel, "Panel") if Object.const_defined?(:PokemonPartyPanel)

      envuelve(Object, [:pbDrawTextPositions, :pbDrawImagePositions, :pbDrawShadowText,
                        :pbDrawOutlineText, :pbDrawPlainText, :pbSetSystemFont,
                        :pbSetSmallFont, :pbSetNarrowFont,
                        # La descripcion del objeto en la mochila va por aqui:
                        # getFormattedText trocea la cadena caracter a caracter
                        # y drawFormattedChars hace un draw_text por caracter.
                        :drawTextEx, :drawTextExMultiline, :getFormattedText,
                        :drawFormattedChars, :getLineBrokenText, :pbDoEnsureBitmap,
                        :getFormattedTextFast, :getFormattedTextForDims,
                        # drawTextEx, que es lo que usa la descripcion de la
                        # mochila, no pasa por getFormattedText sino por estos:
                        :getLineBrokenChunks, :renderLineBrokenChunksWithShadow], "fn")

      envuelve(Bitmap, [:set_pixel, :get_pixel, :draw_line, :draw_shape,
                        :draw_shape_with_values, :draw_hexagon, :draw_hexagon_with_values,
                        :draw_circle, :fill_rect, :blt, :draw_text], "Bmp")

      if Object.const_defined?(:UIHandlers)
        envuelve(UIHandlers.singleton_class, [:call, :get_info], "UIH")
      end

      # Combate. Las clases van anidadas (Battle::Scene), asi que se resuelven
      # por nombre completo y se salta la que no exista en esta version.
      %w[Battle::Scene Battle::Scene::Animation Battle::Scene::Menu
         Battle::Scene::Animation::Intro PokemonBattlerSprite BattlerShadowSprite
         PokemonDataBox Battle::Scene::Animation::BattlerAppear].each do |nombre|
        begin
          klass = Object.const_get(nombre)
        rescue NameError
          next
        end
        etiqueta = nombre.split("::").last
        envuelve(klass, klass.instance_methods(false) + klass.private_instance_methods(false), etiqueta)
      end

      # Efectos por pixel de otros plugins: findTop (Deluxe Battle Rules) y los
      # de Sprite (outline, colorize...). Si aparecen aqui con miles de objetos,
      # van al mismo saco que findCenter.
      envuelve(Object, [:findTop], "fn")
      envuelve(Sprite, [:outline, :colorize, :avg_color, :glow, :blur_sprite, :mask,
                        :swap_colors, :blur], "Spr")

      # Quien pega. Hubo fotogramas con 7.764 blt en la lista y ningun metodo
      # envuelto al lado, o sea que el que los hace no es de las clases de
      # arriba. Se apunta el llamador de uno de cada 200 blt: barato, y con
      # 7.000 blt por fotograma da 35 muestras, de sobra para senalar.
      Bitmap.class_eval do
        alias_method :nx_blt_sin_apuntar, :blt
        def blt(*args)
          NXMetodos.apunta_blt
          nx_blt_sin_apuntar(*args)
        end
        alias_method :nx_stretch_blt_sin_apuntar, :stretch_blt
        def stretch_blt(*args)
          NXMetodos.apunta_blt
          nx_stretch_blt_sin_apuntar(*args)
        end
      end

      NX.log("[metodos] envueltos %d metodos" % CUENTA.size.clamp(0, 10**9)) rescue nil
      true
    end

    DESDE = Hash.new(0)
    @blt_n = 0

    def apunta_blt
      @blt_n += 1
      return unless (@blt_n % 200) == 1
      m = caller_locations(2, 1)&.first
      return unless m
      ruta = m.path.to_s
      ruta = ruta[(ruta.rindex("/") || -1) + 1, 40]
      DESDE["#{ruta}:#{m.lineno} #{m.label}"] += 1
    rescue StandardError
      nil
    end

    def cobra_desde
      return nil if DESDE.empty?
      filas = DESDE.sort_by { |_, n| -n }.first(5)
      DESDE.clear
      filas.map { |k, n| "#{k} x#{n * 200}" }.join("  ")
    end

    def cobra
      desde = cobra_desde
      return nil if CUENTA.empty? && desde.nil?
      filas = CUENTA.map { |k, (n, seg, obj)| [k, n, seg, obj] }
      CUENTA.clear
      filas << ["blt-desde", 0, 0.0, 0, desde] if desde
      filas
    end

    # Los doce que mas objetos crearon, mas cualquier cosa que haya tardado mas
    # de 20 ms aunque cree poco: lo caro en tiempo y lo caro en objetos no
    # tienen por que ser lo mismo.
    def informe(filas)
      return nil if filas.nil? || filas.empty?
      desde = filas.find { |f| f[0] == "blt-desde" }
      filas = filas.reject { |f| f[0] == "blt-desde" }
      caros = filas.sort_by { |f| -f[3] }.first(12)
      lentos = filas.select { |f| f[2] > 0.020 }.sort_by { |f| -f[2] }.first(6)
      texto = (caros + lentos).uniq.map { |k, n, seg, obj|
        "%s %dx/%dms/%dobj" % [k, n, (seg * 1000).round, obj]
      }.join("  ")
      texto += "  | blt desde: " + desde[4] if desde
      texto
    end
  end
end

NX.log("[metodos] a la espera de las clases de las pantallas")
