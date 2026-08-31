# Compatibilidad para la version de Nintendo Switch.
#
# Se ejecuta ANTES que preload.rb (ver "preloadScript" en mkxp.json) porque
# preload.rb, que viene con el juego, llama a MKXP.puts en su tercera linea.
#
# MKXP es la API de JoiPlay, no la de mkxp-z: el juego se distribuye tambien
# para Android y sus scripts la usan en dos sitios. En mkxp-z el equivalente es
# el modulo System, y la constante MKXP sencillamente no existe, asi que sin
# esto el interprete se para en la primera linea de preload.rb.

module NX
  # Fichero PROPIO, distinto del que usa el lado C++. Compartirlo no sale
  # bien: el descriptor de Ruby se queda con su desplazamiento en cache y
  # pisa lo que el C++ acaba de anadir, de modo que se pierden justo las
  # lineas de error que uno quiere leer.
  LOG = "mkxp-ruby.log"

  def self.log(msg)
    $nx_log ||= begin
      f = (File.open(LOG, "a") rescue File.open("sdmc:/switch/pokemon-anil/" + LOG, "a"))
      f.sync = true
      f
    end
    $nx_log.write(msg.to_s + "\n")
    # sync = true solo quita el bufer de Ruby. Debajo hay otro: Horizon no
    # escribe en la SD hasta que alguien se lo pide, y este fichero no se
    # cierra nunca porque el proceso muere de golpe. Resultado: las ULTIMAS
    # lineas —justo las que uno quiere leer— se quedaban en el aire. fsync
    # baja hasta fsFileFlush y las asienta. Cuesta una IPC por linea, y este
    # canal se usa con cuentagotas.
    $nx_log.fsync
    nil
  rescue StandardError
    nil   # Nunca dejar que un fallo de registro tumbe el juego.
  end
end

# El unico canal de diagnostico de Horizon es el fichero: la salida estandar no
# va a ninguna parte. Redirigir $stdout hace visible todo el `puts` del juego.
#
# Ruby comprueba que el objeto responda a `write` EN EL MOMENTO de la asignacion
# ("$stdout must have write method, Object given"), asi que la clase tiene que
# estar completa antes de asignarla; no vale crear el objeto y anadirle metodos.
class NXOut
  def write(*a);  a.each { |x| NX.log(x.to_s.chomp) }; a.sum { |x| x.to_s.size } end
  def <<(x);      NX.log(x.to_s.chomp); self end
  def puts(*a);   a.empty? ? NX.log("") : a.flatten.each { |x| NX.log(x) }; nil end
  def print(*a);  a.each { |x| NX.log(x.to_s.chomp) }; nil end
  def printf(*a); NX.log(format(*a)); nil end
  def flush;      self end
  def sync;       true end
  def sync=(v);   v end
  def fileno;     1 end
  def tty?;       false end
  def close;      nil end
end
$stdout = NXOut.new
$stderr = $stdout

module MKXP
  # preload.rb la usa para avisar de metodos retirados en Ruby 3.2. Nuestro
  # interprete es el 3.1.7, donde Dir.exists?/File.exists? siguen existiendo,
  # asi que el aviso es informativo y basta con registrarlo.
  def self.puts(msg)
    NX.log("[MKXP] #{msg}")
  end

  # JoiPlay abre un navegador. En Horizon no hay ninguno al que delegar; los
  # dos sitios que la llaman ya la envuelven en `rescue`, pero devolver false
  # es mas limpio que dejar que estalle.
  def self.launch(url)
    NX.log("[MKXP] launch ignorado en Switch: #{url}")
    false
  end
end

# --- constantes de Encoding -----------------------------------------------
# Nuestro Ruby se enlazo con dmyenc.o (el Init_enc vacio) en lugar de la base
# de datos de codificaciones, asi que registra las integradas -- UTF-8 incluida,
# que funciona: Encoding.find("UTF-8") devuelve el objeto correcto -- pero NO
# crea sus constantes, porque quien las define es rb_encdb_declare desde
# enc/encdb.o. Resultado: Encoding.constants solo tiene las cinco clases de
# error y el script MKXP_Compatibility del juego se para en su linea 22 con
# "uninitialized constant Encoding::UTF_8".
#
# Se reproduce aqui la misma regla de nombres que usa set_encoding_const en
# encoding.c: lo que no sea alfanumerico pasa a "_" y la inicial se pone en
# mayuscula. El juego solo usa UTF-8 (17 Encoding::UTF_8 y 23
# force_encoding("UTF-8") en sus 770 scripts, ninguna otra codificacion y
# ninguna conversion entre juegos de caracteres), asi que esto le basta.
ESPECIALES = %w[external internal locale filesystem]
silencio, $VERBOSE = $VERBOSE, nil   # Encoding.find avisa por cada codificacion ausente
Encoding.name_list.each do |nombre|
  next if ESPECIALES.include?(nombre)
  const = nombre.gsub(/[^A-Za-z0-9_]/, "_").sub(/\A[a-z]/) { |c| c.upcase }
  next unless const =~ /\A[A-Z]/
  next if Encoding.const_defined?(const, false)
  begin
    Encoding.const_set(const, Encoding.find(nombre))
  rescue StandardError
    # Un alias sin codificacion detras: no es motivo para parar el arranque.
  end
end
$VERBOSE = silencio
NX.log("[nx] constantes de Encoding definidas: #{Encoding.constants.size - 5}")

# --- diagnostico del cargador ---------------------------------------------
def nx_prueba(etiqueta)
  NX.log("[nx] #{etiqueta}: #{yield.inspect}")
rescue Exception => e
  NX.log("[nx] #{etiqueta}: #{e.class}: #{e.message}")
end

# --- ruta de busqueda de require ------------------------------------------
# rb_is_absolute_path solo acepta rutas que empiecen por "/". El directorio de
# trabajo en Horizon es "sdmc:/switch/pokemon-anil", que no cumple, asi que
# Ruby lo trata como relativo y lo expande DOS veces: primero al construir la
# ruta de busqueda y otra vez al buscar el fichero. El resultado es
# "sdmc:/switch/pokemon-anil/sdmc:/switch/pokemon-anil/lib/set.rb", que
# evidentemente no existe.
#
# newlib acepta rutas sin dispositivo y las resuelve contra el dispositivo por
# omision, que en homebrew es la SD. Quitando el prefijo "sdmc:" la ruta empieza
# por "/", Ruby la reconoce como absoluta y deja de duplicarla. No se codifica
# el directorio: se deduce de Dir.pwd, asi que el juego sigue funcionando si se
# instala en otra carpeta.
NX::RAIZ = Dir.pwd.sub(/\A[A-Za-z0-9_]+:/, "")
$LOAD_PATH.map! do |ruta|
  if ruta.start_with?("/")
    ruta
  else
    NX::RAIZ + "/" + ruta.sub(/\A[A-Za-z0-9_]+:/, "").sub(%r{\A/}, "")
  end
end
NX.log("[nx] raiz sin dispositivo: #{NX::RAIZ.inspect}")
NX.log("[nx] $LOAD_PATH: #{$LOAD_PATH.inspect}")

# --- comprobacion del cargador --------------------------------------------
# El juego hace require de 'set', 'tsort', 'socket' e 'io/wait'. Los dos
# ultimos son shims nuestros (Cable Club necesita sockets, que en Horizon no
# hay). Si require falla, el gestor de plugins cierra el juego sin decir mas
# que una linea en errorlog.txt, asi que conviene dejarlo dicho aqui.
%w[set tsort socket io/wait].each do |feature|
  begin
    require feature
    NX.log("[nx] require #{feature}: OK")
  rescue Exception => e
    NX.log("[nx] require #{feature}: #{e.class}: #{e.message}")
  end
end
