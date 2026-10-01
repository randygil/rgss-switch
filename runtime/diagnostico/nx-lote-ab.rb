# nx-lote-ab.rb — el lote de sprites, comparado píxel a píxel contra el camino
# de siempre, en el mismo fotograma.
#
# El lote (patches/mkxpz-lote-sprites.patch, bitácora §5.74) junta en un solo
# dibujo los sprites seguidos que dibujan igual. Se comprobó a ojo, en el mapa:
# ni menús, ni combate, ni comparación exacta. Y con sin-lote.txt no se puede
# comparar exacto: hacen falta dos partidas, y dos partidas no llegan nunca al
# mismo fotograma, porque en Essentials v21 el agua, los PNJ, las flechas de
# los menús y los Pokémon que botan van por reloj (System.uptime), no por
# fotogramas. Cualquier diferencia se confundiría con una animación.
#
# Así que se compara DENTRO del mismo fotograma. Con diagnostico.txt puesto,
# el motor deja que la variable de entorno RGSS_SIN_LOTE apague el lote
# mientras exista (sprite.cpp, loteActivo). Cada CADA fotogramas esta sonda
# hace dos fotos de la escena con Graphics.snap_to_bitmap —una sin lote y otra
# con él— y compara los bytes. Entre las dos no corre Ruby: es la misma escena
# dibujada por los dos caminos. Si salen distintas, guarda las dos en crudo
# (nx-lote-ab-<n>-sin.raw y -con.raw, RGBA de 512x384 por filas, la de
# arriba primero, como raw_data de cualquier Bitmap), y apunta en mkxp-ruby.log el recuadro que
# cambia, cuántos píxeles, la escena, y los sprites visibles que caen dentro
# con todo lo que el lote mira para decidir (opacidad, mezcla, tono, color,
# destello, arbusto, onda, giro, zoom, espejo, viewport).
#
# Y una foto de control: cada CONTROL comparaciones, dos fotos CON lote. Si
# esas salen distintas, la foto no es repetible en esa escena (un bitmap
# animado, por ejemplo) y la comparación de ese momento no dice nada.
#
# Para demostrar que la variable llega al motor —si no llegara, todas las
# comparaciones saldrían iguales y no probarían nada—, en el mapa, entre los
# fotogramas de mapa SIN_LOTE_DESDE y CON_LOTE_DESDE, la sonda deja la
# variable puesta y no hace fotos: las líneas [ritmo] de mkxp-boot.log de ese
# tramo tienen que decir "lote 0 dibujos". Le sigue un tramo igual de largo,
# hasta MEDIDA_HASTA, con el lote y tampoco sin fotos: andando por el mismo
# sitio, las [ritmo] de los dos tramos son el antes y el después del lote en
# la misma partida y con el mismo binario.
#
# Cada INFORME fotogramas, una línea [lote-ab] con el recuento por escena.
#
# Uso: diagnostico.txt en la carpeta del juego, este fichero en lib/ y
# "lib/nx-lote-ab.rb" en preloadScript del mkxp.json de la tarjeta.

module NXLoteAB
  CADA = 15
  CONTROL = 10
  INFORME = 600
  MAX_GUARDADAS = 24
  SIN_LOTE_DESDE = 600
  CON_LOTE_DESDE = 2400
  MEDIDA_HASTA = 4200
  VAR = "RGSS_SIN_LOTE"
  CARPETA = Dir.pwd

  @f = 0
  @m = 0
  @n = 0
  @guardadas = 0
  @iguales = Hash.new(0)
  @distintas = Hash.new(0)
  @control_mal = Hash.new(0)
  @aviso_tamano = false

  def self.log(texto)
    if defined?(NX) && NX.respond_to?(:log)
      NX.log(texto)
    else
      @salida ||= ::File.open(::File.join(CARPETA, "nx-lote-ab.log"), "a").tap { |s| s.sync = true }
      @salida.write(texto + "\n")
    end
  end

  def self.foto(sin_lote)
    sin_lote ? ENV[VAR] = "1" : ENV.delete(VAR)
    b = Graphics.snap_to_bitmap
    datos = crudo(b)
    w = b.width
    h = b.height
    b.dispose
    [datos, w, h]
  ensure
    ENV.delete(VAR)
  end

  # raw_data de un Bitmap creado con Bitmap.new (el de la foto, o uno con un
  # fill_rect recién hecho), en Ryujinx, trae mal las filas cuando el ancho es
  # múltiplo de 16: de 512 sólo llegan las 128 primeras columnas, de 256 las
  # 64, de 640 las 160 —la cuarta parte— y el resto a cero; con 200, 257 o 511
  # de ancho sale entero. get_pixel lo mismo. Los bitmaps cargados de un
  # fichero no, porque se leen de su copia en memoria. Es lo que dejaba la foto
  # de §5.74 en 128 píxeles, y con ella esta comparación habría mirado una
  # cuarta parte de la pantalla. Así que se lee a tiras de TIRA columnas (171:
  # 171 + 171 + 170 para 512, ninguna múltiplo de 16), copiadas con blt —en un
  # Bitmap recién creado blt es una copia exacta, sin mezclar— y cosidas fila
  # a fila.
  TIRA = 171

  def self.crudo(b)
    w = b.width
    h = b.height
    return b.raw_data if w <= TIRA
    tiras = (0...w).step(TIRA).map do |x0|
      cw = [TIRA, w - x0].min
      t = Bitmap.new(cw, h)
      t.blt(0, 0, b, Rect.new(x0, 0, cw, h))
      d = t.raw_data
      t.dispose
      [cw, d]
    end
    out = String.new(capacity: w * h * 4)   # sin encoding: ya es ASCII-8BIT, y Encoding::BINARY no existe en el Ruby de la consola
    h.times do |y|
      tiras.each { |cw, d| out << d.byteslice(y * cw * 4, cw * 4) }
    end
    out
  end

  def self.sin_lote_fijo?
    @m >= SIN_LOTE_DESDE && @m < CON_LOTE_DESDE
  end

  def self.midiendo?
    @m >= SIN_LOTE_DESDE && @m < MEDIDA_HASTA
  end

  def self.ms
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) * 1000).round
  end

  # Los menús, el PC y el combate corren todos dentro de Scene_Map, así que
  # la escena sola no dice qué había en pantalla. Lo dice quién llamó a
  # Graphics.update: el bucle de cada pantalla (pbPokemonScreen, pbStartScreen,
  # pbCommandMenu...). Se toman los dos primeros métodos de la pila que no sean
  # de lib/ (los shims y esta sonda) ni un "update" a secas (los plugins que
  # encadenan Graphics.update con alias).
  def self.escena
    nombre = $scene ? $scene.class.to_s : "nil"
    pila = (caller_locations(3, 12) || []).reject { |l| l.path.to_s.start_with?("lib/") }
    etiquetas = pila.map { |l| l.label.to_s.sub(/^block (\(\d+ levels\) )?in /, "") }.reject { |e| %w[update loop each times].include?(e) }.uniq.first(2)
    etiquetas.empty? ? nombre : "#{nombre}<#{etiquetas.join('<')}"
  end

  def self.paso
    @f += 1
    @m += 1 if defined?(Scene_Map) && $scene.is_a?(Scene_Map) && @m < MEDIDA_HASTA
    if @m == SIN_LOTE_DESDE && !@apagado
      @apagado = true
      ENV[VAR] = "1"
      log("[lote-ab] f#{@f} t#{ms}: tramo SIN lote, #{CON_LOTE_DESDE - SIN_LOTE_DESDE} fotogramas de mapa (sus [ritmo] deben decir lote 0 dibujos)")
    elsif @m == CON_LOTE_DESDE && !@encendido
      @encendido = true
      ENV.delete(VAR)
      log("[lote-ab] f#{@f} t#{ms}: tramo CON lote, #{MEDIDA_HASTA - CON_LOTE_DESDE} fotogramas de mapa")
    elsif @m == MEDIDA_HASTA && !@medido
      @medido = true
      log("[lote-ab] f#{@f} t#{ms}: fin de los tramos de medida; vuelven las fotos")
    end
    informe if @f % INFORME == 0
    muestra if @m == 300 && !@muestra
    sintetico if @m == 400 && !@sintetico
    return if midiendo?
    return unless @f % CADA == 0
    return unless Graphics.respond_to?(:snap_to_bitmap)
    @n += 1
    esc = escena
    if @n % CONTROL == 0
      a, = foto(false)
      b, = foto(false)
      @control_mal[esc] += 1 if a != b
      return
    end
    sin, w, h = foto(true)
    con, = foto(false)
    if sin.bytesize != w * h * 4 && !@aviso_tamano
      @aviso_tamano = true
      log("[lote-ab] raw_data trae #{sin.bytesize} bytes para #{w}x#{h}")
    end
    if sin == con
      @iguales[esc] += 1
    else
      @distintas[esc] += 1
      diferencia(sin, con, w, h, esc)
    end
  end

  # Una pareja de fotos del mapa parado, se parezcan o no: para comprobar que
  # la foto trae la escena entera y no un rectángulo negro, que también sale
  # igual por los dos caminos y no probaría nada.
  def self.muestra
    @muestra = true
    sin, w, h = foto(true)
    con, = foto(false)
    ::File.binwrite(::File.join(CARPETA, "nx-lote-ab-muestra-sin.raw"), sin)
    ::File.binwrite(::File.join(CARPETA, "nx-lote-ab-muestra-con.raw"), con)
    log("[lote-ab] muestra del mapa parado (#{w}x#{h}, #{sin == con ? 'iguales' : 'DISTINTAS'}) -> nx-lote-ab-muestra-*.raw")
  end

  # El juego no tiene por qué pasar por todos los casos raros en una vuelta,
  # así que se fabrican: una vez, con el mapa parado, una serie de montajes de
  # sprites encima de todo, cada uno con lo que el lote tiene que saber
  # separar —espejo, zoom no entero, giro, tono igual y distinto, opacidad,
  # mezclas, color, destello, arbusto, onda, recortes, viewports con
  # desplazamiento y efectos, otra textura y un Plane en medio del orden z, un
  # bitmap tocado con set_pixel justo antes—, y cada montaje se fotografía por
  # los dos caminos. Sale una línea por montaje.
  def self.sintetico
    @sintetico = true
    t1 = textura(64, 48, 0)
    t2 = textura(40, 40, 1)
    montajes = {
      "cuadricula" => proc { |l| 48.times { |i| l << spr(t1, 8 + (i % 8) * 60, 8 + (i / 8) * 52) } },
      "espejo" => proc { |l| 24.times { |i| s = spr(t1, 10 + (i % 6) * 70, 20 + (i / 6) * 70); s.mirror = i.odd?; l << s } },
      "zoom" => proc do |l|
        [[2, 2], [0.5, 0.5], [1.37, 1.37], [1.5, 0.75], [3, 1], [0.33, 2.2]].each_with_index do |(zx, zy), i|
          s = spr(t1, 40 + (i % 3) * 150, 60 + (i / 3) * 160)
          s.zoom_x = zx; s.zoom_y = zy; s.ox = 17; s.oy = 11
          l << s
        end
        8.times { |i| l << spr(t1, 20 + i * 55, 330) }
      end,
      "giro" => proc do |l|
        [15, 30, 45, 90, 180, 270, 7.5, 333].each_with_index do |a, i|
          s = spr(t1, 60 + (i % 4) * 120, 90 + (i / 4) * 170)
          s.ox = 32; s.oy = 24; s.angle = a
          l << s
        end
      end,
      "tono" => proc do |l|
        a = Tone.new(-60, 20, 40, 0)
        b = Tone.new(30, -30, 0, 120)
        30.times do |i|
          s = spr(t1, 8 + (i % 6) * 80, 8 + (i / 6) * 70)
          s.tone = [a, a, b, Tone.new(0, 0, 0, 0), a, b][i % 6].clone
          l << s
        end
      end,
      "mezcla" => proc do |l|
        30.times do |i|
          s = spr(t1, 12 + (i % 6) * 40, 12 + (i / 6) * 30)   # se solapan: el orden importa
          case i % 10
          when 1 then s.opacity = 128
          when 3 then s.blend_type = 1
          when 5 then s.blend_type = 2
          when 6 then s.color = Color.new(255, 0, 0, 100)
          when 7 then s.flash(Color.new(255, 255, 255, 200), 30); s.update
          when 8 then s.bush_depth = 10
          end
          l << s
        end
      end,
      "orden-z" => proc do |l|
        24.times do |i|
          s = spr(i.even? ? t1 : t2, 20 + i * 18, 40 + (i % 5) * 20)
          s.z = 100_000 + (i * 7) % 11
          l << s
        end
        pl = Plane.new
        pl.bitmap = t2
        pl.z = 100_005
        pl.opacity = 160
        l << pl
        12.times { |i| s = spr(t1, 30 + i * 36, 240); s.z = 100_003 + (i % 4); l << s }
      end,
      "viewports" => proc do |l|
        v1 = Viewport.new(30, 20, 300, 200)
        v1.z = 100_000; v1.ox = 13; v1.oy = 7
        v2 = Viewport.new(200, 150, 280, 220)
        v2.z = 100_010; v2.tone = Tone.new(40, -20, -40, 60)
        v3 = Viewport.new(100, 250, 380, 120)
        v3.z = 100_020; v3.color = Color.new(0, 0, 255, 80)
        v3.flash(Color.new(255, 255, 0, 160), 40); v3.update
        [v1, v2, v3].each_with_index do |v, k|
          20.times { |i| l << spr(t1, -20 + (i % 5) * 70 + k * 3, -10 + (i / 5) * 55, v) }
        end
        l.concat([v1, v2, v3])
        10.times { |i| l << spr(t1, 300 + i * 9, 10 + i * 30) }
      end,
      "onda" => proc do |l|
        12.times do |i|
          s = spr(t1, 20 + (i % 4) * 110, 40 + (i / 4) * 110)
          if i == 5
            s.wave_amp = 6; s.wave_length = 60; s.wave_speed = 360; s.update
          end
          l << s
        end
      end,
      "recortes" => proc do |l|
        [[0, 0, 32, 24], [16, 8, 48, 40], [40, 30, 64, 64], [-8, -8, 30, 30], [60, 40, 20, 20], [0, 0, 64, 48]].each_with_index do |r, i|
          s = spr(t1, 30 + (i % 3) * 150, 40 + (i / 3) * 150)
          s.src_rect.set(*r)
          l << s
        end
      end,
      "set_pixel" => proc do |l|
        t3 = textura(32, 32, 2)
        10.times { |i| l << spr(t3, 40 + i * 40, 100) }
        10.times { |i| l << spr(t1, 20 + i * 45, 160) }
        20.times { |i| t3.set_pixel(i, i, Color.new(255, 255, 0)); t3.set_pixel(31 - i, i, Color.new(0, 255, 255)) }
        l << t3
      end
    }
    montajes.each do |nombre, monta|
      cosas = []
      begin
        monta.call(cosas)
        sin, w, h = foto(true)
        con, = foto(false)
        if sin == con
          log("[lote-ab] sintetico #{nombre}: iguales (#{cosas.size} piezas)")
        else
          @distintas["sintetico #{nombre}"] += 1
          diferencia(sin, con, w, h, "sintetico #{nombre}")
        end
      rescue StandardError => e
        log("[lote-ab] sintetico #{nombre}: fallo #{e.class} #{e.message} #{e.backtrace&.first}")
      ensure
        cosas.each { |c| c.dispose unless c.disposed? }
      end
    end
    [t1, t2].each(&:dispose)
  end

  def self.spr(bitmap, x, y, viewport = nil)
    s = Sprite.new(viewport)
    s.bitmap = bitmap
    s.x = x
    s.y = y
    s.z = 100_000
    s
  end

  # Franjas de colores con huecos semitransparentes: la mezcla y el orden se
  # notan en cuanto algo se dibuja en otro sitio o en otro orden.
  def self.textura(w, h, semilla)
    b = Bitmap.new(w, h)
    colores = [[220, 40, 40], [40, 200, 60], [50, 80, 230], [240, 220, 30], [200, 60, 220]]
    (0...h).step(4) do |y|
      c = colores[(y / 4 + semilla) % colores.size]
      b.fill_rect(0, y, w, 4, Color.new(c[0], c[1], c[2], (y / 4).even? ? 255 : 140))
    end
    b.fill_rect(w / 4, h / 4, w / 2, h / 2, Color.new(255, 255, 255, 60 + semilla * 50))
    b.fill_rect(0, 0, 3, h, Color.new(0, 0, 0, 255))
    b
  end

  def self.diferencia(sin, con, w, h, esc)
    a = sin.unpack("N*")
    b = con.unpack("N*")
    n = 0
    x0 = w; y0 = h; x1 = -1; y1 = -1
    i = 0
    total = a.size
    while i < total
      if a[i] != b[i]
        n += 1
        x = i % w
        y = i / w
        x0 = x if x < x0
        x1 = x if x > x1
        y0 = y if y < y0
        y1 = y if y > y1
      end
      i += 1
    end
    nombre = nil
    if @guardadas < MAX_GUARDADAS
      @guardadas += 1
      nombre = "nx-lote-ab-#{@guardadas}"
      ::File.binwrite(::File.join(CARPETA, nombre + "-sin.raw"), sin)
      ::File.binwrite(::File.join(CARPETA, nombre + "-con.raw"), con)
    end
    log("[lote-ab] DISTINTA f#{@f} #{esc}: #{n} px en (#{x0},#{y0})-(#{x1},#{y1}) #{w}x#{h}#{nombre ? " -> #{nombre}" : ''}")
    sospechosos(x0, y0, x1, y1)
  rescue StandardError => e
    log("[lote-ab] fallo al medir la diferencia: #{e.class} #{e.message}")
  end

  # Los sprites visibles cuyo recuadro aproximado toca la zona que cambia.
  def self.sospechosos(x0, y0, x1, y1)
    lista = []
    ObjectSpace.each_object(Sprite) do |s|
      next if s.disposed?
      next unless s.visible && s.bitmap && !s.bitmap.disposed? && s.opacity > 0
      vp = s.viewport
      ox = vp ? vp.rect.x - vp.ox : 0
      oy = vp ? vp.rect.y - vp.oy : 0
      sx = ox + s.x - s.ox * s.zoom_x
      sy = oy + s.y - s.oy * s.zoom_y
      sw = s.src_rect.width * s.zoom_x
      sh = s.src_rect.height * s.zoom_y
      next if s.angle == 0 && (sx > x1 || sy > y1 || sx + sw < x0 || sy + sh < y0)
      lista << s
    end
    lista.first(12).each do |s|
      t = s.tone
      c = s.color
      vp = s.viewport
      log(format("[lote-ab]   %s z%d xy(%d,%d) o(%d,%d) src%dx%d op%d bl%d tono(%d,%d,%d,%d) color(%d,%d,%d,%d) " \
                 "bush%d ang%.1f zoom(%.2f,%.2f) espejo%s onda%d vp%s",
                 s.class, s.z, s.x, s.y, s.ox, s.oy, s.src_rect.width, s.src_rect.height,
                 s.opacity, s.blend_type, t.red, t.green, t.blue, t.gray,
                 c.red, c.green, c.blue, c.alpha, s.bush_depth, s.angle, s.zoom_x, s.zoom_y,
                 s.mirror ? "1" : "0", (s.wave_amp rescue 0),
                 vp ? "(#{vp.rect.x},#{vp.rect.y},#{vp.rect.width},#{vp.rect.height} z#{vp.z} tono#{vp.tone.red.to_i},#{vp.tone.gray.to_i})" : "-"))
    end
    log("[lote-ab]   (#{lista.size} sprites tocan la zona)") if lista.size > 12
  rescue StandardError => e
    log("[lote-ab] fallo al listar sprites: #{e.class} #{e.message}")
  end

  def self.informe
    escenas = (@iguales.keys + @distintas.keys + @control_mal.keys).uniq
    partes = escenas.map do |e|
      s = "#{e} #{@iguales[e]}=/#{@distintas[e]}!"
      s += " control#{@control_mal[e]}!" if @control_mal[e] > 0
      s
    end
    log("[lote-ab] f#{@f}: #{partes.join(' | ')}")
  end
end

# Con alias y no con prepend, por lo dicho en nx-mapa.rb: los plugins de
# Essentials encadenan Graphics.update con alias.
module Graphics
  class << self
    alias_method :nx_lote_ab_update, :update
    def update(*a)
      begin
        NXLoteAB.paso
      rescue StandardError => e
        NXLoteAB.log("[lote-ab] fallo en la sonda: #{e.class} #{e.message} #{e.backtrace&.first}")
      end
      nx_lote_ab_update(*a)
    end
  end
end

NXLoteAB.log("[lote-ab] sonda cargada: cada #{NXLoteAB::CADA} fotogramas, foto sin lote y con lote")
