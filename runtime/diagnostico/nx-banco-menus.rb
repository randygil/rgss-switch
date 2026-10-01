# nx-banco-menus.rb — banco de pruebas de los menus de un Essentials v21, sin mando.
#
# Carga una partida, abre las pantallas con las mismas llamadas que el menu de
# pausa y las conduce con una entrada de mentira: Input.trigger?, repeat?,
# press? y dir4 devuelven lo que diga el guion, y el raton no existe. No hace
# falta foco de teclado ni nadie delante. Por cada fotograma mide el tiempo de
# Ruby entre dos Graphics.update; si pasa de UMBRAL apunta el paso del guion y
# los metodos envueltos que mas tardaron en ese fotograma, y al final de cada
# flujo, el total y el peor fotograma de cada paso.
#
# Nacio para el lag de los menus de Anil (bitacora §5.72) y conoce sus
# pantallas: dex (lista, entrada, pagina Datos con su menu y su lista de
# especies, buscador), equipo, datos (el resumen) y mochila. Funciona en el PC
# sobre una copia del juego (tmp/pc-anil/, con este fichero en preloadScript)
# y en la consola igual, en lib/ y en preloadScript detras de los shims.
#
# Se gobierna con ficheros junto al juego (en la consola, en su carpeta):
#   banco-menus.flujo     flujos, separados por espacios (dex equipo datos mochila)
#   banco-menus.partida   nombre de la partida, sin .rxdata (Partida 1)
#   banco-menus.shims     rutas de .rb que cargar despues de este (solo PC)
#   banco-menus.sincache  existe = vacia la cache de PokeAPI, para medir la red
#   banco-menus.equipo6   existe = rellena el equipo hasta seis, solo en memoria
# Escribe banco-menus.log y SALE DEL JUEGO al terminar, sin guardar.

module NX
  def self.log(s)
    NXP.escribe("[nx] #{s}")
  end
end unless defined?(NX)

module NXP
  RAIZ = Dir.pwd
  LOG = File.join(RAIZ, "banco-menus.log")
  UMBRAL = 0.030
  CUENTA = Hash.new { |h, k| h[k] = [0, 0.0, 0] }
  PASOS = {}
  @f = File.open(LOG, "w")
  @f.sync = true
  @hecho = false
  @corriendo = false
  @cola = []
  @tecla = nil
  @espera = 0
  @etiqueta = "(arranque)"
  @fin_marco = nil
  @marcos = 0
  @escenas = {}

  class << self
    attr_accessor :escenas, :etiqueta

    def ahora
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def escribe(s)
      @f.puts(s)
    end

    #--- envoltura de metodos ---------------------------------------------
    def envuelve(klass, nombres, etiqueta)
      nombres.each do |m|
        next if m.to_s.start_with?("nx_")
        begin
          orig = klass.instance_method(m)
        rescue NameError
          next
        end
        next if orig.owner != klass && !klass.singleton_class?
        clave = "#{etiqueta}##{m}"
        klass.send(:define_method, m) do |*args, &blk|
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          o0 = GC.stat(:total_allocated_objects)
          begin
            orig.bind_call(self, *args, &blk)
          ensure
            c = NXP::CUENTA[clave]
            c[0] += 1
            c[1] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
            c[2] += GC.stat(:total_allocated_objects) - o0
          end
        end
        klass.send(:ruby2_keywords, m) rescue nil
      end
    end

    def clase(nombre)
      nombre.split("::").inject(Object) { |o, n| o.const_get(n) }
    rescue NameError
      nil
    end

    def envuelve_clase(nombre, etiqueta = nil)
      k = clase(nombre)
      return unless k
      envuelve(k, k.instance_methods(false) + k.private_instance_methods(false),
               etiqueta || nombre.split("::").last)
    end

    def instala_perfil
      %w[PokemonPokedex_Scene PokemonPokedexInfo_Scene Window_Pokedex PokemonDataPageSprite
         PokemonPokedexMenu_Scene PokedexSearcher
         PokemonParty_Scene PokemonPartyScreen PokemonPartyPanel PokemonPartyBlankPanel
         PokemonPartyCancelSprite PokemonPartyConfirmSprite
         PokemonSummary_Scene PokemonBag_Scene Window_PokemonBag
         PokemonSpeciesIconSprite PokemonIconSprite PokemonSprite DeluxeBitmapWrapper
         AnimatedBitmap ChangelingSprite Player::Pokedex IconSprite
         Window_CommandPokemon Window_DrawableCommand SpriteWindow_Selectable].each do |n|
        envuelve_clase(n)
      end
      if (sp = clase("GameData::Species"))
        envuelve(sp, [:display_species?, :get_family_species, :get_evolutions,
                      :get_previous_species, :get_baby_species, :is_regional_form?,
                      :base_pokedex_form, :get_tutor_moves, :get_egg_moves], "Sp")
        envuelve(sp.singleton_class, [:get_species_form, :each, :each_species, :sprite_filename,
                                      :front_sprite_filename, :icon_filename,
                                      :icon_filename_from_pokemon, :sprite_bitmap_from_pokemon,
                                      :front_sprite_bitmap, :icon_bitmap], "Sp.")
      end
      envuelve(Object, [:pbDrawTextPositions, :pbDrawImagePositions, :pbDrawShadowText,
                        :pbResolveBitmap, :network_available?, :pbDownloadToString,
                        :pbDownloadData, :pbFadeOutAndHide, :pbFadeInAndShow,
                        :pbGetDexList, :pbAllRegionalSpecies, :drawTextEx, :getFormattedText,
                        :drawFormattedChars, :findCenter, :findTop, :pbSetSystemFont,
                        :pbSetSmallFont, :pbBitmap, :pbMessage], "fn")
      envuelve(PokeAPI.singleton_class, PokeAPI.singleton_methods(false), "API") if defined?(PokeAPI)
      envuelve(HTTPLite.singleton_class, [:get, :post, :post_body], "HTTP") if defined?(HTTPLite)
      envuelve(RPG::Cache.singleton_class, [:load_bitmap, :retrieve, :ui, :picture], "Cache") if defined?(RPG::Cache)
      envuelve(Bitmap, [:blt, :stretch_blt, :draw_text, :get_pixel, :set_pixel, :fill_rect,
                        :clear, :dispose, :hue_change], "Bmp")
      Bitmap.singleton_class.prepend(Module.new {
        def new(*a, &b)
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            super
          ensure
            c = NXP::CUENTA[a[0].is_a?(String) ? "Bmp.new(fichero)" : "Bmp.new(wxh)"]
            c[0] += 1
            c[1] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
          end
        end
      })
      escribe("[perfil] envoltura puesta")
    end

    def informe
      filas = CUENTA.map { |k, (n, s, o)| [k, n, s, o] }
      CUENTA.clear
      filas.sort_by { |f| -f[2] }.first(14).map { |k, n, s, o|
        "%s %dx/%dms/%dkobj" % [k, n, (s * 1000).round, o / 1000]
      }.join("  ")
    end

    #--- marcos -------------------------------------------------------------
    def antes_de_update
      return unless @corriendo
      t = ahora
      if @fin_marco
        ruby = t - @fin_marco
        p = (PASOS[@etiqueta] ||= [0, 0.0, 0.0])
        p[0] += 1
        p[1] += ruby
        p[2] = ruby if ruby > p[2]
        if ruby > UMBRAL
          escribe("[lento] %4d ms | %s | %s" % [(ruby * 1000).round, @etiqueta, informe])
        end
      end
      CUENTA.clear
    end

    def despues_de_update
      @fin_marco = ahora if @corriendo
      @marcos += 1
    end

    #--- entrada de mentira ---------------------------------------------------
    def avanza
      if @espera > 0
        @espera -= 1
        @tecla = nil
        return
      end
      paso = @cola.shift
      if paso.nil?
        @tecla = Input::BACK
        @etiqueta = "(cola vacia: B)"
        return
      end
      @etiqueta, tecla, @espera = paso
      if tecla.is_a?(Proc)
        tecla.call rescue escribe("[perfil] paso #{@etiqueta}: #{$!.message}")
        @tecla = nil
      else
        @tecla = tecla
      end
    end

    def tecla
      @tecla
    end

    def instala_entrada
      Input.singleton_class.class_eval do
        alias_method :nxp_update_real, :update
        def update
          nxp_update_real
          NXP.avanza
        end
        def trigger?(k) = (NXP.tecla == k)
        def repeat?(k) = (NXP.tecla == k)
        def press?(k) = (NXP.tecla == k)
        def release?(_k) = false
        def triggerex?(_k) = false
        def pressex?(_k) = false
        def repeatex?(_k) = false
        def mouse_in_window = false
        def dir4
          case NXP.tecla
          when Input::DOWN then 2
          when Input::LEFT then 4
          when Input::RIGHT then 6
          when Input::UP then 8
          else 0
          end
        end
        def dir8 = dir4
      end
    end

    def guion(pasos)
      @cola.concat(pasos)
    end

    def pon(etq, tecla, n)
      [etq, tecla, n]
    end

    #--- flujos ---------------------------------------------------------------
    def flujo_dex
      i = Input
      # La entrada y la pagina Datos solo se abren para especies vistas y
      # capturadas: el equipo se registra en la Pokedex, solo en memoria.
      $player.party.each { |pk| ($player.pokedex.register(pk) rescue nil); ($player.pokedex.set_owned(pk.species) rescue nil) }
      pasos = [
        pon("dex: abrir", nil, 40),
        pon("dex: ir al Pokemon del equipo", proc {
          sc = NXP.escenas[:dex]
          # El primero del equipo que este en ESTA Pokedex (la de la partida de
          # la consola es la regional de 151, sin Litten).
          del_equipo = $player.party.map(&:species)
          lista = sc.instance_variable_get(:@dexlist)
          idx = lista.index { |d| del_equipo.include?(d[:species]) } || 0
          NXP.escribe("[perfil] dex: entrada #{idx} (#{lista[idx] && lista[idx][:species]}) de #{lista.length}")
          sc.sprites["pokedex"].index = idx
          sc.pbRefresh
        }, 10),
        pon("dex: abajo en la lista", i::DOWN, 10),
        pon("dex: arriba en la lista", i::UP, 10),
        pon("dex: A en la lista (abre la entrada)", i::USE, 60),
        pon("entrada: derecha (area)", i::RIGHT, 30),
        pon("entrada: derecha (formas)", i::RIGHT, 30),
        pon("entrada: derecha (datos)", i::RIGHT, 40),
        pon("datos: A (menu de datos)", i::USE, 60),
        pon("datos-menu: A sobre general (lista de especies)", i::USE, 60),
        pon("lista-especies: abajo", i::DOWN, 15),
        pon("lista-especies: B", i::BACK, 30),
        pon("datos-menu: B", i::BACK, 30),
        pon("datos: abajo (otra especie)", i::DOWN, 40),
        pon("datos: abajo (otra especie)", i::DOWN, 40),
        pon("datos: arriba (otra especie)", i::UP, 40),
        pon("entrada: izquierda (formas)", i::LEFT, 30),
        pon("entrada: B (vuelve a la lista)", i::BACK, 60),
        pon("dex: Y (buscador)", i::ACTION, 60),
        pon("buscador: B", i::BACK, 60),
        pon("dex: B (sale)", i::BACK, 60)
      ]
      guion(pasos)
      pbFadeOutIn do
        scene = PokemonPokedex_Scene.new
        NXP.escenas[:dex] = scene
        PokemonPokedexScreen.new(scene).pbStartScreen
      end
    end

    def flujo_equipo
      i = Input
      pasos = [pon("equipo: abrir", nil, 40)]
      5.times { |n| pasos << pon("equipo: abajo (panel #{n + 2})", i::DOWN, 15) }
      pasos << pon("equipo: arriba", i::UP, 15)
      pasos << pon("equipo: B (sale)", i::BACK, 40)
      guion(pasos)
      pbPokemonScreen
    end

    def flujo_datos
      i = Input
      pasos = [pon("resumen: abrir", nil, 40)]
      4.times { |n| pasos << pon("resumen: derecha (pagina #{n + 2})", i::RIGHT, 25) }
      pasos << pon("resumen: izquierda", i::LEFT, 25)
      5.times { |n| pasos << pon("resumen: abajo (Pokemon #{n + 2})", i::DOWN, 30) }
      3.times { pasos << pon("resumen: arriba (Pokemon anterior)", i::UP, 30) }
      pasos << pon("resumen: B (sale)", i::BACK, 40)
      guion(pasos)
      pbFadeOutIn do
        scene = PokemonSummary_Scene.new
        PokemonSummaryScreen.new(scene).pbStartScreen($player.party, 0)
      end
    end

    def flujo_mochila
      i = Input
      pasos = [pon("mochila: abrir", nil, 40)]
      3.times { pasos << pon("mochila: abajo", i::DOWN, 10) }
      3.times { pasos << pon("mochila: derecha (bolsillo)", i::RIGHT, 20) }
      pasos << pon("mochila: B (sale)", i::BACK, 40)
      guion(pasos)
      pbFadeOutIn do
        PokemonBagScreen.new(PokemonBag_Scene.new, $bag).pbStartScreen
      end
    end

    def flujo_prueba
      # 1) display_species? rapido contra el lineal
      if GameData::Species.method_defined?(:nx_display_species_lineal)
        sc = PokemonPokedex_Scene.new
        lista = sc.pbGetDexList rescue nil
        lista ||= []
        if lista.empty?
          escribe("[prueba] sin dexlist")
        else
          dif = 0; n = 0
          objetivos = [lista[0][:species], lista[lista.length / 2][:species], lista[-1][:species], $player.party[0].species]
          objetivos.each do |obj|
            s2 = GameData::Species.get(obj)
            GameData::Species.each do |sp|
              [[false, false], [true, false], [false, true], [true, true]].each do |a, b|
                n += 1
                dif += 1 if sp.display_species?(lista, s2, a, b) != sp.nx_display_species_lineal(lista, s2, a, b)
              end
            end
          end
          escribe("[prueba] display_species?: #{n} comparaciones, #{dif} diferencias (dexlist #{lista.length})")
        end
      end
      # 2) fotogramas perezosos contra recorte entero
      if DeluxeBitmapWrapper.method_defined?(:nx_refresh_entero)
        especies = GameData::Species.keys.first(400).select.with_index { |_, i| i % 40 == 0 }
        dif = 0; marcos = 0
        especies.each do |sp|
          f = GameData::Species.front_sprite_filename(sp) rescue nil
          next unless f
          met = GameData::SpeciesMetrics.get_species_form(sp, 0, false)
          a = DeluxeBitmapWrapper.new(f, met)
          a.hue_change(90)
          b = DeluxeBitmapWrapper.allocate
          b.instance_variable_set(:@bitmaps, [])
          b.instance_variable_set(:@bmp_file, f)
          b.instance_variable_set(:@scale, a.scale)
          b.instance_variable_set(:@speed, 0)
          b.instance_variable_set(:@frame_idx, 0)
          b.instance_variable_set(:@constrict_x, 0)
          b.instance_variable_set(:@constrict_y, 0)
          b.nx_refresh_entero(nil)
          b.instance_variable_get(:@bitmaps).each { |x| x.hue_change(90) }
          if a.length != b.length || a.width != b.width
            escribe("[prueba] #{sp}: medidas distintas #{a.length}/#{b.length} #{a.width}/#{b.width}")
            dif += 1
            next
          end
          a.length.times do |i|
            a.to_frame(i); b.to_frame(i)
            ba = a.bitmap; bb = b.bitmap
            marcos += 1
            if ba.respond_to?(:raw_data)
              dif += 1 if ba.raw_data != bb.raw_data
            else
              0.step(ba.width - 1, 7) { |x| 0.step(ba.height - 1, 7) { |y| (dif += 1; break) if ba.get_pixel(x, y).to_s != bb.get_pixel(x, y).to_s } }
            end
          end
          a.dispose; b.dispose
        end
        escribe("[prueba] fotogramas: #{especies.length} especies, #{marcos} fotogramas comparados, #{dif} distintos")
      end
    end

    def nxp_una_vuelta
      Graphics.nxp_update_real
    end

    def mide(etq, n)
      t0 = ahora
      n.times { yield }
      escribe("[micro] %-40s %6d x  %8.3f ms cada una" % [etq, n, (ahora - t0) * 1000.0 / n])
    end

    def flujo_micro
      h = { "a" => 1 }
      mide("Process.clock_gettime", 2000) { ahora }
      mide("GC.stat(:total_allocated_objects)", 2000) { GC.stat(:total_allocated_objects) }
      mide("Hash#key? con String", 2000) { h.key?("Graphics/Pictures/x") }
      mide("pbResolveBitmap (repetida)", 500) { pbResolveBitmap("Graphics/Pictures/Party/icon_ball") }
      mide("FileTest.exist? (no existe)", 50) { FileTest.exist?("Graphics/Pictures/no_existe.png") }
      b = Bitmap.new(64, 64)
      mide("Bitmap#set_pixel", 200) { b.set_pixel(3, 3, Color.new(1, 2, 3)) }
      mide("Bitmap#get_pixel", 200) { b.get_pixel(3, 3) }
      mide("Bitmap#fill_rect", 200) { b.fill_rect(0, 0, 8, 8, Color.new(1, 2, 3)) }
      mide("set_pixel + fill_rect alternos", 100) { b.set_pixel(3, 3, Color.new(1, 2, 3)); b.fill_rect(0, 0, 2, 2, Color.new(1, 2, 3)) }
      mide("Bitmap#draw_text", 100) { b.draw_text(0, 0, 64, 32, "Abc") }
      mide("Bitmap.new(96x96) + dispose", 100) { Bitmap.new(96, 96).dispose }
      if b.respond_to?(:nx_opaque_bounds)
        f = GameData::Species.front_sprite_filename($player.party[0].species) rescue nil
        if f
          s = Bitmap.new(f)
          mide("nx_opaque_bounds sobre #{s.width}x#{s.height}", 20) { s.nx_opaque_bounds }
          s.dispose
        end
      end
      b.dispose
    end

    def listo?
      !@hecho && defined?(Game) && Game.respond_to?(:load) && defined?(PokemonPokedexInfo_Scene) &&
        defined?(SaveData) && $data_system
    end

    def arranca
      @hecho = true
      nombre = File.exist?(File.join(RAIZ, "banco-menus.partida")) ? File.read(File.join(RAIZ, "banco-menus.partida")).strip : "Partida 1"
      ruta = File.join(System.data_directory, nombre + ".rxdata")
      escribe("[perfil] partida #{ruta}")
      datos = SaveData.read_from_file(ruta)
      Game.load(datos)
      $PokemonSystem.bgmvolume = 0 rescue nil
      $PokemonSystem.sevolume = 0 rescue nil
      pbBGMStop rescue nil
      escribe("[perfil] partida cargada: equipo #{$player.party.map(&:name).join(',')} | vistos #{$player.pokedex.seen_count} | capturados #{$player.pokedex.owned_count}") rescue nil
      if defined?(PokeAPI) && $PokemonGlobal.pokeapi_cache
        c = $PokemonGlobal.pokeapi_cache
        escribe("[perfil] pokeapi_cache: #{c.size} entradas, #{Marshal.dump(c).bytesize} bytes en Marshal; partida entera #{File.size(ruta)} bytes; claves #{c.keys.inspect}")
        if File.exist?(File.join(RAIZ, "banco-menus.sincache"))
          $PokemonGlobal.pokeapi_cache = {}
          escribe("[perfil] pokeapi_cache vaciado para medir la red")
        end
      end
      if File.exist?(File.join(RAIZ, "banco-menus.equipo6"))
        relleno = %i[PIKACHU CHARIZARD GENGAR LUCARIO GARCHOMP SPINDA EEVEE].select { |k| GameData::Species.exists?(k) }
        relleno.each do |k|
          break if $player.party.length >= 6
          $player.party.push(Pokemon.new(k, 40))
        end
        escribe("[perfil] equipo rellenado: #{$player.party.map { |pk| pk.species }.join(',')}")
      end
      # Los shims del juego se instalan en su propio Graphics.update, que esta
      # DENTRO del de este fichero: una vuelta para que lleguen antes de medir.
      nxp_una_vuelta
      instala_perfil
      instala_entrada
      flujos = File.exist?(File.join(RAIZ, "banco-menus.flujo")) ?
               File.read(File.join(RAIZ, "banco-menus.flujo")).split : %w[dex equipo datos mochila]
      flujos.each do |fl|
        escribe("[perfil] ==== flujo #{fl}")
        PASOS.clear
        @corriendo = true
        @fin_marco = nil
        t0 = ahora
        begin
          send("flujo_#{fl}")
        rescue Exception => e
          escribe("[perfil] flujo #{fl} fallo: #{e.class} #{e.message}\n  #{e.backtrace.first(8).join("\n  ")}")
        end
        @corriendo = false
        @cola.clear
        @espera = 0
        escribe("[perfil] flujo #{fl}: %.1f s" % (ahora - t0))
        if defined?(PokeAPI) && $PokemonGlobal.pokeapi_cache
          NXPokeAPI.recoge if defined?(NXPokeAPI)
          c = $PokemonGlobal.pokeapi_cache
          escribe("[perfil] pokeapi_cache tras el flujo: #{c.size} entradas, #{Marshal.dump(c).bytesize} bytes; claves #{c.keys.inspect}")
        end
        escribe(NXFotogramas.informe) if defined?(NXFotogramas)
        PASOS.each do |etq, (n, s, mx)|
          escribe("[paso] %-50s %4d marcos  total %5d ms  peor %4d ms" % [etq, n, (s * 1000).round, (mx * 1000).round])
        end
      end
      escribe("[perfil] fin")
      @f.flush
      Kernel.exit!(0)
    end
  end
end

module Graphics
  class << self
    alias_method :nxp_update_real, :update
    def update
      if NXP.listo?
        NXP.arranca
      end
      NXP.antes_de_update
      nxp_update_real
      NXP.despues_de_update
    end
  end
end

NXP.escribe("[perfil] preload cargado")

# En el PC no hay Bitmap#nx_opaque_bounds (es del motor de la consola) y
# findCenter cae al barrido con get_pixel, que en el PC se come la mitad de
# cada medida y en la consola no existe. Para que el reparto se parezca al de
# la consola, aqui se hace el mismo barrido sobre raw_data (mismas reglas que
# Bitmap::opaqueBounds de bitmap.cpp) y asi nx-centro.rb puede instalarse.
if !Bitmap.method_defined?(:nx_opaque_bounds) && Bitmap.method_defined?(:raw_data)
  class Bitmap
    def nx_opaque_bounds
      w = width; h = height
      return [-1, -1, -1, -1] if w <= 0 || h <= 0
      alfa = raw_data.unpack("C*").each_slice(4).map { |px| px[3] }
      fila = Array.new(h, false); col = Array.new(w, false)
      h.times do |y|
        base = y * w
        w.times { |x| if alfa[base + x] != 0 then fila[y] = true; col[x] = true end }
      end
      l = (1...w).find { |x| col[x] } || -1
      r = (w - 1).downto(0).find { |x| col[x] } || -1
      t = (1...h).find { |y| fila[y] } || -1
      b = (h - 1).downto(0).find { |y| fila[y] } || -1
      [l, r, t, b]
    end
  end
  NXP.escribe("[perfil] nx_opaque_bounds de mentira (raw_data) para el PC")
end

# Los shims que se prueban, por ruta relativa a la carpeta del juego.
if File.exist?(File.join(NXP::RAIZ, "banco-menus.shims"))
  File.read(File.join(NXP::RAIZ, "banco-menus.shims")).split.each do |n|
    load File.join(NXP::RAIZ, n)
    NXP.escribe("[perfil] shim #{n} cargado")
  end
end

class Dir
  class << self
    alias exists? exist? unless method_defined?(:exists?)
  end
end

class File
  class << self
    alias exists? exist? unless method_defined?(:exists?)
  end
end
