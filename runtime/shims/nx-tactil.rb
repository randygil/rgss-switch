# nx-tactil.rb — la pantalla tactil de la consola, sobre la interfaz de Essentials.
#
# EL MOTOR. Desde este shim, el primer dedo que toca la pantalla hace de boton
# izquierdo del raton (eventthread.cpp, nxDedoComoRaton): Input.mouse_x e
# Input.mouse_y dicen donde, ya en coordenadas de la pantalla logica del juego
# (512x384 en Anil, con el margen negro y la escala descontados), e
# Input.press?(Input::MOUSELEFT) si sigue apoyado. Es la misma API que el raton
# del PC, asi que este fichero se puede probar con el Game.exe de Windows y un
# raton de verdad. Antes, mkxp-z guardaba los dedos en un sitio que nadie leia
# y la pantalla tactil estaba muerta.
#
# ESTE FICHERO. Essentials no sabe nada de ratones: cada pantalla lee la
# cruceta y A/B y nada mas. Rehacer cada bucle para que entienda toques seria
# reescribir media interfaz -y la de cada plugin-. Lo que se hace es traducir:
#
#   - Un toque se decide en Input.update, al principio del fotograma, contra
#     lo que estaba en pantalla en el fotograma anterior (quien se registro al
#     actualizarse). Asi da igual que el bucle de la escena mire los botones
#     antes o despues de actualizar sus ventanas.
#   - "Pulsar A" es INYECTAR: durante ese fotograma Input.trigger?(Input::USE)
#     contesta que si, como si el jugador lo hubiera apretado. Lo mismo con B,
#     la cruceta o X/Y. El bucle original hace el resto, con sus sonidos, sus
#     menus y sus reglas.
#   - "Mover el cursor a tal sitio" es distinto en cada pantalla: en las
#     ventanas se fija el indice dentro de su propio update (para que la escena
#     se entere del cambio igual que con la cruceta); en el PC de cajas y en el
#     equipo se inyecta una flecha y se intercepta pbChangeSelection, que es la
#     funcion que esos bucles llaman para saber a donde va el cursor.
#
# QUE RESPONDE
#   - Cualquier lista de Essentials (SpriteWindow_Selectable y sus hijas:
#     Window_CommandPokemon, Window_AdvancedCommandPokemon, la mochila, la
#     tienda, la Pokedex, el menu de pausa, Si/No...): tocar una opcion la
#     selecciona, tocar la que ya estaba seleccionada la confirma (A).
#     Arrastrar arriba o abajo dentro de la lista la desplaza.
#   - Los mensajes: mientras un mensaje se esta escribiendo o espera, tocar en
#     cualquier sitio es A (acaba la linea o pasa a la siguiente). Si hay una
#     lista activa, manda la lista.
#   - El PC de cajas (PokemonStorageScene): tocar una casilla lleva alli el
#     cursor; tocar la que ya estaba seleccionada es A (su menu). ARRASTRAR un
#     Pokemon lo coge y soltarlo en otra casilla lo deja (o lo intercambia),
#     sin menu: es el "cambio rapido" del juego, encendido solo para ese gesto.
#     Con un Pokemon en la mano, tocar una casilla lo deja ahi. Las flechas de
#     la caja cambian de caja (tambien arrastrando un Pokemon encima), el
#     nombre abre el menu de la caja, y "Equipo" y "Salir" hacen lo suyo.
#     En la pestana del equipo, igual con sus seis huecos; "Atras" o tocar
#     fuera de la pestana la cierra.
#   - La pantalla del equipo (PokemonParty_Scene): tocar un Pokemon lo
#     selecciona, tocar el seleccionado es A; "Salir" tambien.
#   - La pantalla de cargar partida (PokemonLoad_Scene) y el menu de pausa
#     "DP Pause Menu" (DP_PauseMenu), con la misma regla que las listas.
#   - El resumen (PokemonSummary_Scene): deslizar de lado cambia de pagina, y
#     de arriba abajo, de Pokemon.
#   - En un juego de RPG Maker XP sin Essentials, las Window_Selectable de
#     siempre, con la misma regla que las listas.
#
# QUE NO: un toque que no cae sobre nada de lo anterior no hace nada (no hay
# "tocar fuera = B" salvo en la pestana del equipo del PC). Los combates, el
# mapa, las pestanas de la mochila y el teclado de texto siguen siendo de
# botones.
#
# Las clases de Essentials aun no existen cuando corre el preload, asi que los
# modulos se anteponen (Module#prepend) la primera vez que cada clase existe.
# Anteponer y no aliasar a proposito: un plugin que redefina el metodo con
# `def` despues de nosotros no se lleva el arreglo por delante, porque lo
# antepuesto va siempre delante de lo que tenga la clase.

module NXTactil
  # Cuantos pixeles de la pantalla logica hay que mover el dedo para que un
  # toque deje de ser un toque y pase a ser un arrastre. Un dedo nunca se
  # apoya quieto del todo.
  UMBRAL = 10

  # Con un fichero tactil-traza.txt en la carpeta del juego se apunta tambien
  # cada movimiento y cada suelta, fotograma a fotograma. Para depurar un gesto;
  # en juego normal solo se apunta la bajada.
  TRAZA = File.exist?("tactil-traza.txt") rescue false

  # Botones inyectados en este fotograma: boton => false mientras nadie lo ha
  # preguntado, true en cuanto alguien lo ve.
  INY = {}

  @pulsado  = false
  @arrastre = false
  @x = @y = @x0 = @y0 = 0
  @fc = -1
  @ventanas = [];  @ventanas_ant = []
  @escenas  = [];  @escenas_ant  = []
  @mensaje  = false; @mensaje_ant = false
  @dueno    = nil    # quien recibe los movimientos y la suelta de este toque
  @despues  = []     # lo que hay que hacer en el fotograma siguiente
  @pendientes = nil  # clases a las que aun no se ha antepuesto su modulo

  class << self
    attr_reader :x, :y, :x0, :y0, :pulsado

    def log(msg)
      NX.log("[tactil] " + msg) if defined?(NX)
    end

    def arrastre?; @arrastre; end

    # Cambiar de caja: X e Y desde v20 (Input::JUMPUP / JUMPDOWN); en v19, L y R.
    def caja_anterior
      defined?(Input::JUMPUP) ? Input::JUMPUP : Input::L
    end

    def caja_siguiente
      defined?(Input::JUMPDOWN) ? Input::JUMPDOWN : Input::R
    end

    def visto(b)
      return false unless INY.key?(b)
      INY[b] = true
    end

    def inyecta(*botones)
      botones.each { |b| INY[b] = false }
    end

    # Para el fotograma siguiente: el cursor tiene que llegar antes de que se
    # pulse A, y llegar es otra vuelta del bucle de la escena.
    def despues(&blk)
      @despues << blk
    end

    # El mismo boton, `veces` fotogramas seguidos: para los menus que solo
    # saben avanzar de uno en uno (y animan cada paso).
    def en_serie(boton, veces, &al_final)
      if veces <= 0
        al_final&.call
        return
      end
      inyecta(boton)
      despues { en_serie(boton, veces - 1, &al_final) }
    end

    # Llevar el cursor de una escena con pbChangeSelection a `sel`: se inyecta
    # una flecha y, cuando el bucle pregunte a donde lleva, se contesta `sel`.
    # Solo vale en el mismo fotograma: si el bucle no llego a preguntar (estaba
    # animando, o la flecha no le tocaba), la proxima flecha de verdad no puede
    # saltar a un sitio que el jugador ya ni recuerda.
    def lleva_a(escena, sel)
      @destino = [escena, sel, Graphics.frame_count]
      inyecta(Input::DOWN)
    end

    def destino(escena)
      d = @destino
      return nil unless d && d[0].equal?(escena)
      @destino = nil
      d[2] == Graphics.frame_count ? d[1] : nil
    end

    def registra_ventana(w); @ventanas << w; end
    def registra_escena(e);  @escenas << e unless @escenas.include?(e); end
    def registra_mensaje;    @mensaje = true; end

    def pendientes(lista)
      @pendientes = lista
    end

    def instala
      return if !@pendientes || @pendientes.empty?
      @pendientes.reject! do |nombre, mod|
        clase = nombre.split("::").inject(Object) do |m, c|
          break nil unless m.is_a?(Module) && m.const_defined?(c, false)
          m.const_get(c, false)
        end
        next false unless clase.is_a?(Class)
        clase.prepend(mod) unless clase.ancestors.include?(mod)
        log("#{nombre}: responde al toque")
        true
      end
    end

    # Se llama desde Input.update, despues del original.
    def actualiza
      instala if @pendientes && !@pendientes.empty?
      fc = Graphics.frame_count
      unless INY.empty?
        # Un Input.update de mas dentro del mismo fotograma (los hay: un
        # pbUpdateAnnotation, un "Input.update para que no se repita") no puede
        # llevarse una pulsacion que el bucle aun no ha mirado, o el toque se
        # pierde sin rastro. Lo que ya se vio, si se va: eso es justo lo que
        # quiere quien vacia la entrada despues de aceptar.
        if fc != @fc
          INY.clear
        else
          INY.delete_if { |_b, visto| visto }
        end
      end
      if fc != @fc
        @fc = fc
        @ventanas_ant, @ventanas = @ventanas, @ventanas_ant
        @ventanas.clear
        @escenas_ant, @escenas = @escenas, @escenas_ant
        @escenas.clear
        @mensaje_ant = @mensaje
        @mensaje = false
        unless @despues.empty?
          tareas = @despues
          @despues = []
          tareas.each { |t| (t.call rescue log("tarea: #{$!.class}: #{$!.message}")) }
        end
      end
      p = Input.nx_tactil_press?(Input::MOUSELEFT)
      return if !p && !@pulsado
      x = Input.mouse_x
      y = Input.mouse_y
      if p && !@pulsado
        @pulsado = true
        @arrastre = false
        @x = @x0 = x
        @y = @y0 = y
        baja
      elsif p
        return if x == @x && y == @y
        @x = x
        @y = y
        @arrastre ||= (x - @x0).abs > UMBRAL || (y - @y0).abs > UMBRAL
        log("mueve #{x},#{y} f#{@fc}#{@arrastre ? ' arrastre' : ''}") if TRAZA
        envia(:mueve)
      else
        @pulsado = false
        @x = x
        @y = y
        log("sube #{x},#{y} f#{@fc}") if TRAZA
        envia(:sube)
        @dueno = nil
      end
    rescue StandardError => e
      # Un fallo aqui no puede llevarse la partida: se apunta y el toque se pierde.
      log("#{e.class}: #{e.message} @ #{(e.backtrace || [])[0]}")
      @dueno = nil
    end

    def envia(ev)
      d = @dueno
      return unless d
      return @dueno = nil if d.respond_to?(:disposed?) && d.disposed?
      if d.is_a?(Proc)
        d.call(ev, @x, @y)
      else
        d.nx_toque(ev, @x, @y)
      end
    end

    # A quien le toca este toque. Primero la lista activa bajo el dedo (la de
    # encima, si se solapan). Si no cae en ninguna, la escena con cursor propio
    # que estuviera mirando los botones (el PC, el equipo, la mochila). Si no
    # hay escena pero si listas, nadie: tocar al lado de un menu no tiene que
    # hacer nada. Por ultimo, un mensaje que se este escribiendo.
    def baja
      @dueno = nil
      elige_dueno
    ensure
      # Un toque es un acontecimiento raro y cuesta una linea: se apunta donde
      # cayo y quien se lo quedo, que es lo primero que hay que saber cuando un
      # toque "no hace nada".
      quien = if @dueno.is_a?(Ventanas::Toque) then @dueno.ventana.class
              elsif @dueno then @dueno.class
              elsif !INY.empty? then "mensaje"
              else "nadie"
              end
      log("toque en #{@x},#{@y} -> #{quien}")
    end

    def elige_dueno
      vivas = @ventanas_ant.select { |w| Ventanas.viva?(w) }.uniq
      w = vivas.select { |v| Ventanas.contiene?(v, @x, @y) }.max_by { |v| Ventanas.altura(v) }
      if w
        @dueno = Ventanas::Toque.new(w)
        envia(:baja)
        return
      end
      # Fuera de las listas, la escena que las contiene (las pestanas de la
      # mochila estan al lado de su lista).
      e = @escenas_ant.last
      if e
        @dueno = e
        envia(:baja)
        return
      end
      return unless vivas.empty?
      inyecta(Input::C) if @mensaje_ant
    end
  end

  #=============================================================================
  # Las listas
  #=============================================================================
  module Ventanas
    module_function

    def viva?(w)
      return false if w.disposed?
      return false unless w.visible && w.active
      v = w.viewport
      return false if v && (v.disposed? || !v.visible)
      true
    end

    def origen(w)
      v = w.viewport
      return [w.x, w.y] unless v
      [v.rect.x - v.ox + w.x, v.rect.y - v.oy + w.y]
    end

    def contiene?(w, x, y)
      ox, oy = origen(w)
      x >= ox && y >= oy && x < ox + w.width && y < oy + w.height
    end

    def altura(w)
      v = w.viewport
      [(v ? v.z : 0), w.z]
    end

    # El elemento bajo el dedo, o nil.
    def item_en(w, x, y)
      ox, oy = origen(w)
      if w.respond_to?(:itemRect)       # Essentials: SpriteWindow_Selectable
        lx = x - ox - w.leftEdge + w.ox
        ly = y - oy - w.topEdge + w.oy
        n = w.itemCount
        top = w.top_item
        fin = [top + w.page_item_max + 1, n].min
        (top...fin).each do |i|
          r = w.itemRect(i)
          next if r.width <= 0 || r.height <= 0
          return i if lx >= r.x && lx < r.x + r.width && ly >= r.y && ly < r.y + r.height
        end
        nil
      else                              # RGSS: Window_Selectable de RPG Maker XP
        n = w.instance_variable_get(:@item_max).to_i
        cols = [w.instance_variable_get(:@column_max).to_i, 1].max
        cr = w.cursor_rect
        rh = cr.height > 0 ? cr.height : 32
        cw = cr.width > 0 ? cr.width : (w.width / cols - 32)
        lx = x - ox - 16 + w.ox
        ly = y - oy - 16 + w.oy
        return nil if lx < 0 || ly < 0
        col = cols > 1 ? lx / (cw + 32) : 0
        return nil if col >= cols || (cols > 1 && lx % (cw + 32) >= cw)
        i = (ly / rh) * cols + col
        (i >= 0 && i < n) ? i : nil
      end
    end

    def alto_fila(w)
      return w.rowHeight if w.respond_to?(:rowHeight)
      cr = w.cursor_rect
      cr.height > 0 ? cr.height : 32
    end

    def columnas(w)
      return w.columns if w.respond_to?(:columns)
      [w.instance_variable_get(:@column_max).to_i, 1].max
    end

    def cuenta(w)
      return w.itemCount if w.respond_to?(:itemCount)
      w.instance_variable_get(:@item_max).to_i
    end

    # Un toque sobre una lista, de la bajada a la suelta.
    class Toque
      def initialize(w)
        @w = w
      end

      def disposed?
        @w.disposed?
      end

      def ventana
        @w
      end

      def nx_toque(ev, x, y)
        w = @w
        case ev
        when :baja
          i = Ventanas.item_en(w, x, y)
          @item0 = i
          @era_sel = (i && i == w.index)
          @y_ref = y
          w.nx_pide_indice(i) if i && i != w.index
        when :mueve
          return unless NXTactil.arrastre?
          return if (x - NXTactil.x0).abs > (y - NXTactil.y0).abs   # eso es deslizar de lado
          # Arrastrar desplaza: el dedo sube, la lista avanza. Una fila por
          # cada alto de fila recorrido.
          rh = [Ventanas.alto_fila(w), 1].max
          filas = (@y_ref - y) / rh
          filas = -((y - @y_ref) / rh) if y > @y_ref
          return if filas == 0
          @y_ref -= filas * rh
          n = Ventanas.cuenta(w)
          return if n <= 0
          base = w.nx_indice_pedido || w.index
          nuevo = [[base + filas * Ventanas.columnas(w), 0].max, n - 1].min
          w.nx_pide_indice(nuevo) if nuevo != base
        when :sube
          if NXTactil.arrastre?
            # Deslizar de lado sobre una lista es izquierda/derecha: en la
            # mochila cambia de bolsillo, en una lista de varias columnas mueve
            # de columna, y en las demas no hace nada.
            dx = x - NXTactil.x0
            dy = y - NXTactil.y0
            if dx.abs >= Resumen::DESLIZ && dx.abs > dy.abs * 2
              NXTactil.inyecta(dx < 0 ? Input::RIGHT : Input::LEFT)
            end
            return
          end
          i = Ventanas.item_en(w, x, y)
          NXTactil.inyecta(Input::C) if @era_sel && i == @item0 && i == w.index
        end
      end
    end
  end

  # Lo que se antepone a las listas de Essentials.
  module Seleccionable
    def nx_pide_indice(i)
      @nx_indice = i
    end

    def nx_indice_pedido
      @nx_indice
    end

    def update
      if @nx_indice
        i = @nx_indice
        @nx_indice = nil
        if i != self.index && i >= 0 && i < (@item_max || 0)
          self.index = i
          pbPlayCursorSE if defined?(pbPlayCursorSE)
        end
      end
      super
      NXTactil.registra_ventana(self) if self.active && self.visible && !@ignore_input && (@item_max || 0) > 0
    end
  end

  # Y a las de RPG Maker XP, que no tienen pbPlayCursorSE.
  module SeleccionableRGSS
    def nx_pide_indice(i)
      @nx_indice = i
    end

    def nx_indice_pedido
      @nx_indice
    end

    def update
      if @nx_indice
        i = @nx_indice
        @nx_indice = nil
        if i != self.index && i >= 0 && i < (@item_max || 0)
          self.index = i
          $game_system.se_play($data_system.cursor_se) if $game_system && $data_system
        end
      end
      super
      NXTactil.registra_ventana(self) if self.active && self.visible && (@item_max || 0) > 0
    end
  end

  # Los mensajes: solo mientras se escriben o esperan a que el jugador siga.
  # Una ventana de texto quieta (la ayuda de la mochila, un cartel) no cuenta.
  module Mensaje
    def update
      super
      NXTactil.registra_mensaje if self.visible && @letterbyletter && busy?
    end
  end

  #=============================================================================
  # El PC de cajas
  #=============================================================================
  module Cajas
    def pbSelectBoxInternal(*args)
      @nx_rapido = false
      @nx_modo = :caja
      nx_devuelve
      super
    ensure
      @nx_modo = nil
    end

    def pbSelectPartyInternal(*args)
      @nx_rapido = false
      @nx_modo = :equipo
      nx_devuelve
      super
    ensure
      @nx_modo = nil
    end

    # Soltar lo arrastrado ENCIMA de otro Pokemon es, para el juego, un
    # intercambio: el de la casilla pasa a la mano. Con la cruceta tiene
    # sentido (llevas uno, coges otro); con el dedo no, porque el gesto era
    # "pon este aqui" y el jugador se encuentra con otro Pokemon pegado al dedo
    # que no ha pedido. Asi que el desplazado vuelve solo a donde salio el
    # primero: en la caja, a esa misma casilla, que se quedo vacia; en el
    # equipo, que se compacta al coger, al primer hueco libre.
    def nx_devuelve
      d = @nx_devolver
      @nx_devolver = nil
      return unless d && nx_lleva? && d[:modo] == @nx_modo
      return if @nx_modo == :caja && d[:caja] != @storage.currentBox
      destino = (@nx_modo == :equipo) ? @storage.party.length : d[:hueco]
      NXTactil.despues { nx_en_cuanto_llegue(destino, true) if @nx_modo }
    end

    def update
      NXTactil.registra_escena(self) if @nx_modo
      super
    end

    # El cambio rapido (el modo del juego en que A coge y deja sin menu), solo
    # para el gesto de arrastrar. pbStartScreen lo mira justo despues de que
    # pbSelectBox devuelva la casilla.
    def quickswap
      @nx_rapido || super
    end

    def pbSetArrow(arrow, selection)
      @nx_sel = (selection == -4 || selection == -5) ? -1 : selection
      super
    end

    def pbPartySetArrow(arrow, selection)
      @nx_sel_equipo = selection if selection >= 0
      super
    end

    def pbChangeSelection(key, selection)
      d = NXTactil.destino(self)
      return d if d
      super
    end

    def pbPartyChangeSelection(key, selection)
      d = NXTactil.destino(self)
      return d if d
      super
    end

    #--- Geometria (la de v19-v21: caja en 184,18, botones abajo a la derecha) --

    def nx_caja_en(x, y)
      box = @sprites["box"]
      return nil if !box || box.disposed?
      bx = box.x
      by = box.y
      if y >= by && y < by + 46 && x >= bx && x < bx + 324
        return :izq if x < bx + 40
        return :der if x >= bx + 284
        return :nombre
      end
      ancho = PokemonBox::BOX_WIDTH
      alto  = PokemonBox::BOX_HEIGHT
      if x >= bx + 4 && x < bx + 320 && y >= by + 46 && y < by + 296
        col = [[(x - (bx + 18)) / 48, 0].max, ancho - 1].min
        fila = [[(y - (by + 38)) / 48, 0].max, alto - 1].min
        return fila * ancho + col
      end
      if y >= Graphics.height - 70
        return :equipo if x >= 182 && x < 362
        return :salir  if x >= 370
      end
      nil
    end

    def nx_tam_equipo
      respond_to?(:max_party_size, true) ? max_party_size : Settings::MAX_PARTY_SIZE
    end

    def nx_equipo_en(x, y)
      ps = @sprites["boxparty"]
      return nil if !ps || ps.disposed?
      px = ps.x
      py = ps.y
      n = nx_tam_equipo
      n.times do |i|
        sx = px + 18 + (72 * (i % 2))
        sy = py + 2 + (16 * (i % 2)) + (64 * (i / 2))
        return i if x >= sx && x < sx + 64 && y >= sy && y < sy + 64
      end
      return :atras if x >= px + 18 && x < px + 154 && y >= py + 228 && y < py + 284
      return :fuera unless x >= px && x < px + 172 && y >= py && y < py + 352
      nil
    end

    #--- El gesto -------------------------------------------------------------

    def nx_lleva?
      @screen && @screen.pbHeldPokemon
    end

    def nx_pokemon_en(hueco)
      return nil unless hueco.is_a?(Integer) && hueco >= 0
      if @nx_modo == :equipo
        @storage.party[hueco]
      else
        @storage[@storage.currentBox, hueco]
      end
    end

    def nx_sel_actual
      @nx_modo == :equipo ? (@nx_sel_equipo || 0) : (@nx_sel || 0)
    end

    def nx_mueve_a(sel)
      return if sel == nx_sel_actual
      NXTactil.lleva_a(self, sel)
    end

    # A con el cambio rapido encendido: coger, dejar o intercambiar sin menu.
    def nx_rapido_a
      @nx_rapido = true
      NXTactil.inyecta(Input::C)
    end

    # Cuando el cursor ya este en `sel`, pulsar A (rapido o no).
    def nx_en_cuanto_llegue(sel, rapido)
      if sel == nx_sel_actual
        rapido ? nx_rapido_a : NXTactil.inyecta(Input::C)
      else
        nx_mueve_a(sel)
        NXTactil.despues do
          next unless @nx_modo && sel == nx_sel_actual
          rapido ? nx_rapido_a : NXTactil.inyecta(Input::C)
        end
      end
    end

    def nx_toque(ev, x, y, intentos = 0)
      unless @nx_modo
        # Soltar el dedo mientras el juego anima la cogida (pbHold no vuelve al
        # bucle hasta que la mano ha bajado y subido) no puede perderse, o el
        # Pokemon se queda en la mano sin que el jugador sepa por que. Se espera
        # a que la caja vuelva a mirar los botones, hasta un par de segundos.
        if ev == :sube && @nx_cogido && intentos < 120
          NXTactil.despues { nx_toque(ev, x, y, intentos + 1) }
        end
        return
      end
      organizar = (@command == 0) && !@multi
      hit = (@nx_modo == :equipo) ? nx_equipo_en(x, y) : nx_caja_en(x, y)
      case ev
      when :baja
        @nx_inicio = hit
        @nx_ultimo = hit
        @nx_cogido = false
        @nx_estaba = (hit == nx_sel_actual)
        case hit
        when Integer        then nx_mueve_a(hit)
        when :izq           then NXTactil.inyecta(NXTactil.caja_anterior)
        when :der           then NXTactil.inyecta(NXTactil.caja_siguiente)
        when :atras         then nx_mueve_a(nx_tam_equipo)
        when :nombre        then nx_mueve_a(-1)
        when :equipo        then nx_mueve_a(-2)
        when :salir         then nx_mueve_a(-3)
        end
      when :mueve
        return unless NXTactil.arrastre?
        if organizar && !@nx_cogido && !nx_lleva? && @nx_inicio.is_a?(Integer) &&
           hit != @nx_inicio && nx_pokemon_en(@nx_inicio) && nx_sel_actual == @nx_inicio
          # El dedo sale de la casilla con un Pokemon: se coge.
          @nx_cogido = true
          @nx_caja_inicio = @storage.currentBox
          nx_rapido_a
        elsif nx_lleva? && hit != @nx_ultimo
          case hit
          when Integer then nx_mueve_a(hit)
          when :izq    then NXTactil.inyecta(NXTactil.caja_anterior) if @nx_modo == :caja
          when :der    then NXTactil.inyecta(NXTactil.caja_siguiente) if @nx_modo == :caja
          end
        end
        @nx_ultimo = hit
      when :sube
        if NXTactil.arrastre?
          # Soltar lo arrastrado en la casilla de debajo; fuera de cualquier
          # casilla se queda en la mano.
          return unless organizar && nx_lleva? && hit.is_a?(Integer)
          if @nx_cogido && hit != @nx_inicio && nx_pokemon_en(hit)
            @nx_devolver = { modo: @nx_modo, caja: @nx_caja_inicio, hueco: @nx_inicio }
          end
          nx_en_cuanto_llegue(hit, true)
          return
        end
        return unless hit == @nx_inicio
        case hit
        when Integer
          if organizar && nx_lleva?
            nx_en_cuanto_llegue(hit, true)
          elsif @nx_estaba
            NXTactil.inyecta(Input::C)
          end
        when :nombre then nx_en_cuanto_llegue(-1, false)
        when :equipo then nx_en_cuanto_llegue(-2, false)
        when :salir  then nx_en_cuanto_llegue(-3, false)
        when :atras  then nx_en_cuanto_llegue(nx_tam_equipo, false)
        when :fuera  then NXTactil.inyecta(Input::B)
        end
      end
    end
  end

  #=============================================================================
  # La pantalla del equipo
  #=============================================================================
  module Equipo
    def pbChoosePokemon(*args)
      @nx_eligiendo = true
      super
    ensure
      @nx_eligiendo = false
    end

    def update
      NXTactil.registra_escena(self) if @nx_eligiendo
      super
    end

    def pbChangeSelection(key, currentsel)
      d = NXTactil.destino(self)
      return d if d
      super
    end

    def nx_hueco_en(x, y)
      i = 0
      while (s = @sprites["pokemon#{i}"])
        unless s.disposed?
          bmp = s.bitmap
          unless bmp
            fondo = s.instance_variable_get(:@panelbgsprite) || s.instance_variable_get(:@bgsprite)
            bmp = fondo.bitmap if fondo && !fondo.disposed?
          end
          if bmp && !bmp.disposed?
            return i if x >= s.x && y >= s.y && x < s.x + bmp.width && y < s.y + bmp.height
          end
        end
        i += 1
      end
      nil
    end

    def nx_toque(ev, x, y)
      return unless @nx_eligiendo
      hit = nx_hueco_en(x, y)
      case ev
      when :baja
        @nx_inicio = hit
        @nx_estaba = (hit && hit == @activecmd)
        return unless hit && hit != @activecmd
        # Un hueco vacio del equipo no se puede seleccionar con la cruceta.
        n = respond_to?(:max_party_size, true) ? max_party_size : Settings::MAX_PARTY_SIZE
        return if hit < n && !@party[hit]
        NXTactil.lleva_a(self, hit)
      when :sube
        return if NXTactil.arrastre? || hit.nil? || hit != @nx_inicio
        NXTactil.inyecta(Input::C) if @nx_estaba
      end
    end
  end
end

module NXTactil
  #=============================================================================
  # El menu de pausa "DP Pause Menu" (el de Anil): seis botones en columna que
  # no son una ventana. Tiene soporte de raton propio, pero contra un $mouse
  # de otro script que aqui no existe.
  #=============================================================================
  module MenuDP
    def update
      NXTactil.registra_escena(self) unless @done
      super
    end

    def nx_boton_en(x, y)
      return nil unless @count && x >= 316 && x < 500 && y >= 14 && y < 14 + (48 * @count)
      (y - 14) / 48
    end

    def nx_toque(ev, x, y)
      hit = nx_boton_en(x, y)
      case ev
      when :baja
        @nx_inicio = hit
        @nx_estaba = (hit && hit == @option)
        return unless hit && hit != @option
        # El bucle solo sabe moverse de uno en uno; se le dan los pasos por el
        # camino corto, uno por fotograma, y cada uno con su animacion.
        abajo = (hit - @option) % @count
        if abajo <= @count - abajo
          NXTactil.en_serie(Input::DOWN, abajo)
        else
          NXTactil.en_serie(Input::UP, @count - abajo)
        end
      when :sube
        return if NXTactil.arrastre? || hit.nil? || hit != @nx_inicio
        NXTactil.inyecta(Input::C) if @nx_estaba
      end
    end
  end
end

module NXTactil
  #=============================================================================
  # La pantalla de cargar partida: unos paneles que se mueven con una
  # Window_CommandPokemon INVISIBLE (la que lleva el indice). Tocar un panel lo
  # selecciona; tocar el seleccionado es A.
  #=============================================================================
  module Carga
    def pbChoose(*args)
      @nx_eligiendo = true
      super
    ensure
      @nx_eligiendo = false
    end

    def pbUpdate(*args)
      NXTactil.registra_escena(self) if @nx_eligiendo
      super
    end

    def nx_panel_en(x, y)
      n = 0
      n += 1 while @sprites["panel#{n}"]
      (n - 1).downto(0) do |i|
        s = @sprites["panel#{i}"]
        next if s.disposed? || !s.visible || !s.bitmap
        return i if x >= s.x && y >= s.y && x < s.x + s.bitmap.width && y < s.y + s.bitmap.height
      end
      nil
    end

    def nx_toque(ev, x, y)
      cw = @sprites["cmdwindow"]
      return if !@nx_eligiendo || !cw || cw.disposed?
      hit = nx_panel_en(x, y)
      case ev
      when :baja
        @nx_inicio = hit
        @nx_estaba = (hit && hit == cw.index)
        cw.nx_pide_indice(hit) if hit && hit != cw.index && cw.respond_to?(:nx_pide_indice)
      when :sube
        return if NXTactil.arrastre? || hit.nil? || hit != @nx_inicio
        NXTactil.inyecta(Input::C) if @nx_estaba
      end
    end
  end
end

module NXTactil
  #=============================================================================
  # El resumen del Pokemon: no tiene nada que tocar, pero pasar el dedo de lado
  # cambia de pagina (como izquierda/derecha) y de arriba abajo cambia de
  # Pokemon (como arriba/abajo). Un toque quieto no hace nada.
  #=============================================================================
  module Resumen
    DESLIZ = 60   # pixeles de pantalla logica para que cuente como deslizar

    def pbScene(*args)
      @nx_mirando = true
      super
    ensure
      @nx_mirando = false
    end

    def pbUpdate(*args)
      NXTactil.registra_escena(self) if @nx_mirando
      super
    end

    def nx_toque(ev, x, y)
      return unless ev == :sube && @nx_mirando && NXTactil.arrastre?
      dx = x - NXTactil.x0
      dy = y - NXTactil.y0
      if dx.abs >= DESLIZ && dx.abs > dy.abs * 3 / 2
        NXTactil.inyecta(dx < 0 ? Input::RIGHT : Input::LEFT)
      elsif dy.abs >= DESLIZ && dy.abs > dx.abs * 3 / 2
        NXTactil.inyecta(dy < 0 ? Input::DOWN : Input::UP)
      end
    end
  end
end

module NXTactil
  #=============================================================================
  # Los menus del combate (Luchar/Mochila/Pokemon/Huir y los cuatro
  # movimientos): botones sueltos, no ventanas. El bucle del combate guarda el
  # indice antes de pbUpdate y lo compara despues, asi que basta con fijarlo
  # durante Input.update: el juego ve el cambio, suena y repinta como con la
  # cruceta. Tocar el boton ya elegido es A. El menu de objetivos NO: su indice
  # es el del combatiente, y fijarlo a mano podria elegir uno que no vale.
  #=============================================================================
  module MenuCombate
    def update(*args)
      NXTactil.registra_escena(self) if self.visible && !disposed?
      super
    end

    def nx_boton_en(x, y)
      return nil unless @buttons
      @buttons.each_with_index do |b, i|
        next if !b || b.disposed? || !b.visible || !b.bitmap
        w = b.src_rect.width
        h = b.src_rect.height
        bx = b.x - b.ox
        by = b.y - b.oy
        return i if x >= bx && y >= by && x < bx + w && y < by + h
      end
      nil
    end

    def nx_toque(ev, x, y)
      return if disposed? || !self.visible
      hit = nx_boton_en(x, y)
      case ev
      when :baja
        @nx_inicio = hit
        @nx_estaba = (hit && hit == @index)
        self.index = hit if hit && hit != @index
      when :sube
        return if NXTactil.arrastre? || hit.nil? || hit != @nx_inicio
        NXTactil.inyecta(Input::C) if @nx_estaba
      end
    end
  end
end

module NXTactil
  #=============================================================================
  # La mochila: la lista ya es una ventana; lo que falta son los bolsillos.
  # Tocar el icono de un bolsillo va a el (a pasos de izquierda/derecha, que es
  # lo unico que entiende el bucle, y que se salta los vacios si se esta
  # eligiendo un objeto), y deslizar de lado fuera de la lista cambia de
  # bolsillo. Los iconos solo se conocen en la mochila "Bag Screen with
  # Party" (la de Anil); en las demas queda el deslizar.
  #=============================================================================
  module Mochila
    def pbChooseItem(*args)
      @nx_eligiendo = true
      super
    ensure
      @nx_eligiendo = false
    end

    def pbUpdate(*args)
      NXTactil.registra_escena(self) if @nx_eligiendo
      super
    end

    def nx_bolsillo_en(x, y)
      icono = @sprites["pocketicon"]
      return nil unless defined?(BagScreenWiInParty) && icono && !icono.disposed? && @bag
      n = @bag.pockets.length - 1
      extra = 0
      n.times do |k|
        i = k + 1
        bx = icono.x + (k * 14) + extra
        by = icono.y + ((i % 2) * 26)
        return i if x >= bx && x < bx + 28 && y >= by && y < by + 28
        extra += 2 if k.odd?
      end
      nil
    end

    def nx_ir_a_bolsillo(p, intentos = 20)
      w = @sprites["itemlist"]
      return if !@nx_eligiendo || !w || w.disposed? || w.pocket == p || intentos <= 0
      NXTactil.inyecta(p > w.pocket ? Input::RIGHT : Input::LEFT)
      NXTactil.despues { nx_ir_a_bolsillo(p, intentos - 1) }
    end

    def nx_toque(ev, x, y)
      return unless @nx_eligiendo
      case ev
      when :baja
        p = nx_bolsillo_en(x, y)
        nx_ir_a_bolsillo(p) if p
      when :sube
        return unless NXTactil.arrastre?
        dx = x - NXTactil.x0
        dy = y - NXTactil.y0
        if dx.abs >= Resumen::DESLIZ && dx.abs > dy.abs * 3 / 2
          NXTactil.inyecta(dx < 0 ? Input::RIGHT : Input::LEFT)
        end
      end
    end
  end
end

module Input
  class << self
    alias_method :nx_tactil_update, :update
    alias_method :nx_tactil_press?, :press?
    alias_method :nx_tactil_trigger?, :trigger?
    alias_method :nx_tactil_repeat?, :repeat?

    def update
      nx_tactil_update
      NXTactil.actualiza
    end

    def press?(b)
      nx_tactil_press?(b) || (!NXTactil::INY.empty? && NXTactil.visto(b))
    end

    def trigger?(b)
      nx_tactil_trigger?(b) || (!NXTactil::INY.empty? && NXTactil.visto(b))
    end

    def repeat?(b)
      nx_tactil_repeat?(b) || (!NXTactil::INY.empty? && NXTactil.visto(b))
    end
  end
end

NXTactil.pendientes([
  ["SpriteWindow_Selectable",   NXTactil::Seleccionable],
  ["Window_AdvancedTextPokemon", NXTactil::Mensaje],
  ["PokemonStorageScene",       NXTactil::Cajas],
  ["PokemonParty_Scene",        NXTactil::Equipo],
  ["DP_PauseMenu",              NXTactil::MenuDP],
  ["PokemonLoad_Scene",         NXTactil::Carga],
  ["PokemonSummary_Scene",      NXTactil::Resumen],
  ["PokemonBag_Scene",          NXTactil::Mochila],
  ["Battle::Scene::CommandMenu", NXTactil::MenuCombate],
  ["Battle::Scene::FightMenu",  NXTactil::MenuCombate],
  ["Window_Selectable",         NXTactil::SeleccionableRGSS]
])

NXTactil.log("a la espera de las ventanas del juego")
