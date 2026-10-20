# encoding: utf-8
#
# nx-ruby18.rb — lo que le falta a un juego de Ruby 1.8 para correr sobre el
# CRuby 3.1.7 de la Switch.
#
# Cuatro juegos del censo (Opalo, Iberia, Titan, Z) comparten el mismo Game.exe
# byte a byte: mkxp-z con Ruby 1.8.7 embebido. Uranium es RGSS1 (Ruby 1.8.1).
# El motor de esta consola lleva 3.1.7 y no se va a portar el 1.8: el censo
# midio que la sintaxis de 1.8 son 25-28 lineas por juego en 3-4 ficheros sobre
# corpus de 118.000 a 160.000 lineas —entre el 0,002 % y el 0,02 % del fuente—,
# mientras que Win32API son 134-166 referencias en 20-29 ficheros. Portar el
# interprete costaria lo mismo en Win32API y ademas el interprete.
#
# Asi que aqui hay tres cosas, en este orden:
#
#   1. NXFuente.transforma  — arregla la sintaxis de 1.8 al cargar cada seccion
#                             de Scripts.rxdata, GUIADA POR EL COMPILADOR.
#   2. Win32API             — la clase postiza. Es lo que impide llegar a la
#                             pantalla de titulo: 12-14 de esas llamadas son
#                             asignaciones que se evaluan AL CARGAR el script,
#                             asi que revientan con NameError en la seccion 21
#                             de 168 y el juego no dibuja ni un pixel.
#   3. Metodos de 1.8       — solo los que se han contado en los cinco corpus.
#
# Se carga despues de nx-compat.rb, que es quien define NX.log y el modulo MKXP.

# ---------------------------------------------------------------------------
# 1. NXFuente: la transformacion de fuente
# ---------------------------------------------------------------------------
#
# El gancho del motor: antes de evaluar cada seccion de Scripts.rxdata mira si
# existe un modulo NXFuente que responda a `transforma`, y si existe evalua lo
# que devuelve. Si esto lanza, el motor registra la excepcion y evalua el
# original: nunca se puede quedar peor que sin shim.
#
# POR QUE GUIADA POR EL COMPILADOR Y NO A CIEGAS. Un gsub sobre 136.000 lineas
# encuentra `when` dentro de cadenas, `?:` ternarios y `break` de bloques, que
# son legitimos y que romper cuesta un fallo en mitad de una batalla, no un
# error al cargar. Aqui se compila primero: si compila —y compilan ~211 de los
# 214 scripts de Opalo, y los 450 de Anil, y los 432 de Vanguard— se devuelve el
# fuente sin tocar ni un byte. Solo cuando el compilador senala una linea con un
# error concreto se toca ESA linea, y se vuelve a compilar para comprobarlo.
# El censo llego a mano a 25 lineas en Opalo; este bucle tiene que llegar solo.
module NXFuente
  VUELTAS = 40          # tope: 23 `when X:` en un fichero caen en ~5 vueltas
  @ms = 0.0
  @secciones = 0
  @tocadas = 0
  @arreglos = 0
  @resumido = false

  class << self
    attr_reader :ms, :secciones, :tocadas, :arreglos
  end

  def self.reloj
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Un error de compilacion de Ruby 3.1 puede traer VARIOS errores concatenados
  # con saltos de linea (AudioUtilities da cinco de golpe), y cada uno viene con
  # su "nombre:LINEA: ". Se sacan todos: asi una vuelta arregla cuatro `when` en
  # vez de uno, y el bucle converge en cinco pasadas y no en veintitres.
  # El nombre llega del motor tal cual sale de Scripts.rxdata
  # (rb_ary_entry(script, 1)), y esos .rxdata los escribio RPG Maker XP con
  # Ruby 1.8: no llevan etiqueta de codificacion, asi que Marshal.load los
  # devuelve en ASCII-8BIT. Hay secciones con acentos -Opalo tiene "Titulo" y
  # "Meson Batalla" con tilde-, y construir una Regexp con un String binario
  # con bytes altos y casarla contra un mensaje UTF-8 lanza
  # Encoding::CompatibilityError. Se normaliza UNA vez y se usa el mismo
  # nombre para compilar y para leer el mensaje, que es lo que hace que el
  # prefijo "nombre:LINEA:" case.
  def self.limpio(nombre)
    n = nombre.to_s.dup.force_encoding("UTF-8")
    n.valid_encoding? ? n : n.scrub("?")
  rescue StandardError
    "seccion"
  end

  def self.errores(nombre, mensaje)
    lista = []
    escapado = Regexp.escape(nombre.to_s)
    texto = mensaje.to_s.dup.force_encoding("UTF-8")
    texto = texto.scrub("?") unless texto.valid_encoding?
    texto.each_line do |bruta|
      # chomp obligatorio: e.message de un SyntaxError con varios errores los
      # trae separados por saltos de linea y \z no casa con el \n final. Sin
      # esto, de los cinco errores de AudioUtilities solo se veia el ultimo
      # —"unexpected `end'", que no tiene arreglo— y los 23 `when X:` no se
      # tocaban nunca.
      linea = bruta.chomp
      if linea =~ /\A#{escapado}:(\d+): (.+)\z/
        lista << [$1.to_i, $2.strip]
      elsif linea =~ /\A.*?:(\d+): (syntax error.+|Invalid .+|invalid .+|too short .+)\z/
        # Reserva: el motor podria pasar un nombre con dos puntos dentro.
        lista << [$1.to_i, $2.strip]
      end
    end
    lista
  end

  def self.clasifica(texto)
    case texto
    when /Invalid break/                                  then :break
    when /Invalid retry/                                  then :retry
    when /invalid multibyte escape/,
         /too short escaped multibyte character/,
         /invalid multibyte char/                         then :regex
    when /unexpected ':'/, /expecting `then'/, /unexpected `when'/ then :cuando
    end
  end

  # La regex es LA DEL CENSO, no una parecida:
  #   /^(\s*when\b.*[^:\s]):(\s*(#.*)?)$/  ->  '\1 then\2'
  # Exige que lo de antes de los dos puntos no acabe en `:` ni en espacio (asi
  # no toca `when x ? a : b`) y que detras de los dos puntos no quede mas que
  # espacio o un comentario (asi no toca un `when` dentro de una cadena que
  # siga con texto). Los 23 de AudioUtilities son "  when 0: # dialtone".
  CUANDO = /^(\s*when\b.*[^:\s]):(\s*(#.*)?)$/

  def self.arregla(lineas, n, tipo, texto)
    i = n - 1
    return nil if i < 0 || i >= lineas.size
    vieja = lineas[i]
    nueva =
      case tipo
      when :cuando
        vieja.sub(CUANDO, '\1 then\2')
      when :break
        # `break` en el cuerpo de un metodo (no en un bloque) es un error de
        # COMPILACION, no de analisis: por eso el censo no uso `ruby -c`, que
        # daba "Syntax OK" sobre un fichero que no carga. En 1.8 salia del
        # metodo; el equivalente exacto en 3.1 es `return`. Tres casos, todos
        # en Iberia y Titan, todos de la forma "break if !opponent.pbCanX?".
        vieja.sub(/\bbreak\b/, "return")
      when :retry
        # `retry` fuera de un rescue se retiro en 1.9. Aqui esta dentro de un
        # bucle de la pantalla de carga ("vuelve a preguntar tras borrar la
        # partida"), y ahi el equivalente es `redo`. Mismo fichero y casi la
        # misma linea en los cuatro juegos (508 o 544).
        vieja.sub(/\bretry\b/, "redo")
      when :regex
        arregla_regex(vieja, texto)
      end
    return nil if nueva.nil? || nueva == vieja
    lineas[i] = nueva
    nueva
  end

  # El literal problematico viene DENTRO del mensaje de error:
  #   "invalid multibyte escape: /\"[^\"\\\\\\n\\r\\x00-\\x1f\\x7f-\\x9f]*\"/"
  # asi que no hay que adivinar donde empieza y acaba la expresion regular en
  # una linea que ademas lleva un comentario detras (`#"`): se busca ese texto
  # exacto y se le anade el modificador `n`, que es lo que le dice a Ruby que la
  # expresion es una secuencia de BYTES y no de caracteres UTF-8. Son literales
  # como /[\x00-\x1f\x7f-\x9f]/ que en 1.8 eran bytes por definicion.
  def self.arregla_regex(linea, texto)
    literal = texto[/(?:escape|character|char):\s*(\/.*\/)\s*\z/, 1]
    if literal && (pos = linea.index(literal))
      fin = pos + literal.length
      # linea[fin, 1] y no linea[fin]: da lo mismo con el `[]` de 3.1, pero deja
      # claro que aqui se quiere UN CARACTER y no un byte, sea cual sea la
      # codificacion con la que llego la seccion.
      fin += 1 while fin < linea.length && linea[fin, 1] =~ /[imxounse]/
      return linea[0...fin] + "n" + linea[fin..-1].to_s
    end
    # Reserva sin el mensaje: el primer literal de la linea que lleve un \xNN.
    linea.sub(%r{(/[^/\n]*\\x[0-9A-Fa-f]{2}[^/\n]*/)([imxounse]*)}) { "#{$1}#{$2}n" }
  end

  # El fuente llega del motor como String UTF-8.
  #
  # Reconvertir desde Windows-1252 es EL ULTIMO RECURSO y no el primero, y esto
  # se aprendio probando: 0140_PokemonOrgBattleRules.rb de Iberia tiene bytes
  # que no son UTF-8 valido y aun asi COMPILA, porque estan dentro de literales
  # de bytes. Reconvertirlo "por si acaso" cambiaba el fichero —y con el, el
  # significado de esos literales— sin que hiciera falta para nada. El censo ya
  # lo habia dicho: ni un solo fichero de los cinco juegos esta en Latin-1.
  # Asi que solo se intenta cuando el fichero no compila, no es UTF-8 valido y
  # no hay ningun arreglo conocido que aplicarle.
  def self.reencodifica(nombre, src)
    return nil if src.valid_encoding?
    convertido = src.encode("UTF-8", "Windows-1252")
    NX.log("[fuente] #{nombre}: no compila y no es UTF-8 valido; reconvertido de Windows-1252")
    convertido
  rescue StandardError
    nil
  end

  def self.transforma(nombre, codigo)
    t0 = reloj
    @secciones += 1
    src = codigo
    hechos = 0
    begin
      src = codigo.dup.force_encoding("UTF-8")
      src, hechos = bucle(limpio(nombre), src)
    rescue Exception => e
      # Cualquier cosa que no sea un SyntaxError esperado: se devuelve lo que
      # haya y se deja constancia. El motor evaluaria el original de todos
      # modos, pero asi el fallo tiene nombre.
      NX.log("[fuente] #{nombre}: FALLO de la transformacion #{e.class}: #{e.message}")
    end
    @ms += (reloj - t0) * 1000.0
    @tocadas += 1 if hechos > 0
    @arreglos += hechos
    # Entre seccion y seccion es el unico momento en que se puede arreglar lo
    # que depende de clases que el juego acaba de definir; ver NX18Tarde.
    NX18Tarde.revisar if defined?(NX18Tarde)
    resumen if nombre.to_s == "Main"
    src
  end

  def self.bucle(nombre, src)
    hechos = 0
    ya = {}
    silencio, $VERBOSE = $VERBOSE, nil   # compilar dos veces duplicaria los avisos
    begin
      VUELTAS.times do
        begin
          RubyVM::InstructionSequence.compile(src, nombre)
          NX.log("[fuente] #{nombre}: #{hechos} arreglos, compila") if hechos > 0
          return [src, hechos]
        rescue SyntaxError => e
          lista = errores(nombre, e.message)
          # Sin linea no hay a quien apuntar. Unico caso en que se toca el
          # fichero entero: los `when X:`, que la regex del censo acota sola.
          if lista.empty?
            lineas = src.lines
            n = 0
            lineas.each_index do |i|
              if lineas[i] =~ CUANDO
                lineas[i] = lineas[i].sub(CUANDO, '\1 then\2')
                n += 1
              end
            end
            if n == 0
              otro = reencodifica(nombre, src)
              if otro
                src = otro
                hechos += 1
                next
              end
              NX.log("[fuente] #{nombre}: NO COMPILA y el error no trae linea: #{e.message.lines.first.to_s.strip}")
              return [src, hechos]
            end
            NX.log("[fuente] #{nombre}: #{n} `when X:` sin linea en el mensaje, arreglados a ciegas con la regex del censo")
            hechos += n
            src = lineas.join
            next
          end

          lineas = src.lines
          cambio = 0
          lista.each do |linea, texto|
            tipo = clasifica(texto)
            next if tipo.nil?
            clave = "#{tipo}:#{linea}"
            next if ya[clave]          # no repetir el mismo arreglo en la misma linea
            nueva = arregla(lineas, linea, tipo, texto)
            next if nueva.nil?
            ya[clave] = true
            cambio += 1
            NX.log("[fuente] #{nombre}: linea #{linea} #{etiqueta(tipo)}")
          end
          if cambio == 0
            otro = reencodifica(nombre, src)
            if otro
              src = otro
              hechos += 1
              next
            end
            NX.log("[fuente] #{nombre}: NO COMPILA, sin arreglo conocido: #{e.message.lines.first.to_s.strip}")
            return [src, hechos]
          end
          hechos += cambio
          src = lineas.join
        end
      end
      NX.log("[fuente] #{nombre}: NO COMPILA tras #{VUELTAS} vueltas, se devuelve lo mejor que hay")
      [src, hechos]
    ensure
      $VERBOSE = silencio
    end
  end

  def self.etiqueta(tipo)
    case tipo
    when :cuando then "when X: -> when X then"
    when :break  then "break -> return (cuerpo de metodo)"
    when :retry  then "retry -> redo (fuera de rescue)"
    when :regex  then "regex con \\xNN -> se le anade /n"
    else tipo.to_s
    end
  end

  # "Main" es la ultima seccion de todo proyecto de RPG Maker XP, asi que el
  # resumen sale justo cuando ya han pasado todas y antes de que el juego
  # empiece. Lo que se quiere saber en la consola es el COSTE: esto se paga al
  # arrancar, una vez, y compilar dos veces cada seccion no es gratis.
  def self.resumen
    return if @resumido
    @resumido = true
    NX.log("[fuente] TOTAL: #{@secciones} secciones, #{@tocadas} tocadas, " \
           "#{@arreglos} arreglos, #{@ms.round(1)} ms")
  end
end
NX.log("[nx] NXFuente.transforma listo (sintaxis de Ruby 1.8 guiada por el compilador)")

# ---------------------------------------------------------------------------
# 2. Win32API postizo
# ---------------------------------------------------------------------------
#
# En mkxp-z lo aporta binding/miniffi-binding.cpp sobre SDL_LoadObject, y el
# Makefile de mkxp-z-nx lo excluye a proposito. Aunque se compilara, en Horizon
# no hay user32.dll que cargar.
#
# Lo que mata el arranque no son las llamadas: son las 12-14 asignaciones que se
# evaluan al cargar el script (`RtlMoveMemory = Win32API.new(...)` en el cuerpo
# de una clase, `@GetKeyState=Win32API.new(...)` en el de un modulo). Con la
# clase definida, todas ellas construyen un objeto y siguen adelante.
#
# OJO: los juegos REABREN esta clase. Opalo trae un 0005_Win32API.rb entero que
# hace `class Win32API` y le anade metodos de clase (SetWindowText, SetWindowPos,
# pbFindRgssWindow...), y su cuerpo lleva `@@GetCurrentThreadId=Win32API.new(...)`.
# Por eso esto tiene que ser una CLASE de verdad y no un modulo con method_missing.
class Win32API
  # Registro con cuentagotas. Estos juegos construyen el objeto Win32API DENTRO
  # del metodo que lo llama (Winsock hace `Win32API.new(DLL,"send",...).call(...)`
  # en cada envio) y algunos se llaman por fotograma: registrar cada vez llenaria
  # la SD y costaria un fsync a 60 Hz. Se registra la primera vez que se pide una
  # funcion y la primera vez que se llama, y nada mas.
  @@pedidas = {}
  @@llamadas = {}

  def self.nx_visto(mapa, clave, texto)
    return if mapa[clave]
    mapa[clave] = true
    NX.log(texto)
  end

  # 'kernel32', 'kernel32.dll', 'Kernel32.dll', './rubyscreen.dll' y
  # 'winmm.dll' aparecen los cinco en el mismo corpus: se normaliza o la tabla
  # de semanticas tendria que llevar cada variante.
  def self.nx_clave(dll, funcion)
    d = dll.to_s.tr("\\", "/").split("/").last.to_s
    d = d.sub(/\.dll\z/i, "")
    "#{d.downcase}!#{funcion}"
  end

  attr_reader :nx_dll, :nx_funcion, :nx_importa, :nx_exporta, :nx_clave

  def initialize(dll = "", funcion = "", importa = nil, exporta = nil)
    @nx_dll     = dll.to_s
    @nx_funcion = funcion.to_s
    # `importa` llega de siete formas distintas en el mismo juego: 'LLIIIII',
    # %w(l p) (Array), ['P']*3 (Array), '%w(l p)' (una cadena con el %w dentro,
    # que en 1.8 tampoco significaba nada) y '' . No se usa para nada; se guarda
    # tal cual por si algun dia hace falta para diagnosticar.
    @nx_importa = importa
    @nx_exporta = (exporta.is_a?(Array) ? exporta.join : exporta.to_s)
    @nx_clave   = Win32API.nx_clave(@nx_dll, @nx_funcion)
    Win32API.nx_visto(@@pedidas, @nx_clave,
                      "[win32api] #{@nx_clave} pedido por el script")
  end

  def call(*args)
    Win32API.nx_visto(@@llamadas, @nx_clave,
                      "[win32api] #{@nx_clave} llamado (solo se avisa la 1a vez)")
    NXWin32.despacha(@nx_clave, @nx_exporta, args)
  rescue Exception => e
    # Un fallo del postizo no puede tumbar el juego: devolver el neutro es
    # exactamente lo que haria la version muda.
    NX.log("[win32api] #{@nx_clave}: FALLO del postizo #{e.class}: #{e.message}")
    NXWin32.neutro(@nx_exporta)
  end
  alias Call call

  def to_s
    "#<Win32API #{@nx_clave}>"
  end
  alias inspect to_s
end

# La semantica, separada de la clase para que los juegos puedan reabrir
# `class Win32API` sin riesgo de pisar nada de esto.
module NXWin32
  # El valor neutro segun el tipo de retorno declarado.
  #
  # Se devuelve 0 tambien para 'v'/'V' (void) y para '' aunque en Win32API de
  # verdad no devuelvan nada: en estos scripts el resultado de una llamada de
  # tipo 'V' se compara con cero (`mciSendString`) o se le aplica una mascara
  # (`@GetKeyState.call(key)&0x8000`), y un nil daria NoMethodError en un sitio
  # que no tiene ninguna relacion con el problema.
  def self.neutro(exporta)
    case exporta.to_s[0, 1].to_s.downcase
    when "p" then ""
    else 0
    end
  end

  # Tamano de la ventana. Los juegos preguntan por el para centrar la ventana y
  # para calcular margenes; devolver 0 lo mas facil, pero un 0 aqui se acaba
  # dividiendo en algun sitio. Se contesta con la resolucion real si Graphics ya
  # existe (en el preload todavia no) y con la de Essentials clasico si no.
  def self.ancho
    (defined?(Graphics) && Graphics.respond_to?(:width) ? Graphics.width : 512) rescue 512
  end

  def self.alto
    (defined?(Graphics) && Graphics.respond_to?(:height) ? Graphics.height : 384) rescue 384
  end

  # Escribe en un bufer que el script paso por referencia. En Win32API el
  # patron es siempre el mismo: `buf = "\0"*256; api.call(..., buf, 256, ...)` y
  # luego `buf.delete!("\0")` o `buf.unpack(...)`. En Ruby eso solo funciona si
  # se MUTA la cadena que llego; asignarle otra no hace nada.
  def self.rellena(buf, datos)
    return 0 unless buf.is_a?(String)
    n = buf.bytesize
    d = datos.to_s.dup.force_encoding("ASCII-8BIT")
    d = d[0, n] if n > 0 && d.bytesize > n
    d += "\0" * (n - d.bytesize) if n > d.bytesize
    buf.replace(d)
    datos.to_s.bytesize
  end

  # Un puñado de constantes de winsock, para que se lea lo que devuelve.
  INVALID_SOCKET  = -1
  SOCKET_ERROR    = -1
  WSAENETDOWN     = 10050
  INADDR_NONE     = 0xFFFFFFFF

  def self.despacha(clave, exporta, args)
    case clave

    # --- Game.ini: lo unico de esta lista que se implementa DE VERDAD --------
    # Los juegos guardan y leen opciones ahi (el nombre del Scripts.rxdata, la
    # ruta del RTP, ajustes propios), y el fichero existe en la tarjeta porque
    # §2 de CONVENCIONES.md copia sueltos todos los ficheros de la raiz.
    # Firma: GetPrivateProfileString(seccion, clave, omision, buf, tam, ruta)
    when "kernel32!GetPrivateProfileString"
      seccion, llave, omision, buf, _tam, ruta = args
      valor = NXIni.lee(ruta, seccion, llave, omision.to_s)
      rellena(buf, valor)

    # Firma: WritePrivateProfileString(seccion, clave, valor, ruta)
    when "kernel32!WritePrivateProfileString"
      seccion, llave, valor, ruta = args
      NXIni.escribe(ruta, seccion, llave, valor) ? 1 : 0

    # WriteProfileString escribe en WIN.INI (el del sistema). Aqui no hay
    # ninguno y nadie lo lee: 1 (exito) para que el llamante no reintente.
    when "kernel32!WriteProfileString"
      1

    # --- memoria ------------------------------------------------------------
    # RtlMoveMemory es 34 de las 164 referencias de Opalo y NO SE PUEDE hacer:
    # el juego pasa `bitmap.__id__*2+16` como si el object_id fuera la direccion
    # del objeto, que era cierto en el Ruby 1.8 de 32 bits y no lo es en ningun
    # Ruby moderno. Escribir ahi seria corromper el monton. Devuelve 0 y el
    # bufer del script se queda a ceros, que es lo que ya pasa hoy.
    when "kernel32!RtlMoveMemory"
      NXWin32.aviso(clave, "no se copia memoria: los __id__ de 3.1 no son punteros")
      0

    # --- ventana ------------------------------------------------------------
    # pbFindRgssWindow de 0005_Win32API.rb hace
    #   begin; nextwindow=FindWindowEx.call(0,nextwindow,"RGSS Player",0)
    #     ... end until nextwindow==0
    #   raise "Can't find RGSS player window"
    # o sea que si FindWindow devuelve 0 el metodo LANZA. Se devuelve un asa
    # falsa (1) y se hace que GetCurrentThreadId y GetWindowThreadProcessId
    # coincidan, con lo que el bucle sale en la primera vuelta con la asa 1 y
    # nadie lanza nada. Todo lo que se haga despues con esa asa es inofensivo.
    when "user32!FindWindow", "user32!FindWindowEx", "user32!GetForegroundWindow",
         "user32!GetActiveWindow"
      1
    when "kernel32!GetCurrentThreadId", "user32!GetWindowThreadProcessId"
      1

    when "user32!GetWindowRect", "user32!GetClientRect"
      # rect.unpack('l4') -> x, y, derecha, abajo. El script hace
      # Rect.new(x,y,width-x,height-y), asi que 0,0,W,H da la ventana entera.
      rect = args[1]
      rellena(rect, [0, 0, ancho, alto].pack("l4"))
      1

    when "user32!GetSystemMetrics"
      # SM_CXSCREEN=0, SM_CYSCREEN=1. Lo demas, 0.
      case args[0].to_i
      when 0 then 1280
      when 1 then 720
      else 0
      end

    when "user32!GetCursorPos"
      rellena(args[0], [0, 0].pack("l2"))
      1

    when "user32!ScreenToClient"
      1

    # Mover, redimensionar y renombrar la ventana no significa nada con la
    # pantalla completa fija de la consola: 0 y a otra cosa.
    when "user32!SetWindowPos", "user32!SetWindowLong", "user32!SetWindowTextA",
         "user32!ShowWindow", "user32!MoveWindow", "user32!SendMessage",
         "user32!PostMessage", "user32!SetCapture", "user32!ReleaseCapture",
         "user32!ShowCursor", "user32!RegisterHotKey", "user32!MessageBox"
      0

    # --- teclado y raton ----------------------------------------------------
    # 0 = ninguna tecla pulsada. La entrada del jugador NO pasa por aqui: pasa
    # por Input.*, que mkxp-z tiene y el motor mapea a los botones del mando.
    # Estos Win32API son el teclado "extra" (atajos de depuracion, el editor de
    # animaciones, la tarjeta de entrenador de Opalo) y el ToUnicode de la
    # entrada de texto. Ver la nota sobre USEKEYBOARDTEXTENTRY al final.
    when "user32!GetKeyState", "user32!GetAsyncKeyState", "user32!MapVirtualKey",
         "user32!ToUnicode", "user32!PeekMessage"
      0

    when "user32!GetKeyboardState"
      rellena(args[0], "\0" * 256)
      1

    # --- bateria ------------------------------------------------------------
    # pbBatteryLow? hace power="\0"*12; sps.call(power); power.unpack("CCCCVV").
    # Se rellena la SYSTEM_POWER_STATUS de una maquina enchufada y sin bateria:
    # ACLineStatus=1, BatteryFlag=128 (sin bateria), BatteryLifePercent=255
    # (desconocido), y los dos tiempos a -1. Con eso pbBatteryLow? da false y el
    # juego no ensena el aviso de "guarda, que te quedas sin bateria" en una
    # consola cuya bateria no controla.
    when "kernel32!GetSystemPowerStatus"
      rellena(args[0], [1, 128, 255, 0, 0xFFFFFFFF, 0xFFFFFFFF].pack("CCCCVV"))
      1

    # --- usuario y sistema --------------------------------------------------
    # GetUserName(buf, tambuf): el juego lo usa para el nombre por omision del
    # entrenador y para la carpeta de guardado. "Switch" es mejor que vacio.
    when "advapi32!GetUserName", "advapi32!GetUserNameA"
      rellena(args[0], "Switch\0")
      rellena(args[1], [7].pack("L")) if args[1].is_a?(String)
      1

    when "kernel32!GetUserDefaultLangID"
      0x0C0A          # espanol (Espana). Estos cuatro juegos estan en espanol.
    when "kernel32!GetUserGeoID"
      217             # Espana
    when "kernel32!GetLastError"
      0
    when "kernel32!GetCurrentProcess"
      1
    when "kernel32!SetPriorityClass", "kernel32!LoadLibrary", "kernel32!FreeLibrary"
      # LoadLibrary devuelve 0 = "no se pudo cargar": es lo que se quiere, que
      # el juego concluya que la DLL no esta y se vaya por el camino de reserva.
      0

    # La consola de depuracion de Windows. No hay ninguna; ya se escribe todo en
    # mkxp-ruby.log por el $stdout de nx-compat.rb.
    when /\Akernel32!(AllocConsole|CreateConsoleScreenBuffer|SetConsole|WriteConsole|ReadConsole|FormatMessage)/
      0

    # El registro de Windows (MiniRegistry: busca la ruta del RTP y el ajuste
    # PlaySound). 2 = ERROR_FILE_NOT_FOUND, que es la verdad.
    when /\Aadvapi32!Reg/
      2

    # --- lo que no se puede tapar, solo callar ------------------------------
    when /\Awinmm!/, /\Awinmm\.dll!/
      # mciSendString (video), waveOut* (el segundo sistema de audio, el que
      # reproduce wave a mano para los tonos del telefono). El audio normal del
      # juego va por la clase Audio de mkxp-z y no pasa por aqui.
      0

    when /\Arubyscreen!/
      NXWin32.aviso(clave, "captura de pantalla desactivada")
      0

    when "gdi32!AddFontResource"
      # Las fuentes del juego las carga mkxp-z solo desde Fonts/.
      0

    when /\Agdi32!/
      0

    when /\Akleinbitmap!/
      NXWin32.aviso(clave, "KleinBitmap.dll no esta: ese bitmap NO se ha procesado")
      0

    when /\Agif!/
      # Va protegido con `if safeExists?("gif.dll")` y la DLL no viaja a la
      # tarjeta, asi que esto no deberia llamarse nunca. Si sale en el registro,
      # es que alguien copio la DLL a mano.
      0

    when /\Aaudio!/, /\Argss linker!/, /\Argss fmodex!/
      NXWin32.aviso(clave, "audio nativo desactivado; suena por la clase Audio de mkxp-z")
      0

    when /\Ashell32!/, /\Aole32!/
      # SHGetSpecialFolderLocation / SHGetKnownFolderPath: "Mis documentos",
      # donde Essentials quiere guardar. 1 = fallo -> el juego cae a su reserva,
      # que es guardar junto al ejecutable, que es lo que hay que hacer aqui.
      1

    when /\Amsvcrt!/, /\Axinput/
      0

    # --- sockets ------------------------------------------------------------
    # 0006_Sockets.rb monta TCP entero sobre Win32API de ws2_32 (12 usos en un
    # fichero). No hay red que ofrecer, pero SI hay que contestar de forma que
    # el codigo concluya "sin conexion" y siga: devolver 0 en `socket` seria un
    # descriptor VALIDO y el juego se quedaria esperando datos para siempre.
    when "ws2_32!socket", "ws2_32!accept"
      INVALID_SOCKET
    when "ws2_32!connect", "ws2_32!bind", "ws2_32!listen", "ws2_32!send",
         "ws2_32!recv", "ws2_32!select", "ws2_32!setsockopt", "ws2_32!shutdown",
         "ws2_32!ioctlsocket", "ws2_32!WSAStartup"
      SOCKET_ERROR
    when "ws2_32!WSAGetLastError"
      WSAENETDOWN                       # "la red esta caida": la verdad exacta
    when "ws2_32!closesocket"
      0                                 # cerrar lo que no existe siempre va bien
    when "ws2_32!gethostbyname", "ws2_32!gethostbyaddr", "ws2_32!getservbyname"
      0                                 # NULL
    when "ws2_32!inet_addr"
      INADDR_NONE
    when "ws2_32!inet_ntoa"
      "0.0.0.0"
    when "ws2_32!htons", "ws2_32!htonl", "ws2_32!ntohs", "ws2_32!ntohl"
      args[0].to_i                      # sin conversion: nadie mira el orden
    when "ws2_32!gethostname"
      rellena(args[0], "switch\0")
      0

    else
      NXWin32.aviso(clave, "sin semantica: se devuelve el neutro")
      neutro(exporta)
    end
  end

  @@avisos = {}
  def self.aviso(clave, texto)
    return if @@avisos[clave]
    @@avisos[clave] = true
    NX.log("[win32api] #{clave}: #{texto}")
  end
end

# Un .ini de veinte lineas. No se usa una gema ni se intenta cubrir el formato
# entero: sirve para Game.ini, que es "[Game]\nLibrary=...\nScripts=...".
module NXIni
  # Las rutas llegan como ".\\Game.ini" y como "./Game.ini". El motor ya hizo
  # chdir a la carpeta del juego, asi que basta con quedarse con el nombre.
  def self.ruta(r)
    s = r.to_s.tr("\\", "/")
    s = s.sub(%r{\A\./}, "")
    s
  end

  def self.lee(r, seccion, llave, omision)
    texto = File.binread(ruta(r)) rescue nil
    return omision unless texto
    actual = nil
    texto.force_encoding("UTF-8")
    texto.each_line do |l|
      l = l.strip
      next if l.empty? || l.start_with?(";", "#")
      if l =~ /\A\[(.*)\]\z/
        actual = $1.strip.downcase
      elsif (i = l.index("="))
        next unless actual == seccion.to_s.downcase
        next unless l[0...i].strip.downcase == llave.to_s.downcase
        return l[(i + 1)..-1].to_s.strip
      end
    end
    omision
  rescue StandardError => e
    NX.log("[ini] no se pudo leer #{ruta(r)}: #{e.class}: #{e.message}")
    omision
  end

  def self.escribe(r, seccion, llave, valor)
    destino = ruta(r)
    lineas = (File.binread(destino).force_encoding("UTF-8").lines rescue [])
    actual = nil
    puesto = false
    fin_seccion = nil
    lineas.each_index do |i|
      l = lineas[i].strip
      if l =~ /\A\[(.*)\]\z/
        fin_seccion = i if actual == seccion.to_s.downcase && fin_seccion.nil?
        actual = $1.strip.downcase
      elsif (j = l.index("=")) && actual == seccion.to_s.downcase &&
            l[0...j].strip.downcase == llave.to_s.downcase
        lineas[i] = "#{llave}=#{valor}\n"
        puesto = true
        break
      end
    end
    unless puesto
      if lineas.any? { |l| l.strip.downcase == "[#{seccion.to_s.downcase}]" }
        pos = fin_seccion || lineas.size
        lineas.insert(pos, "#{llave}=#{valor}\n")
      else
        lineas << "\n" unless lineas.empty? || lineas.last.end_with?("\n")
        lineas << "[#{seccion}]\n" << "#{llave}=#{valor}\n"
      end
    end
    File.binwrite(destino, lineas.join)
    true
  rescue StandardError => e
    NX.log("[ini] no se pudo escribir #{ruta(r)}: #{e.class}: #{e.message}")
    false
  end
end
NX.log("[nx] Win32API postizo definido (Game.ini de verdad; el resto, neutro y registrado)")

# ---------------------------------------------------------------------------
# 3. Los metodos que 1.8 tenia y 3.1 no
# ---------------------------------------------------------------------------
#
# Nada de esto se anade "por si acaso": cada uno se conto antes con un grep
# sobre los cinco corpus (Opalo 214 scripts, Iberia 168, Titan 167, Z 235,
# Uranium 260) y lo que salio a cero no esta aqui. Menos superficie, menos
# sorpresas. Todos van con `unless method_defined?`, porque los juegos definen
# algunos de estos nombres para sus propias clases y el suyo tiene que ganar,
# que es exactamente lo que pasaba en 1.8.

# Array#nitems — 7 usos en CADA uno de los cinco juegos, y el censo se equivoco
# al descartarlo. Es verdad que PokemonBox define `def nitems`, pero lo que ese
# metodo hace es `return @pokemon.nitems`, y @pokemon es un Array de 30 huecos
# con nil dentro: la llamada de verdad es Array#nitems, "cuantos no son nil".
# Sin esto, `full?` y `pbFirstFreePos` mueren con NoMethodError la primera vez
# que se abre el PC de Pokemon o se captura el septimo bicho.
class Array
  unless method_defined?(:nitems)
    def nitems
      count { |x| !x.nil? }
    end
  end
end

# Thread.critical — 12 usos en cada uno de los cinco juegos, en Audio.rb
# (Thread.exclusive) y en BitmapCache. Se retiro en 1.9 con los hilos nativos.
# El patron es siempre `_old = Thread.critical; Thread.critical = true; ...
# ensure Thread.critical = _old`, asi que hace falta el par lector/escritor o el
# `ensure` casca. No-op: en la Switch el juego corre en un hilo y no hay nada
# que excluir; mkxp-z ya serializa las llamadas al motor.
class Thread
  class << self
    unless respond_to?(:critical)
      def critical
        false
      end

      def critical=(valor)
        valor
      end
    end
  end
end

# Object#type — el alias de `class` que 1.8 traia y que 1.9 retiro. El grep no
# discrimina (121 `.type` en Opalo, 129 en Z... pero Anil, que corre sobre 3.1,
# tiene 90: en un juego de Pokemon `.type` mide la palabra "tipo"). Se define
# igualmente porque no cuesta nada y porque las clases que definen el suyo
# —PBMove#type, PokemonRules#type, el `type=` del clima— lo pisan, que es
# justo lo que ocurria en 1.8. Se registran las diez primeras llamadas CON EL
# LLAMANTE: si en el registro aparecen, ahi hay codigo de 1.8 de verdad; si no
# aparece ninguna, este metodo no ha hecho falta nunca y sobra.
class Object
  unless method_defined?(:type)
    # Una variable global y no una de clase: una @@ en Object la comparten
    # todas sus descendientes y Ruby 3.x lanza RuntimeError en cuanto una
    # subclase la toca ("class variable of Object is overtaken by ...").
    $nx_type_avisos = 0
    def type
      if $nx_type_avisos.to_i < 10
        $nx_type_avisos = $nx_type_avisos.to_i + 1
        NX.log("[1.8] Object#type sobre #{self.class} desde #{caller(1, 1).to_a.first}")
      end
      self.class
    end
  end
end

# Object#id — el object_id que 1.8 tenia con nombre corto y que 1.9 retiro. El
# censo lo descarto por no ser grepeable (689 `.id` en Anil, que corre, porque
# en un juego de Pokemon `.id` es `species.id`), y aparecio en ejecucion en el
# unico sitio donde no hay una clase del juego que lo tape: sobre nil.
#
# Medido en Pokemon Z al entrar en el primer mapa, dibujando las sombras de los
# eventos (Sombras.rb, linea 75):
#
#     @sprite.visible = !(@event.bush_depth>0 or !(@map.id==$game_map.id) or ...)
#     Section163:75:in `update': undefined method `id' for nil:NilClass
#
# `@map` llega nil, y en 1.8 `nil.id` valia 4 -el object_id de nil-, con lo que
# la comparacion fallaba, la sombra se quedaba invisible y nadie se enteraba.
# Definirlo devuelve ESE comportamiento, no otro. Las clases que definen su
# propio `id` lo pisan, igual que en 1.8.
class Object
  unless method_defined?(:id)
    $nx_id_avisos = 0
    def id
      if $nx_id_avisos.to_i < 10
        $nx_id_avisos = $nx_id_avisos.to_i + 1
        NX.log("[1.8] Object#id sobre #{self.class} desde #{caller(1, 1).to_a.first}")
      end
      object_id
    end
  end
end

# Kernel#proc — en 1.8 era `lambda`, y por eso `return` dentro valia.
#
# Medido en Titan el 9 de septiembre de 2026, en la transferencia al primer
# mapa jugable, y NO es un rincon: mata el juego entero al cambiar de mapa.
#
#     Section116:95:in `block in <main>': unexpected return (LocalJumpError)
#             from Section040:54:in `block in trigger'   (PBEvent#trigger)
#             from Section088:622:in `setMapChanged'
#             from Section019:230:in `transfer_player'
#
# La linea es `Events.onMapChange+=proc {|sender,e| return if !$PokemonGlobal ...`
# de PokemonRoaming.rb. En Ruby 1.8 `Kernel#proc` era un alias de `lambda`, o
# sea que el Proc que salia era de los que TIENEN marco propio y `return` sale
# de el; en 1.9 `proc` pasa a ser `Proc.new`, el `return` intenta salir del
# metodo que ya no existe -el bloque se escribio en el nivel superior- y
# LocalJumpError mata el hilo RGSS. Sin excepcion de Essentials, porque el
# `rescue` del cargador no cubre esto: la pantalla se queda negra a 0 FPS.
#
# Cuantos hay, contados sobre los cinco corpus con las llaves emparejadas y no
# con un grep de tres lineas: 74 en Opalo, 74 en Z, 72 en Iberia, 72 en Titan y
# 78 en Uranium, siempre en los mismos nueve o diez ficheros -los manejadores de
# objetos (`ItemHandlers::UseInField`), los MO de campo, el Pokemon errante, el
# Poke Radar, el Chatter, los Pokemon oscuros-. En Anil, que es v21.1 sobre Ruby
# 3.1, son CERO: la version moderna de Essentials ya los reescribio. O sea que
# esto es exactamente una diferencia de 1.8 y afecta a los cinco juegos de las
# dos familias viejas.
#
# COMO se arregla, y por que asi y no convirtiendo el bloque en lambda. Un
# bloque no se puede volver lambda en 3.1 sin pasar por `define_method`, y eso
# le cambia el `self` al bloque, que es justo lo que estos manejadores
# necesitan conservar. Lo que si se puede es envolverlo: por fuera un Proc
# normal que llama al de dentro y recoge el LocalJumpError que lanza su
# `return`, devolviendo `exit_value`, que es el valor que el juego queria
# devolver. Desde el que llama, el efecto es identico al de 1.8 y ademas se
# conserva la tolerancia de arity de los Proc, que es MAS permisiva que la del
# lambda de 1.8: no puede romper nada que antes funcionara.
#
# `arity` se repone a mano sobre el envoltorio porque hay codigo que lo mira
# para decidir como llamar -PBEvent#trigger hace `if callback.arity>2` para
# distinguir los manejadores de tres argumentos-, y un `|*args|` contesta -1.
module NX18Proc
  @cazados = 0

  def self.envuelve(bloque)
    envoltorio = Proc.new do |*args, &interno|
      begin
        bloque.call(*args, &interno)
      rescue LocalJumpError => e
        if @cazados < 5
          @cazados += 1
          # source_location del bloque, y no caller: el que llama es siempre
          # este envoltorio. El bloque se creo dentro de un eval del motor, o
          # sea que su source_location es "SeccionNNN:linea", que es
          # exactamente lo que hay que mirar en el registro.
          donde = bloque.source_location.to_a.join(":")
          NX.log("[1.8] `return` dentro de un proc de 1.8 en #{donde}")
        end
        e.exit_value
      end
    end
    envoltorio.define_singleton_method(:arity) { bloque.arity }
    envoltorio
  end
end

module Kernel
  def proc(&bloque)
    return NX18Proc.envuelve(bloque) if bloque
    raise ArgumentError, "tried to create Proc object without a block"
  end
  private :proc
end
NX.log("[1.8] Kernel#proc devuelve el proc de 1.8: `return` dentro sale del proc")

# Hash#index(valor): en 1.8, la clave de ese valor (en 3.x es Hash#key; index
# se retiro). El censo de abajo lo dio por no usado, y se le escapo: la pantalla
# de Controles de Iberia, Z y Titan hace `CONTROLSLIST.index(keyCode)` sobre un
# Hash constante, y abrirla desde el menu cerraba el juego:
#
#   Section134:187:in `getKeyName': undefined method `index' for {...}:Hash
#     from Section134:218:in `keyName' ... pbStartPokemonMenu
unless Hash.method_defined?(:index)
  class Hash
    def index(valor)
      key(valor)
    end
  end
  NX.log("[1.8] Hash#index = Hash#key")
end

# Audio.bgm_position: el Game.exe de estos juegos lo tenia; mkxp-z 2.4.2 lo
# llama bgm_pos (segundos, que es lo que el juego luego pasa a Audio.bgm_play).
# Game_System#bgm_pause hace `pos = Audio.bgm_position rescue 0` al entrar en
# cada combate (pbBattleAnimation): no se cerraba nada, pero la musica del
# mapa volvia a empezar desde el principio al acabar el combate.
if defined?(Audio) && Audio.respond_to?(:bgm_pos) && !Audio.respond_to?(:bgm_position)
  def Audio.bgm_position
    bgm_pos
  end
  def Audio.bgs_position
    bgs_pos
  end
  NX.log("[1.8] Audio.bgm_position/bgs_position = bgm_pos/bgs_pos")
end

# Lo que se busco y NO se encontro en ninguno de los cinco juegos, y por eso no
# esta definido: Array#indexes / Array#indices (0), Array#choice (0),
# Hash#indexes (0), Object#to_a (los 9 `.to_a` del corpus son
# Range#to_a y String#bytes.to_a, que 3.1 tiene), Kernel#getc (los 2 usos son
# metodos `getc` que los propios juegos definen en File_Mixins y SpriteWindow),
# String#each y String#to_a (0 usos localizables), Symbol#to_proc (ya existe).

# ---------------------------------------------------------------------------
# La entrada de texto de la familia v16: USEKEYBOARDTEXTENTRY
# ---------------------------------------------------------------------------
#
# runtime/lib/nx-teclado.rb desvia pbEnterText a la rejilla de caracteres
# mirando `$PokemonSystem.textinput`, y eso NO SIRVE en estos cinco juegos:
# `textinput` sale 0 veces en los cinco corpus. En Essentials clasico la
# eleccion es una constante que se fija al cargar el script 0001_Settings.rb:
#
#     USEKEYBOARDTEXTENTRY = true          # Opalo 0001_Settings.rb:358
#     if USEKEYBOARDTEXTENTRY              # 0054_TextEntry.rb:1601
#       sscene=PokemonEntryScene.new       # "escribe con el teclado y pulsa Enter"
#     else
#       sscene=PokemonEntryScene2.new      # la rejilla con cursor
#
# Con la constante a true el juego pide el nombre del entrenador por teclado, y
# en una consola sin teclado eso es un callejon sin salida silencioso: la
# partida no puede empezar y no sale ningun error.
#
# El arreglo tiene que ser tardio porque la constante no existe hasta que se
# carga el script del juego. Se engancha a Graphics.update, se cambia en cuanto
# aparece y se desengancha: el coste en regimen es un `defined?` por fotograma
# hasta la primera pantalla, y cero despues.
module NXTexto18
  @hecho = false
  class << self
    attr_accessor :hecho
  end

  def self.revisar
    return unless Object.const_defined?(:USEKEYBOARDTEXTENTRY)
    @hecho = true
    return unless Object.const_get(:USEKEYBOARDTEXTENTRY)
    silencio, $VERBOSE = $VERBOSE, nil     # "already initialized constant"
    Object.const_set(:USEKEYBOARDTEXTENTRY, false)
    $VERBOSE = silencio
    NX.log("[teclado] USEKEYBOARDTEXTENTRY = false: el nombre se escribe en la rejilla")
  rescue Exception => e
    @hecho = true
    NX.log("[teclado] FALLO al cambiar USEKEYBOARDTEXTENTRY: #{e.class}: #{e.message}")
  end
end

if defined?(Graphics) && Graphics.respond_to?(:update)
  module Graphics
    class << self
      alias_method :nx_update_sin_texto18, :update

      def update
        NXTexto18.revisar unless NXTexto18.hecho
        nx_update_sin_texto18
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Lo que habra que ir viendo en el registro
# ---------------------------------------------------------------------------
#
# Compilar no es correr, y esto es lo que un compilador no ve. No se puede
# emular globalmente porque cambiaria el significado del codigo bueno tambien;
# se deja escrito para que quien arranque el juego sepa que buscar en
# mkxp-ruby.log cuando algo salga raro.
#
#   String#[] con un entero. En 1.8 "abc"[0] daba 97 (el codigo del caracter);
#   en 3.1 da "a". Redefinirlo romperia todo el codigo que ya cuenta con la
#   semantica nueva. Sintoma: comparaciones de caracteres que nunca aciertan, y
#   `TypeError: no implicit conversion of String into Integer`. No es
#   grepeable: `[0]` sale por todas partes.
#
#   Array#to_s. En 1.8 [1,2].to_s daba "12"; en 3.1 da "[1, 2]". Sintoma:
#   corchetes y comas dentro de un texto de la pantalla. Tampoco es grepeable:
#   186 `.to_s` en Anil, que corre.
#
#   methods / instance_methods devolvian Strings y ahora devuelven Symbols. El
#   patron acotable es `.methods.include?("...")`, que sale CERO veces en los
#   cinco juegos, asi que este probablemente no aparezca.
#
#   Proc.new sin bloque (heredaba el bloque del metodo): 7 usos en cada juego,
#   pero hay que mirarlos uno a uno porque casi todos son `Proc.new {...}`, que
#   sigue siendo legal. En 3.1 el `Proc.new` sin bloque es ArgumentError, y sale
#   con nombre y linea en el registro, asi que se vera cuando pase.
#
#   Hash#index -> Hash#key. Cero usos localizados, pero un `.index(` sobre un
#   Hash daria NoMethodError con nombre y linea: facil de identificar.
#
#   RtlMoveMemory. 34 referencias en el corpus, todas partiendo de que
#   `objeto.__id__ * 2` es la direccion del objeto. Eso era cierto en el Ruby
#   1.8 de 32 bits y no lo es aqui. El postizo devuelve 0 y no toca memoria: el
#   bitmap que se iba a exportar sale en negro, el juego no se cae.
#
#   KleinBitmap.dll. Segun 0181_KleinBitmapFunctions.rb es una biblioteca de
#   efectos sobre Bitmap: save_pallete/modify_pallete (guardar y aplicar una
#   paleta .kpal), scroll_up/down/left/right (desplazar el contenido del bitmap,
#   que es como se animan las cascadas y el agua), to_retro (reducir a cuatro
#   colores), modify_color y add_outline. Todas llaman
#   `klein_dll(func, ...).call(self.__id__, ...)`, otra vez el puntero por
#   __id__. Con el postizo devuelven 0 y el bitmap sale SIN EL EFECTO: no falta
#   nada en pantalla, esta sin retocar. En Iberia y Titan hay ademas un
#   `Map - Klein.rb` que es el exportador de mapas de KleinStudio (Control+P
#   guarda el mapa entero a PNG); es una herramienta de desarrollo atada a un
#   atajo de teclado que en la consola no se puede pulsar, no el dibujado del
#   mapa. Quien pruebe Iberia debe mirar el agua y las cascadas, no el mapa.
NX.log("[nx] nx-ruby18.rb cargado: Array#nitems, Thread.critical, Object#type, Object#id, Kernel#proc")
# ---------------------------------------------------------------------------
# ENV["TEMP"]: en Horizon el entorno esta vacio
# ---------------------------------------------------------------------------
#
# Essentials clasico se va a la carpeta temporal para convertir los GIF a PNG,
# "since game might be on a CD-ROM":
#
#     Dir.chdir(ENV["TEMP"]){ ... GifLibrary::GifToPngFilesInMemory ... }
#
# En una consola no hay entorno que heredar, asi que ENV["TEMP"] es nil y eso
# sale como un TypeError en un sitio que no tiene nada que ver con los GIF.
# Medido en Pokemon Z al cargar el PRIMER MAPA, dentro de pbGetAutotile:
#
#   Section043:811:in `chdir': no implicit conversion of nil into String
#     ... BitmapWrapper#initialize -> pbGetAutotile -> Spriteset_Map
#
# Se apunta a la carpeta del juego, que es la unica que seguro existe y en la
# que seguro se puede escribir -ahi van las partidas-. Dentro de ese bloque no
# se escribe nada de todas formas: gif.dll no viaja a la tarjeta, asi que
# GifLibrary::PngDll es nil y el bloque no hace mas que entrar y salir.
%w[TEMP TMP TMPDIR].each do |var|
  next if ENV[var] && !ENV[var].to_s.empty?
  begin
    ENV[var] = NX::RAIZ
  rescue StandardError => e
    NX.log("[1.8] no se pudo poner ENV[#{var.inspect}]: #{e.class}")
  end
end
NX.log("[1.8] ENV[\"TEMP\"] = #{ENV["TEMP"].inspect} (Horizon no trae entorno)")


# ---------------------------------------------------------------------------
# 4. Lo que solo se puede arreglar CUANDO EL JUEGO YA HA DEFINIDO SUS CLASES
# ---------------------------------------------------------------------------
#
# El preload corre antes que el primer script del juego, asi que aqui todavia no
# existen ni StringInput ni el modulo Input reescrito. Y esperar a la primera
# Graphics.update -que es lo que hacen nx-teclado.rb y nx-rutas.rb- llega TARDE:
# el ultimo script de Opalo (Meson Batalla) construye Pokemon EN EL NIVEL
# SUPERIOR, o sea que necesita los arreglos mientras las secciones se estan
# cargando todavia.
#
# El unico sitio que corre entre seccion y seccion es NXFuente.transforma, y por
# eso el repaso se engancha ahi: cuesta un `const_defined?` por seccion -214 en
# Opalo- y no cuesta nada en regimen.
module NX18Tarde
  @hecho = {}
  @avisado = {}

  def self.revisar
    cadena_bytes                # antes que nada: de esto depende byte()
    stringinput unless @hecho[:stringinput]
    cadena_each unless @hecho[:cadena_each]
    datos unless @hecho[:datos]
    plano unless @hecho[:plano]
    tilemap unless @hecho[:tilemap]
    fuentes unless @hecho[:fuentes]
    audio unless @hecho[:audio]
    entrada                     # los juegos reabren Input en 4 o 5 secciones
    graficos
    pantalla                    # la pantalla logica, en cuanto el juego dice cual es
  rescue Exception => e
    NX.log("[1.8] FALLO del repaso tardio #{e.class}: #{e.message}")
    @hecho[:stringinput] = true
    @hecho[:cadena_each] = true
  end

  def self.aviso(clave, texto)
    return if @avisado[clave]
    @avisado[clave] = true
    NX.log(texto)
  end

  # --- StringInput#getc devolvia un BYTE ------------------------------------
  #
  # Esta es la semantica de 1.8 que de verdad aparecio, y no en un rincon: en el
  # camino por el que el juego lee TODOS sus datos.
  #
  #   class StringInput            (SpriteWindow, linea 1687)
  #     def getc
  #       ch = @string[@pos]       # 1.8: el codigo del caracter. 3.1: "A"
  #
  #   class StringInput            (File_Mixins, linea 149)
  #     def each_byte
  #       while !eof?; yield getc; end
  #
  #   def fgetb                    (File_Mixins, linea 2)
  #     each_byte {|i| ret = i || 0; break }
  #
  # o sea que `fgetb` -"leeme un byte"- devolvia una cadena de un caracter, y
  # eso sale por `Pokemon#growthrate`, que lee el byte 20 de dexdata.dat. Medido
  # en el emulador, con el juego muriendose antes de dibujar un pixel:
  #
  #   Section068:136:in `>=': comparison of String with 6 failed (ArgumentError)
  #     from Section068:136:in `pbGetStartExperience'
  #     from Section122:133:in `level='
  #     ... from Section211:41:in `<main>'
  #
  # Se arregla en getc y no en fgetb porque getc es donde esta el cambio de
  # significado: en 1.8 tanto IO#getc como este devolvian un Integer, y todo lo
  # que hay encima -fgetb, fgetw, fgetdw, fgetsb, pbGetFileChar- cuenta con eso.
  # Se envuelve el metodo del juego en vez de reescribirlo para no depender de
  # como se llamen sus variables de instancia.
  def self.stringinput
    return unless Object.const_defined?(:StringInput)
    clase = Object.const_get(:StringInput)
    return unless clase.method_defined?(:getc)
    @hecho[:stringinput] = true
    return if clase.method_defined?(:nx_each_byte_de_18)
    # Y SOLO each_byte, no getc, aunque en 1.8 los dos devolvieran un numero.
    #
    # La primera version tambien envolvia `getc`, que es lo que parecia mas
    # limpio -es ahi donde esta el `@string[@pos]` con la semantica vieja-, y
    # rompia el Marshal de Ruby 3.1: cuando el juego hace `Marshal.load(f)`
    # sobre un StringInput, marshal.c lee byte a byte con `getc` y espera una
    # cadena de un caracter. Con un Integer, la carga falla, y el juego la
    # rescata devolviendo el propio StringInput, que es lo que se veia:
    #
    #   Section100:119:in `block in gender': undefined method `[]' for
    #     #<StringInput:closed,src="[...POKEMONTRAINER_Chic">
    #     ... isMale? -> pbMessageDisplay   (Pokemon Z, primer dialogo)
    #
    # `each_byte` promete bytes por su nombre y no lo lee nadie mas que fgetb;
    # `getc` lo lee marshal. Se toca solo el primero.
    clase.class_eval do
      next unless method_defined?(:each_byte)
      alias_method :nx_each_byte_de_18, :each_byte
      define_method(:each_byte) do |&bloque|
        nx_each_byte_de_18 { |c| bloque.call(NX18Tarde.byte(c)) }
      end

      # Y UN getbyte, QUE ES LO QUE MARSHAL MIRA PARA ACEPTAR UN PUERTO.
      #
      # En 1.8, `Marshal.load(port)` se conformaba con que el objeto supiera
      # dar caracteres, y todo Essentials clasico lee sus .dat asi:
      #
      #     pbRgssOpen("Data/trainertypes.dat","rb"){|f|
      #        trainertypes = Marshal.load(f)      # f es un StringInput
      #
      # marshal.c de 3.1 acepta una cadena, o un objeto que responda a `read`
      # Y a `getbyte`; si no, `rb_io_check_io` y `TypeError: instance of IO
      # needed`. StringInput tiene `read` y no tiene `getbyte`, asi que caia
      # por el segundo camino... y el Marshal.load que el propio juego
      # redefine RESCATA la excepcion y devuelve el puerto, con lo que el
      # error sale mucho despues y sin relacion aparente:
      #
      #   Exception: NoMethodError
      #   Message: undefined method `[]' for #<StringInput:closed,
      #            src="[...POKEMONTRAINER_Chic">
      #   PSystem_Utilities NUEVO:547:in `block in pbGetTrainerTypeGender'
      #   ... pbTrainerName    (Pokemon Z, al confirmar el nombre)
      #
      # Un metodo de dos lineas devuelve a marshal el camino de pato que tenia
      # en 1.8. Se comprobo con `Marshal.oldload` sobre una copia del mismo
      # puerto: "TypeError: instance of IO needed".
      unless method_defined?(:getbyte)
        define_method(:getbyte) { NX18Tarde.byte(getc) }
      end
    end
    NX.log("[1.8] StringInput: each_byte entrega bytes y getbyte existe "            "(fgetb/dexdata, y Marshal.load acepta el puerto)")
  end

  # --- String#each ----------------------------------------------------------
  # Se retiro en 1.9 y el censo lo dio por no usado; lo usa StringInput#each,
  # que delega en `@string.each(&block)`. Cuesta tres lineas y evita un
  # NoMethodError en un sitio que no lo explicaria.
  def self.cadena_each
    @hecho[:cadena_each] = true
    return if String.method_defined?(:each)
    String.class_eval do
      def each(*a, &b)
        each_line(*a, &b)
      end
    end
    NX.log("[1.8] String#each = String#each_line")
  end

  # --- pbRgssOpen: los .dat del juego se leian ENTEROS una y otra vez -------
  #
  # `PokeBattle_Pokemon#initialize` hace, por cada Pokemon que se crea:
  #
  #     atkdata = pbRgssOpen("Data/attacksRS.dat", "rb")
  #     offset  = atkdata.getOffset(species-1)
  #     ...
  #     atkdata.close
  #
  # y con el contenedor puesto `pbRgssOpen` es `load_data(file)`, o sea LEER LOS
  # 63 KB ENTEROS para quedarse con veintiocho bytes. En un PC eso es una
  # lectura de disco cacheada por el sistema y nadie lo nota; aqui es abrir el
  # zip, buscar la entrada y copiarla, y ademas pasa por el Marshal.load
  # postizo del juego.
  #
  # Normalmente daria igual, porque se crean Pokemon de uno en uno. Pero Opalo
  # trae un script -"Meson Batalla"- que construye 679 Pokemon EN EL NIVEL
  # SUPERIOR, al cargar, para armar la plantilla de entrenadores del meson.
  # Medido en el emulador: a la creacion numero 155 el proceso entero muere sin
  # excepcion de Ruby y sin traza de invitado -el monton de Ruby estaba plano,
  # 121.000 ranuras y 299 paginas, o sea que lo que se agotaba no era Ruby-, y
  # muere en la misma creacion vuelta tras vuelta. Con la misma especie puesta
  # la SEGUNDA de la lista, se crea sin problema: no es el dato, es la cuenta.
  #
  # Los .dat de Data/ no cambian mientras el juego corre -se instalan con el
  # juego y nadie escribe en ellos-, asi que se memoriza el contenido y se
  # entrega un StringInput nuevo por llamada, que es lo unico que el juego
  # necesita (cada uno tiene su propia posicion). El limite de 8 MB deja fuera
  # cualquier cosa que no sea una tabla de datos.
  CACHE_DAT = {}
  TOPE_DAT = 8 * 1024 * 1024

  def self.datos
    return unless Object.private_method_defined?(:pbRgssOpen) ||
                  Object.method_defined?(:pbRgssOpen)
    return unless Object.const_defined?(:StringInput)
    @hecho[:datos] = true
    return if Object.private_method_defined?(:nx_pbRgssOpen_sin_cache)

    Object.class_eval do
      alias_method :nx_pbRgssOpen_sin_cache, :pbRgssOpen

      def pbRgssOpen(file, mode = nil, &bloque)
        # CON BLOQUE NO SE TOCA NADA, y esto costo dos arranques.
        #
        # El pbRgssOpen del juego no solo abre: alrededor del load_data pone
        # `Marshal.neverload = true` y lo vuelve a false en un ensure, y el
        # Marshal.load que el propio juego redefine mira ese indicador para
        # decidir si deserializa o devuelve la cadena en bruto. Saltarse ese
        # camino deja el indicador en un estado que el bloque del juego no
        # espera, y entonces `Marshal.load(f)` DEVUELVE EL PROPIO StringInput:
        #
        #   Exception: NoMethodError
        #   Message: undefined method `[]' for #<StringInput:closed,
        #            src="[...POKEMONTRAINER_Chic">
        #   PSystem_Utilities NUEVO:547:in `block in pbGetTrainerTypeGender'
        #   ... pbTrainerName   (Pokemon Z, al confirmar el nombre)
        #
        # Y no hace falta: lo que habia que arreglar era la forma SIN bloque,
        # que es la que usa PokeBattle_Pokemon#initialize para attacksRS.dat.
        return nx_pbRgssOpen_sin_cache(file, mode, &bloque) if bloque
        cad = NX18Tarde.dat(file, mode) { nx_pbRgssOpen_sin_cache(file, mode) }
        return nx_pbRgssOpen_sin_cache(file, mode) if cad.nil?
        StringInput.open(cad)
      end
      private :pbRgssOpen
    end
    NX.log("[1.8] pbRgssOpen memoriza los Data/*.dat (attacksRS se leia entero por Pokemon)")
  end

  # Devuelve el contenido memorizado, o nil si este fichero no es de los que se
  # memorizan y hay que dejar pasar la llamada original.
  def self.dat(file, mode)
    nombre = file.to_s
    return nil unless nombre =~ %r{\AData[/\\][^/\\]+\.dat\z}i
    return nil unless mode.nil? || mode.to_s.start_with?("r")
    clave = nombre.tr("\\", "/").downcase
    return CACHE_DAT[clave] if CACHE_DAT.key?(clave)
    f = yield
    return (CACHE_DAT[clave] = nil) unless f.respond_to?(:read)
    cad = f.read
    f.close rescue nil
    cad = nil if cad.nil? || cad.bytesize > TOPE_DAT
    CACHE_DAT[clave] = cad
  rescue StandardError => e
    NX.log("[1.8] no se pudo memorizar #{file}: #{e.class}: #{e.message}")
    nil
  end

  # --- String#[] con un entero: por que NO se emula, medido -----------------
  #
  # En 1.8 `"abc"[0]` valia 97 y desde 1.9 vale "a". Se probo a emularlo
  # acotandolo a lo unico que parecia seguro -devolver el byte solo si la cadena
  # es ASCII-8BIT, o sea si viene de leer un fichero en binario, y dejar el `[]`
  # de 3.1 para el texto UTF-8-. Arreglaba lo que tenia que arreglar: el lector
  # de cabeceras Ogg de Essentials clasico (`file.read(1)[0]` seguido de
  # `.times`) dejaba de matar la pantalla de titulo de Pokemon Z.
  #
  # Y ROMPIA `$~`, que es peor. Cualquier envoltorio de `[]` escrito en Ruby
  # tiene su propio marco, y el `$~` que deja una expresion regular se guarda EN
  # EL MARCO DEL QUE LLAMA. Con `[]` nativo, `text[REGEXP]` deja el resultado a
  # mano de quien escribio la linea; con un `[]` de Ruby por medio, el resultado
  # se queda en el marco del envoltorio y desaparece al volver. No hay forma de
  # arreglarlo desde Ruby: `$~ = m` dentro del envoltorio tampoco sale de ahi.
  #
  # Medido en Pokemon Z, en el primer cuadro de dialogo de la introduccion, que
  # es por donde pasa TODO el texto del juego:
  #
  #     while text[FORMATREGEXP]
  #       textchunks.push($~.pre_match)     # DrawText.rb:498
  #     Section044:498:in `getFormattedText': undefined method `pre_match'
  #                                            for nil:NilClass
  #
  # Asi que se queda como estaba escrito arriba: no se emula globalmente. Lo que
  # de verdad hacia falta se arregla en su sitio -StringInput#getc y #each_byte
  # para los datos, y los dos lectores de audio de aqui abajo-.

  # --- String#getbyte, que el juego convierte en String#[] ------------------
  #
  # `Map - Klein.rb` -Opalo 195, Z 161, Iberia 161- trae estas tres lineas:
  #
  #     class String
  #       alias getbyte  []
  #       alias setbyte  []=
  #       alias bytesize size
  #
  # En Ruby 1.8 eso era ANADIR: `getbyte` no existia y `"abc"[0]` valia 97, o
  # sea el byte. En 3.1 los tres metodos existen ya y hacen lo correcto, asi
  # que el alias los DESTRUYE: a partir de esa seccion `"\x03".getbyte(0)`
  # devuelve `"\x03"` en vez de 3, y `bytesize` cuenta caracteres en vez de
  # bytes. No es un detalle de ese script: es la API de bytes de Ruby entera,
  # rota para todo lo que se cargue despues -Zlib, Marshal, el postizo de
  # Win32API que rellena buferes, y este mismo fichero-.
  #
  # Costo cinco arranques encontrarlo, y la pista fue que el mismo `fgetb`
  # daba 65 en la seccion 69 y "A" en la 211. Se guardan los tres metodos de
  # verdad al cargar el preload y se reponen en cuanto alguien los pisa.
  #
  # Lo que se pierde: el exportador de mapas a PNG de KleinStudio (Control+P),
  # que es una herramienta de escritorio atada a un atajo de teclado que en un
  # mando no se puede pulsar.
  ORIGINALES_STRING = {}
  [:getbyte, :setbyte, :bytesize].each do |m|
    begin
      ORIGINALES_STRING[m] = String.instance_method(m)
    rescue NameError
    end
  end

  # El unico sitio de este fichero que convierte caracter a byte. Usa el metodo
  # guardado y no `c.getbyte`, porque entre que el juego pisa el alias y el
  # repaso lo repone hay una seccion entera de margen.
  def self.byte(c)
    return c unless c.is_a?(String)
    return nil if c.empty?
    m = ORIGINALES_STRING[:getbyte]
    m ? m.bind(c).call(0) : c.unpack1("C")
  end

  def self.cadena_bytes
    return if ORIGINALES_STRING.empty?
    return if "A".getbyte(0) == 65 && "A".bytesize == 1
    ORIGINALES_STRING.each do |nombre, metodo|
      String.send(:define_method, nombre, metodo)
    end
    aviso(:cadena_bytes,
          "[1.8] String#getbyte/setbyte/bytesize repuestos " \
          "(el juego los habia aliasado a []/[]=/size, que en 1.8 daban bytes)")
  end

  # --- Graphics.snap_to_bitmap ----------------------------------------------
  #
  # Los cuatro juegos lo reescriben, y de dos maneras distintas: Klein lo hace
  # con BitBlt y GetDIBits de gdi32 sobre la ventana de Windows, y
  # PSystem_System/PokemonSystem lo dejan en `return nil`. Con el Win32API
  # postizo lo primero devuelve un bitmap en negro y lo segundo un nil, y por
  # ahi pasan las transiciones y los fundidos de Essentials: pantallas negras o
  # un NoMethodError sobre nil en mitad de un menu.
  #
  # El motor tiene el suyo, que funciona. Se repone igual que Input.
  def self.graficos
    return unless NATIVO_GFX[:snap_to_bitmap]
    return unless defined?(Graphics)
    return if Graphics.method(:snap_to_bitmap) == NATIVO_GFX[:snap_to_bitmap]
    Graphics.singleton_class.send(:define_method, :snap_to_bitmap,
                                  NATIVO_GFX[:snap_to_bitmap].unbind)
    aviso(:graficos, "[1.8] Graphics.snap_to_bitmap vuelve a ser el del motor")
  end

  # --- La pantalla logica se quedaba en 640x480 -----------------------------
  #
  # Randy, con Opalo en su Switch y con Z en el emulador: "no esta nada centrado
  # el viewport, se ve super curseado". Medido sobre la captura de Z en Ryujinx
  # (docs/capturas/pokemon-z-viewport-antes-titulo.png): el juego ocupa 960x720
  # de los 1200x895 que el emulador dedica a la consola, pegado a la esquina de
  # arriba a la izquierda. 960/1200 = 720/895 = 0,8 justo, que es 512/640 y
  # 384/480: la pantalla logica del motor era 640x480 y Essentials dibujaba sus
  # 512x384 en un rincon de ella. El motor la centra y la escala bien -eso lo
  # hace fixedAspectRatio-, pero centra los 640x480, no los 512x384.
  #
  # Por que 640x480: es el valor por omision de mkxp-z para RGSS1
  # (src/config.cpp: `conf.defScreenW = (rgssVersion == 1 ? 640 : 544)`), y los
  # mkxp.json de estos cinco juegos NO traen defScreenW/defScreenH -Anil y
  # Vanguard si, y por eso Anil siempre se vio centrado-.
  #
  # Y por que el juego no lo arregla solo, que es lo que hace en el PC:
  # Essentials clasico trae `pbSetResizeFactor` en Sprite_Resizer, que acaba
  # llamando a `Graphics.resize_screen`; pero doce secciones mas adelante,
  # PSystem_System hace
  #
  #     if !Kernel.respond_to?("pbSetResizeFactor")
  #       def pbSetResizeFactor(dummy); end
  #
  # y `Kernel.respond_to?` sobre un metodo de nivel superior -que es privado en
  # Object- contesta false, asi que el sello vacio PISA al de verdad. Medido con
  # una sonda en el emulador (runtime/diagnostico/nx-sonda-viewport.rb):
  #
  #     [viewport] update 1: motor 640x480 | juego 512x384 | haveresizescreen true
  #     [viewport] arity de pbSetResizeFactor = 1   (el de Sprite_Resizer es -1)
  #
  # o sea: el juego SABE que puede redimensionar y no lo pide nunca. Y con la
  # sonda pidiendolo a mano, 512x384, la imagen sale centrada y llenando la
  # pantalla (pokemon-z-viewport-despues-titulo.png). No es de la consola: en el PC
  # pasa lo mismo, solo que alli la ventana es de 640x480 y el hueco negro se
  # confunde con el marco.
  #
  # El arreglo es pedirlo nosotros, y no fijar 512x384 en mkxp.base.json: ahi
  # valdria para estos cinco y romperia cualquier juego de RPG Maker XP que
  # dibuje de verdad a 640x480. Aqui se pregunta al juego -su Graphics.width es
  # su DEFAULTSCREENWIDTH- y se le da esa pantalla, sea cual sea. Si el juego no
  # reescribe Graphics.width, los dos numeros coinciden y esto no hace nada.
  #
  # Corre entre seccion y seccion (NXFuente.transforma), o sea en cuanto
  # Sprite_Resizer se ha evaluado y mucho antes del primer fotograma.
  def self.pantalla
    return unless NATIVO_GFX[:width] && NATIVO_GFX[:height]
    return unless NATIVO_GFX[:resize_screen]
    return unless defined?(Graphics)
    w = (Graphics.width  rescue nil)
    h = (Graphics.height rescue nil)
    return unless w.is_a?(Numeric) && h.is_a?(Numeric)
    w = w.to_i
    h = h.to_i
    # Un tamano absurdo seria peor que el que ya hay: el juego acaba de definir
    # la constante y podria estar a medias.
    return if w < 64 || h < 64 || w > 4096 || h > 4096
    real_w = NATIVO_GFX[:width].call
    real_h = NATIVO_GFX[:height].call
    return if w == real_w && h == real_h
    NATIVO_GFX[:resize_screen].call(w, h)
    NX.log("[1.8] pantalla logica #{real_w}x#{real_h} -> "            "#{NATIVO_GFX[:width].call}x#{NATIVO_GFX[:height].call}: "            "Essentials dibuja #{w}x#{h} y su pbSetResizeFactor lo pisa un "            "`def pbSetResizeFactor(dummy); end`, asi que nunca lo pide")
  rescue Exception => e
    NX.log("[1.8] no se pudo ajustar la pantalla logica: #{e.class}: #{e.message}")
  end

  NATIVO_GFX = {}

  def self.guarda_graficos
    return unless defined?(Graphics)
    begin
      NATIVO_GFX[:snap_to_bitmap] = Graphics.method(:snap_to_bitmap)
    rescue NameError
    end
    # width, height y resize_screen del MOTOR, guardados antes de que
    # Sprite_Resizer los tape con los suyos. Sin esto no hay forma de
    # preguntarle a mkxp-z de que tamano es su pantalla de verdad: a partir de
    # la seccion 25-35 `Graphics.width` es el 512 nominal del juego. Ver
    # NX18Tarde.pantalla.
    [:width, :height, :resize_screen].each do |nombre|
      begin
        NATIVO_GFX[nombre] = Graphics.method(nombre)
      rescue NameError
      end
    end
  end

  # --- Los dos lectores de Ogg de Essentials clasico ------------------------
  #
  # `getPlayTime(fichero)` mide cuanto dura una musica, y de eso depende la
  # pantalla de titulo animada (`@totalFrames = getPlayTime(str).to_i *
  # Graphics.frame_rate`, siete veces en el Titulo.rb de Z) y el grito de los
  # Pokemon. Por dentro son dos metodos que leen la cabecera Ogg byte a byte con
  # la semantica de 1.8:
  #
  #     hdrbodysize = (file.read(1)[0] rescue 0)
  #     hdrbodysize.times do ... end          # AudioUtilities.rb:1019
  #
  # que en 3.1 es una cadena de un caracter y no un numero:
  #
  #     Section040:1020:in `getOggPage': undefined method `times' for "\x01":String
  #       ... oggfiletime -> getPlayTime2 -> getPlayTime -> Titulo#initialize
  #
  # Se sustituyen los dos por la misma cuenta con `getbyte`. No es un apano: es
  # el mismo algoritmo -misma cabecera, mismos campos, mismo resultado-, escrito
  # con el metodo que en 3.1 significa lo que `[0]` significaba en 1.8. Van
  # juntos porque `oggfiletime` vuelve a leer bytes sueltos para el tipo de
  # paquete y los canales, y con la semantica nueva daba -1 ("no se sabe") en
  # silencio, que es una pantalla de titulo con la animacion descuadrada.
  def self.audio
    return unless Object.private_method_defined?(:getOggPage) ||
                  Object.method_defined?(:getOggPage)
    @hecho[:audio] = true
    return if Object.private_method_defined?(:nx_getOggPage_de_18)

    Object.class_eval do
      alias_method :nx_getOggPage_de_18, :getOggPage

      def getOggPage(file)
        return nil if file.eof?
        dw = file.read(4).to_s.unpack("V")[0] || 0
        return nil if dw != 0x5367674F
        header = file.read(22)
        cuantos = NX18Tarde.byte(file.read(1)) || 0
        bodysize = 0
        cuantos.times { bodysize += (NX18Tarde.byte(file.read(1)) || 0) }
        [header, file.pos, bodysize, file.pos + bodysize]
      rescue StandardError
        nil
      end
      private :getOggPage

      alias_method :nx_oggfiletime_de_18, :oggfiletime

      def oggfiletime(file)
        paginas = []
        while (pagina = getOggPage(file))
          paginas.push(pagina)
          file.pos = pagina[3]
        end
        return -1 if paginas.length == 0
        serie = nil
        i = -1
        pcm = []
        ritmos = []
        paginas.each do |pagina|
          cabecera = pagina[0].to_s
          serial = cabecera[10, 4].to_s.unpack("V")
          marco = cabecera[2, 8].to_s.unpack("C*")
          n = 0
          7.downto(0) { |k| n = (n << 8) | (marco[k] || 0) }
          if serial != serie
            serie = serial
            file.pos = pagina[1]
            tipo = NX18Tarde.byte(file.read(1)) || 0
            return -1 if file.read(6) != "vorbis"
            return -1 if tipo != 1
            i += 1
            return -1 if (file.read(4).to_s.unpack("V")[0] || 0) != 0
            file.read(1)                       # canales, no se usa
            ritmos[i] = file.read(4).to_s.unpack("V")[0] || 0
          end
          pcm[i] = n if i >= 0
        end
        total = 0.0
        pcm.each_index do |k|
          r = ritmos[k]
          total += pcm[k] * 1.0 / r if r && r > 0 && pcm[k]
        end
        total
      rescue StandardError
        -1
      end
      private :oggfiletime
    end
    NX.log("[1.8] getOggPage y oggfiletime leen bytes con getbyte (duraban 0 y mataban el titulo)")
  end

  # --- LargePlane: una clase que hereda de Plane y nunca llama a super ------
  #
  # `SpriteWindow.rb` -linea 4345 en Opalo y Z, 4726 en Iberia y Titan- define
  #
  #     class LargePlane < Plane
  #       def initialize(viewport=nil)
  #         @__sprite = Sprite.new(viewport)      # y nada de super
  #
  # o sea que el Plane nativo NUNCA se construye: la clase dice que es un Plane
  # y por dentro dibuja con un Sprite propio. Todo lo que LargePlane
  # reimplementa en Ruby funciona; lo unico que se le escapa al llegar a la
  # clase de arriba es `dispose`, que si hace `super`. Medido en Pokemon Z al
  # cerrar la pantalla de titulo para empezar la partida:
  #
  #   Section043:4373:in `dispose': No instance data for variable
  #                                 (missing call to super?) (MKXPError)
  #     ... AnimatedPlane#dispose -> pbDisposeSpriteHash -> disposeTitle
  #
  # Se arregla por donde lo dice el propio mensaje: se construye el Plane que
  # falta. Queda un Plane de verdad sin bitmap -invisible, porque el dibujo lo
  # hace el Sprite interno-, y `dispose` encuentra sus datos y lo libera. La
  # alternativa era quitarle el `super` al dispose del juego, que dejaria ese
  # Plane sin liberar en cada cambio de pantalla.
  def self.plano
    return unless Object.const_defined?(:LargePlane)
    clase = Object.const_get(:LargePlane)
    return unless clase.method_defined?(:dispose)
    @hecho[:plano] = true
    return if clase.private_method_defined?(:nx_initialize_sin_plane)
    clase.class_eval do
      alias_method :nx_initialize_sin_plane, :initialize
      def initialize(viewport = nil)
        viewport ? super(viewport) : super()
        nx_initialize_sin_plane(viewport)
      end
    end
    NX.log("[1.8] LargePlane construye el Plane nativo que su initialize se saltaba")
  end

  # --- CustomTilemap con un tileset mas alto de lo que admite la GPU --------
  #
  # Los tilesets de exteriores de Iberia miden 256x40026. La GPU de la Switch
  # no admite texturas de mas de 16384 de lado, y mkxp-z guarda un Bitmap asi
  # en RAM como "mega surface": el Tilemap del motor sabe dibujarlo, pero un
  # Sprite no lo acepta. Y el Tilemap que usan estos juegos no es el del motor:
  # Iberia pone `MAPVIEWMODE = 1` en su seccion de ajustes, y con eso
  # TilemapLoader elige CustomTilemap, el de Ruby, que pinta cada tile con
  # `sprite.bitmap = @tileset` y un src_rect. Medido al salir de la casa (mapa
  # 16) al pueblo (mapa 2) con la partida de un jugador:
  #
  #   Section036:371:in `bitmap=': Operation not supported for mega surfaces
  #     from Section036:371:in `getRegularTile'
  #     ... Spriteset_Map#initialize <- Scene_Map#transfer_player
  #
  # En el PC no pasa porque el RGSS de Enterbrain pinta por software. La casa
  # si funciona porque su tileset (Interior.png, 256x15123) cabe.
  #
  # Se arregla dandole al sprite un Bitmap del tamano de un tile, recortado del
  # tileset (NX18Tarde.trozo). Con un tileset que cabe, o con tiles que hay que
  # estirar (@diffsizes, que ya recorta por su cuenta), se sigue por el camino
  # del juego.
  def self.tilemap
    return unless Object.const_defined?(:CustomTilemap)
    clase = Object.const_get(:CustomTilemap)
    return unless clase.method_defined?(:getRegularTile)
    @hecho[:tilemap] = true
    return if clase.method_defined?(:nx_getRegularTile_entero)
    clase.class_eval do
      alias_method :nx_getRegularTile_entero, :getRegularTile
      def getRegularTile(sprite, id)
        if @diffsizes || !@tileset || !@tileset.mega?
          return nx_getRegularTile_entero(sprite, id)
        end
        bitmap = NX18Tarde.trozo(@tileset, ((id - 384) & 7) * @tileSrcWidth,
                                 ((id - 384) >> 3) * @tileSrcHeight, @tileSrcWidth, @tileSrcHeight)
        sprite.bitmap = bitmap if sprite.bitmap != bitmap
      end
    end
    NX.log("[1.8] CustomTilemap recorta los tiles de un tileset mega en vez de pasarlo entero a un Sprite")
  end

  # --- FontInstaller: instalar fuentes en Windows ---------------------------
  #
  # La pantalla de carga de Essentials clasico (PokemonLoad.rb en Iberia y
  # Titan, PScreen_Load.rb en Opalo y Z, PSystem_System en Uranium) empieza
  # con `FontInstaller.install`, que busca las fuentes del juego en la carpeta
  # de fuentes de Windows (registro, %SystemRoot%\Fonts) y, si no estan, las
  # copia alli y llama a AddFontResource. En la Switch no hay esa carpeta, asi
  # que en Iberia salian tres avisos en ingles en cada arranque, entre el
  # titulo y la pantalla de carga ("One or more fonts used in this game do not
  # exist on the system", "The game can be played...", "To install the
  # necessary fonts, copy the files...").
  #
  # No hay nada que instalar: mkxp-z carga las fuentes de Fonts/ del juego al
  # arrancar, y el texto ya sale con ellas. Se deja install sin efecto y se
  # apunta cuales de las que pide el juego no ve el motor, que es lo unico que
  # podria faltar de verdad.
  def self.fuentes
    return unless Object.const_defined?(:FontInstaller)
    m = Object.const_get(:FontInstaller)
    return unless m.respond_to?(:install)
    @hecho[:fuentes] = true
    nombres = (m.const_get(:Names) rescue nil) || []
    faltan = nombres.reject { |n| (Font.exist?(n) rescue true) }
    m.define_singleton_method(:install) { nil }
    NX.log("[1.8] FontInstaller.install sin efecto (instala en Windows); " +
           (faltan.empty? ? "el motor ve las #{nombres.size} fuentes del juego" :
                            "el motor NO ve: #{faltan.join(', ')}"))
  end

  # --- blt desde una mega surface pisa en vez de mezclar --------------------
  #
  # Lo segundo que salio en el mismo pueblo, ya sin el error: rectangulos
  # negros alrededor de la casa. CustomTilemap compone los tiles de prioridad 0
  # de las tres capas en un solo Bitmap con `blt`, el suelo primero y la casa
  # encima. Pero las dos ramas de Bitmap::stretchBlt para un origen mega (la de
  # subImageFix y la de SDL_BlitSurface con BLENDMODE_NONE) COPIAN los pixeles
  # en vez de mezclarlos -mkxp-z lo dice: "Don't do transparent blits for now"-,
  # asi que lo transparente de los tiles de la casa borraba el suelo de debajo.
  #
  # Se recorta primero el trozo pedido a un Bitmap normal -sobre uno recien
  # creado, copiar es lo correcto- y el blt de verdad se hace desde ahi, por el
  # camino que si mezcla. Los trozos se guardan en el propio Bitmap mega, que
  # en estos juegos es el tileset que RPG::Cache ya tiene vivo: el mismo tile
  # se recorta una sola vez. Un blt desde un Bitmap normal no se entera de
  # nada mas que de una llamada a mega?.
  BLT_NATIVO = defined?(::Bitmap) ? ::Bitmap.instance_method(:blt) : nil

  def self.trozo(src, x, y, w, h)
    cache = src.instance_variable_get(:@nx_trozos) || src.instance_variable_set(:@nx_trozos, {})
    clave = (((y << 16) | x) << 24) | (w << 12) | h
    b = cache[clave]
    return b if b && !b.disposed?
    b = ::Bitmap.new(w, h)
    BLT_NATIVO.bind(b).call(0, 0, src, Rect.new(x, y, w, h))
    cache[clave] = b
  end

  module BltMega
    def blt(x, y, src, rect, opacity = 255)
      return super unless src.mega?
      t = NX18Tarde.trozo(src, rect.x, rect.y, rect.width, rect.height)
      super(x, y, t, t.rect, opacity)
    end

    def stretch_blt(dest, src, rect, opacity = 255)
      return super unless src.mega?
      t = NX18Tarde.trozo(src, rect.x, rect.y, rect.width, rect.height)
      super(dest, t, t.rect, opacity)
    end
  end

  def self.blt_mega
    return unless BLT_NATIVO && ::Bitmap.method_defined?(:mega?)
    ::Bitmap.prepend(BltMega) unless ::Bitmap.ancestors.include?(BltMega)
  end

  # --- El modulo Input, que estos cuatro juegos REESCRIBEN ENTERO -----------
  #
  # Y esto es lo que habria dejado el juego mudo con la pantalla de titulo
  # puesta. PSystem_Controls (Opalo 169, Z 151, Iberia y Titan 134) hace
  # `module Input` y vuelve a definir update, press?, trigger?, repeat?,
  # release?, count, dir4 y dir8 EN RUBY, leyendo el teclado de Windows:
  #
  #     @GetKeyState = Win32API.new("user32", "GetAsyncKeyState", "i", "i")
  #     def self.getstate(key)
  #       return (@GetKeyState.call(key)&0x8000)>0
  #
  # Con el Win32API postizo eso contesta 0 siempre, o sea que NINGUN boton se
  # pulsa nunca: el juego arranca, dibuja y no responde. Y no es un script raro
  # de un juego raro: los cuatro lo traen, y encima lo reabren tres o cuatro
  # secciones mas (el KGC de la captura de pantalla, la pantalla de "configura
  # los controles", la tarjeta de entrenador, el turbo).
  #
  # Se devuelven los metodos del motor, que son los que leen el mando de la
  # consola y los que ya funcionan en Anil, Vanguard y Reborn. Se guardan al
  # cargar este fichero -cuando todavia son los del motor- y se reponen entre
  # seccion y seccion, porque cada reapertura los vuelve a pisar.
  #
  # LO QUE SE PIERDE, dicho para que nadie lo busque: la pantalla de "configura
  # los controles" queda decorativa (no hay teclado que remapear), el turbo con
  # ALT y las teclas de depuracion (F7, F8, K) no se pueden pulsar en un mando,
  # y la tarjeta de entrenador de Opalo, que se hojea con Q W E R T Y U I, se
  # queda sin esas paginas.
  NATIVO = {}

  def self.guarda_nativos
    return unless defined?(Input)
    [:update, :press?, :trigger?, :repeat?, :release?, :count, :dir4, :dir8,
     :pressex?, :triggerex?, :repeatex?, :releaseex?, :repeatcount].each do |m|
      begin
        NATIVO[m] = Input.method(m)
      rescue NameError
        # Un motor sin ese metodo: no es motivo para parar nada.
      end
    end
  end

  # Los que se reponen tal cual y los que hay que traducir.
  DIRECTOS = [:update, :press?, :trigger?, :repeat?, :release?, :count, :dir4, :dir8]

  # La traduccion de codigo de tecla de Windows a boton de RGSS. Sale de las
  # tablas `buttonToKey` de los propios juegos (Opalo 0169 y 0191, Z 0151,
  # Iberia y Titan 0134), leidas al reves. Hace falta porque los juegos llaman
  # a triggerex?/pressex? CON CODIGOS DE WINDOWS -Input.any? de Z recorre
  # 0x30..0x5A- y los del motor esperan codigos de tecla de SDL.
  VK = {
    0x25 => 4,  0x26 => 8,  0x27 => 6,  0x28 => 2,       # flechas
    0x5A => 11, 0x10 => 11,                              # Z, Shift -> A
    0x58 => 12, 0x1B => 12,                              # X, Esc   -> B
    0x43 => 13, 0x0D => 13, 0x20 => 13,                  # C, Enter, Espacio -> C
    0x41 => 14,                                          # A -> X
    0x53 => 15,                                          # S -> Y
    0x44 => 16,                                          # D -> Z
    0x51 => 17, 0x21 => 17,                              # Q, RePag -> L
    0x57 => 18, 0x22 => 18,                              # W, AvPag -> R
    0x11 => 22, 0x12 => 23,                              # Ctrl, Alt
    0x74 => 25, 0x75 => 26, 0x76 => 27, 0x77 => 28, 0x78 => 29
  }

  def self.entrada
    return if NATIVO.empty?
    return unless defined?(Input)
    return if Input.method(:press?) == NATIVO[:press?]

    NATIVO.each do |nombre, metodo|
      next unless DIRECTOS.include?(nombre)
      Input.singleton_class.send(:define_method, nombre, metodo.unbind)
    end

    # Los *ex? del juego reciben codigos de Windows. Se traducen; lo que no
    # este en la tabla -las letras sueltas de Input.any?- contesta que no,
    # que es lo que ya contestaba el postizo mudo.
    Input.singleton_class.send(:define_method, :pressex?) do |k|
      b = NX18Tarde::VK[k]; b ? Input.press?(b) : false
    end
    Input.singleton_class.send(:define_method, :triggerex?) do |k|
      b = NX18Tarde::VK[k]; b ? Input.trigger?(b) : false
    end
    Input.singleton_class.send(:define_method, :repeatex?) do |k|
      b = NX18Tarde::VK[k]; b ? Input.repeat?(b) : false
    end
    Input.singleton_class.send(:define_method, :releaseex?) do |k|
      b = NX18Tarde::VK[k]; b ? Input.release?(b) : false
    end
    Input.singleton_class.send(:define_method, :repeatcount) do |k|
      b = NX18Tarde::VK[k]; b ? Input.count(b) : 0
    end

    aviso(:entrada, "[1.8] Input vuelve a ser el del motor " \
                    "(el juego lo habia reescrito sobre Win32API/GetAsyncKeyState)")
  end
end
NX18Tarde.guarda_nativos
NX18Tarde.guarda_graficos
NX18Tarde.blt_mega

