# Empaquetar.ps1 — monta la carpeta que va a la tarjeta SD, con interfaz.
#
# Junta dos cosas que vienen de sitios distintos y que este repositorio no puede
# ni debe mezclar:
#
#   1. TU copia de Pokemon Anil 4.0 para PC (Data/, Graphics/, Audio/, Fonts/...)
#   2. La entrega del port (pokemon-anil.nro, mkxp.json, lib/), que es lo que
#      hay en la misma carpeta que este guion.
#
# y deja en la carpeta de salida un directorio switch/pokemon-anil/ listo para
# copiar a la raiz de la SD. Si en la entrega hay un pokemon-anil.nsp, lo deja
# al lado para instalarlo (Awoo Installer, DBI o Goldleaf).
#
# DOS FORMAS DE LLEVAR LOS RECURSOS. Los recursos del juego son 22.148 ficheros
# y 668 MB, y ahi esta el problema: una tarjeta SD no tarda por los bytes, tarda
# por la cuenta. Cada fichero es una entrada de directorio, una asignacion de
# clusters y una actualizacion de la tabla de FAT32; copiarlos sueltos va entre
# cinco y diez veces mas lento que copiar los mismos bytes en un solo fichero, y
# ademas cualquier corte a mitad deja una carpeta a medias que no se distingue
# de una entera.
#
#   -Contenedor zip       (por omision) un unico anil-datos.zip SIN COMPRIMIR,
#                         que el .nro monta al arrancar con PhysFS. Un fichero
#                         que se copia rapido, se envia de una pieza y se
#                         comprueba con un solo hash.
#   -Contenedor carpetas  Data/, Graphics/, Audio/ y Fonts/ sueltas, como hasta
#                         ahora. Es lo que hay que usar para parchear ficheros
#                         del juego uno a uno.
#
# EL TRATO, medido y sin adornos. El contenedor cuesta unos segundos mas de
# arranque cada vez que se abre el juego: hay que abrir el archivo y leer su
# indice antes de empezar, y eso no se paga con las carpetas sueltas. (Eran
# trece segundos hasta que el indice paso a leerse de una pasada, README 5.63.) En cambio se ahorra en cada copia: 22.148 ficheros a una
# tarjeta SD no van a la velocidad de la tarjeta, van a la del sistema de
# ficheros, y ahi la diferencia se cuenta en decenas de minutos.
#
# Asi que: contenedor si vas a copiar, enviar o rehacer la tarjeta; carpetas
# sueltas si el juego ya esta puesto y lo que quieres es que arranque cuanto
# antes o cambiar graficos a mano.
#
# Sin comprimir a proposito: 535 de los 668 MB ya son PNG y OGG, formatos
# comprimidos, y los .rxdata llevan zlib dentro. Comprimir ahorra un 5% y se
# paga inflando cada lectura durante la partida.
#
# No necesita nada instalado: PowerShell viene con Windows. Se puede usar sin
# interfaz:   powershell -File Empaquetar.ps1 -Juego "C:\...\Pokemon Anil" -Salida D:\sd
param(
    [string]$Juego = "",
    [string]$Salida = "",
    [ValidateSet("zip", "carpetas")]
    [string]$Contenedor = "zip",
    [switch]$SinInterfaz
)

$ErrorActionPreference = "Stop"
$Entrega = Split-Path -Parent $MyInvocation.MyCommand.Path

# El nombre lo conoce tambien sharedstate.cpp del motor: si cambia aqui, cambia alli.
$NombrePaquete = "anil-datos.zip"
$CarpetasJuego = @("Data", "Graphics", "Audio", "Fonts")
# Restos de escritorio que no pintan nada en una consola.
$NoCopiar = @("*.exe", "*.dll", "Thumbs.db", "desktop.ini", "*.parcial")

function Comprueba-Juego([string]$ruta) {
    if (-not $ruta -or -not (Test-Path $ruta)) { return "No existe la carpeta." }
    foreach ($imprescindible in @("Data\Scripts.rxdata", "Graphics", "Audio")) {
        if (-not (Test-Path (Join-Path $ruta $imprescindible))) { return "Falta $imprescindible - no parece la carpeta de Pokemon Anil." }
    }
    return $null
}

function Comprueba-Entrega() {
    foreach ($f in @("pokemon-anil.nro", "mkxp.json", "lib")) {
        if (-not (Test-Path (Join-Path $Entrega $f))) { return "Falta $f junto a este guion - descomprime la entrega entera." }
    }
    return $null
}

function Se-Descarta([string]$nombre) {
    foreach ($p in $NoCopiar) { if ($nombre -like $p) { return $true } }
    return $false
}

#------------------------------------------------------------------ contenedor
# El contenedor se escribe a mano, byte a byte, y no con el ZipArchive de .NET.
# La razon es concreta: en .NET Framework —el que trae Windows y el que usa
# PowerShell 5.1— CompressionLevel::NoCompression NO almacena. Sigue usando
# deflate (metodo 8) con bloques sin comprimir, de modo que el fichero sale
# incluso cinco bytes mas grande y, sobre todo, COMPRIMIDO a ojos de quien lo
# lea. Se comprobo: las 26 entradas de la prueba salian todas con metodo 8.
#
# Y eso, en la consola, no es un detalle de formato:
#
#   - PhysFS pasa cada lectura del juego por inflate en vez de leer el fichero
#     a un desplazamiento, y reserva la ventana de zlib por cada fichero abierto.
#   - Al buscar hacia atras dentro de una entrada comprimida, PhysFS no puede
#     saltar: rebobina y vuelve a inflar desde el principio. El juego busca hacia
#     atras cada vez que un OGG de musica vuelve a su punto de bucle, y son
#     ficheros de varios megas.
#
# Almacenado (metodo 0), leer del contenedor es leer del fichero a otro
# desplazamiento, y ahi se acaba el coste. Por eso estos 90 renglones de C#:
# escriben cabecera local, indice central y registro final, que es todo lo que
# un zip es. Se compilan al vuelo con Add-Type, que viene con .NET; sigue sin
# hacer falta instalar nada.
#
# Los limites del formato clasico (4 GB y 65.534 entradas) se comprueban y se
# dicen: con 668 MB y 22.300 entradas sobra sitio, pero un zip64 mal hecho seria
# peor que negarse.
if (-not ('AnilPaquete' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;

public class AnilPaquete : IDisposable
{
    private FileStream s;
    private MemoryStream central = new MemoryStream();
    private int entradas;
    private static readonly uint[] tabla = Tabla();

    public long Ficheros;
    public long Bytes;

    public AnilPaquete(string ruta)
    {
        s = new FileStream(ruta, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20);
    }

    private static uint[] Tabla()
    {
        uint[] t = new uint[256];
        for (uint i = 0; i < 256; i++)
        {
            uint c = i;
            for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            t[i] = c;
        }
        return t;
    }

    private static void U16(Stream o, int v) { o.WriteByte((byte)v); o.WriteByte((byte)(v >> 8)); }
    private static void U32(Stream o, uint v)
    {
        o.WriteByte((byte)v); o.WriteByte((byte)(v >> 8));
        o.WriteByte((byte)(v >> 16)); o.WriteByte((byte)(v >> 24));
    }
    private static int DosFecha(DateTime d) { return ((d.Year - 1980) << 9) | (d.Month << 5) | d.Day; }
    private static int DosHora(DateTime d) { return (d.Hour << 11) | (d.Minute << 5) | (d.Second / 2); }

    // nombre: separado por '/' y, si es directorio, terminado en '/'
    private void Entrada(string nombre, string local, DateTime fecha, bool dir)
    {
        byte[] nb = Encoding.UTF8.GetBytes(nombre);
        // Bit 11 = el nombre viene en UTF-8. PhysFS lo mira: sin el, interpreta
        // Latin-1 y una tilde en un nombre de fichero se convierte en otra ruta.
        int flags = 0;
        foreach (byte b in nb) if (b > 127) flags = 1 << 11;
        if (fecha.Year < 1980) fecha = new DateTime(1980, 1, 1);

        long donde = s.Position;
        if (donde > 0xFFFFFF00L)
            throw new Exception("el contenedor pasa de 4 GB: empaqueta con carpetas sueltas.");
        if (entradas >= 65534)
            throw new Exception("el contenedor pasa de 65.534 entradas: empaqueta con carpetas sueltas.");

        U32(s, 0x04034b50); U16(s, 10); U16(s, flags); U16(s, 0);
        U16(s, DosHora(fecha)); U16(s, DosFecha(fecha));
        long hueco = s.Position;          // crc y los dos tamanos, aun sin saber
        U32(s, 0); U32(s, 0); U32(s, 0);
        U16(s, nb.Length); U16(s, 0);
        s.Write(nb, 0, nb.Length);

        uint crc = 0xFFFFFFFF;
        long tam = 0;
        if (!dir)
        {
            byte[] buf = new byte[1 << 20];
            using (FileStream e = new FileStream(local, FileMode.Open, FileAccess.Read, FileShare.Read, buf.Length))
            {
                int n;
                while ((n = e.Read(buf, 0, buf.Length)) > 0)
                {
                    for (int i = 0; i < n; i++) crc = tabla[(crc ^ buf[i]) & 0xFF] ^ (crc >> 8);
                    s.Write(buf, 0, n);
                    tam += n;
                }
            }
        }
        crc ^= 0xFFFFFFFF;

        // El crc se sabe despues de leer el fichero: se vuelve al hueco y se
        // rellena. Una pasada de lectura por fichero, no dos.
        long fin = s.Position;
        s.Position = hueco;
        U32(s, crc); U32(s, (uint)tam); U32(s, (uint)tam);
        s.Position = fin;

        U32(central, 0x02014b50); U16(central, 20); U16(central, 10); U16(central, flags); U16(central, 0);
        U16(central, DosHora(fecha)); U16(central, DosFecha(fecha));
        U32(central, crc); U32(central, (uint)tam); U32(central, (uint)tam);
        U16(central, nb.Length); U16(central, 0); U16(central, 0);
        U16(central, 0); U16(central, 0);
        U32(central, dir ? 0x10u : 0x20u);
        U32(central, (uint)donde);
        central.Write(nb, 0, nb.Length);

        entradas++;
        if (!dir) { Ficheros++; Bytes += tam; }
    }

    public void AnadeDirectorio(string nombre)
    {
        Entrada(nombre.EndsWith("/") ? nombre : nombre + "/", null, DateTime.Now, true);
    }

    public void AnadeFichero(string nombre, string local, DateTime fecha)
    {
        Entrada(nombre, local, fecha, false);
    }

    public void Cierra()
    {
        long inicio = s.Position;
        central.Position = 0;
        central.CopyTo(s);
        long medida = s.Position - inicio;
        U32(s, 0x06054b50); U16(s, 0); U16(s, 0);
        U16(s, entradas); U16(s, entradas);
        U32(s, (uint)medida); U32(s, (uint)inicio); U16(s, 0);
        s.Flush();
    }

    public void Dispose() { if (s != null) { s.Dispose(); s = null; } }
}
'@
}

# Las entradas de directorio se escriben ANTES de su contenido. PhysFS sabe
# deducir los directorios que faltan, pero un zip donde el padre va delante es
# lo que producen zip, 7-Zip y el propio Windows, y es el camino mas trillado.
function Anade-Carpeta($paquete, [string]$raiz, [string]$rel, [scriptblock]$avisa) {
    $abs = Join-Path $raiz $rel
    $paquete.AnadeDirectorio(($rel -replace '\\', '/'))

    foreach ($f in (Get-ChildItem -LiteralPath $abs -File | Sort-Object Name)) {
        if (Se-Descarta $f.Name) { continue }
        $paquete.AnadeFichero((($rel + '\' + $f.Name) -replace '\\', '/'), $f.FullName, $f.LastWriteTime)
        if (($paquete.Ficheros % 2500) -eq 0) {
            $avisa.Invoke(("     {0,6} ficheros, {1,5} MB" -f $paquete.Ficheros, [math]::Round($paquete.Bytes / 1MB)))
        }
    }

    foreach ($d in (Get-ChildItem -LiteralPath $abs -Directory | Sort-Object Name)) {
        Anade-Carpeta $paquete $raiz (Join-Path $rel $d.Name) $avisa
    }
}

function Empaqueta-Contenedor([string]$juego, [string]$destino, [scriptblock]$avisa) {
    # Se escribe con otro nombre y se renombra al terminar: un zip a medias no
    # puede parecerse a uno acabado, porque el que lo lee es una consola sin
    # teclado a la que no se le puede preguntar.
    $parcial = Join-Path $destino ($NombrePaquete + ".parcial")
    $final = Join-Path $destino $NombrePaquete
    if (Test-Path $parcial) { Remove-Item $parcial -Force }

    $paquete = New-Object AnilPaquete($parcial)
    try {
        foreach ($c in $CarpetasJuego) {
            if (-not (Test-Path (Join-Path $juego $c))) { continue }
            $avisa.Invoke("     $c")
            Anade-Carpeta $paquete $juego $c $avisa
        }
        $paquete.Cierra()
    } finally { $paquete.Dispose() }

    $cuenta = [pscustomobject]@{ Ficheros = $paquete.Ficheros; Bytes = $paquete.Bytes }
    Move-Item $parcial $final -Force
    $avisa.Invoke(("     {0} ficheros, {1} MB dentro de {2}" -f $cuenta.Ficheros, [math]::Round($cuenta.Bytes / 1MB), $NombrePaquete))
    return $cuenta
}

# Comprobar el zip es volver a abrirlo y leer su indice, no mirar si el fichero
# esta: lo primero demuestra que la consola va a poder leerlo, lo segundo no
# demuestra nada.
function Comprueba-Contenedor([string]$ruta, $cuenta, [scriptblock]$avisa) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ruta)
    try {
        $entradas = $zip.Entries.Count
        $ficheros = @($zip.Entries | Where-Object { -not $_.FullName.EndsWith("/") })
        $bytes = ($ficheros | Measure-Object -Property Length -Sum).Sum
        if (-not $zip.GetEntry("Data/Scripts.rxdata")) { throw "el contenedor no lleva Data/Scripts.rxdata dentro." }
        if ($ficheros.Count -ne $cuenta.Ficheros) { throw ("el contenedor tiene {0} ficheros y se metieron {1}." -f $ficheros.Count, $cuenta.Ficheros) }
        if ($bytes -ne $cuenta.Bytes) { throw ("el contenedor suma {0} bytes y el original {1}." -f $bytes, $cuenta.Bytes) }
        # PhysFS separa con '/'. Una contrabarra en un nombre de entrada la
        # convertiria en parte del nombre del fichero y el juego no lo encontraria.
        foreach ($e in $zip.Entries) {
            if ($e.FullName.Contains('\')) { throw ("nombre de entrada con contrabarra: " + $e.FullName) }
            # Almacenado, no comprimido: en un fichero guardado en claro el tamano
            # comprimido es el mismo. Si alguna entrada saliera con deflate, la
            # consola pagaria una descompresion en cada lectura.
            if ($e.CompressedLength -ne $e.Length) { throw ("entrada comprimida: " + $e.FullName) }
        }
        $avisa.Invoke(("     {0} entradas leidas del indice, {1} MB sin comprimir" -f $entradas, [math]::Round($bytes / 1MB)))
    } finally { $zip.Dispose() }
}

#----------------------------------------------------------------- empaquetado
function Empaqueta([string]$juego, [string]$salida, [string]$modo, [scriptblock]$avisa) {
    $destino = Join-Path $salida "switch\pokemon-anil"
    New-Item -ItemType Directory -Force -Path $destino | Out-Null
    $paquete = Join-Path $destino $NombrePaquete

    if ($modo -eq "zip") {
        $avisa.Invoke("1/4 Recursos del juego -> $NombrePaquete (esto es lo que tarda: ~700 MB)")
        $cuenta = Empaqueta-Contenedor $juego $destino $avisa
    } else {
        $avisa.Invoke("1/4 Recursos del juego, sueltos (esto es lo que tarda: ~700 MB y 22.000 ficheros)")
        foreach ($d in $CarpetasJuego) {
            $o = Join-Path $juego $d
            if (Test-Path $o) {
                $avisa.Invoke("     $d")
                robocopy $o (Join-Path $destino $d) /E /NJH /NJS /NFL /NDL /NP /R:2 /W:1 | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "robocopy fallo copiando $d (codigo $LASTEXITCODE)" }
            }
        }
        Get-ChildItem $destino -Recurse -File -Include $NoCopiar | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    # Los cuatro ficheros pequenos de la raiz van siempre sueltos: el motor los
    # lee antes de montar nada y son los que se tocan a mano.
    foreach ($f in @("Game.ini", "preload.rb", "knownpoint.bmp", "selpoint.bmp")) {
        $o = Join-Path $juego $f
        if (Test-Path $o) { Copy-Item $o (Join-Path $destino $f) -Force }
    }

    # La llave del contenedor.
    #
    # Pokemon Essentials pregunta si un fichero existe de dos maneras distintas,
    # y elige mirando si hay un Game.rgssad al lado:
    #
    #     def pbRgssExists?(filename)
    #       return !pbGetFileChar(filename).nil? if FileTest.exist?("./Game.rgssad")
    #       return FileTest.exist?(canonicalize(filename))
    #     end
    #
    # Sin archivo pregunta al SISTEMA DE FICHEROS, que no sabe nada de lo que
    # hay dentro del contenedor. Con archivo pregunta por load_data, que va por
    # PhysFS y si lo ve. Se comprobo en el emulador: con el contenedor montado y
    # todo lo demas bien, el juego cargaba sus 770 scripts desde dentro del zip
    # y se moria a los veinte segundos con "No se establecio una posicion de
    # inicio en el editor de mapas", porque no encontraba Data/Map###.rxdata.
    #
    # Estos ocho bytes son la cabecera de un RGSSAD version 1 sin ninguna
    # entrada: un archivo vacio, valido, que mkxp-z monta sin quejarse y que le
    # dice al juego "aqui se lee por el camino de los archivos".
    if ($modo -eq "zip") {
        $suyo = Join-Path $juego "Game.rgssad"
        if (Test-Path $suyo) {
            Copy-Item $suyo (Join-Path $destino "Game.rgssad") -Force
            $avisa.Invoke("     Game.rgssad: el juego ya traia uno, se copia tal cual")
        } else {
            [System.IO.File]::WriteAllBytes((Join-Path $destino "Game.rgssad"),
                [byte[]](0x52, 0x47, 0x53, 0x53, 0x41, 0x44, 0x00, 0x01))
            $avisa.Invoke("     Game.rgssad (8 bytes): la llave que hace que el juego lea del contenedor")
        }
    }

    $avisa.Invoke("2/4 Motor del port (.nro, mkxp.json, lib/)")
    Copy-Item (Join-Path $Entrega "pokemon-anil.nro") (Join-Path $destino "pokemon-anil.nro") -Force
    Copy-Item (Join-Path $Entrega "mkxp.json") (Join-Path $destino "mkxp.json") -Force
    Get-ChildItem (Join-Path $destino "lib") -Filter "nx-*.rb" -ErrorAction SilentlyContinue | Remove-Item -Force
    robocopy (Join-Path $Entrega "lib") (Join-Path $destino "lib") /E /NJH /NJS /NFL /NDL /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy fallo copiando lib/ (codigo $LASTEXITCODE)" }

    $avisa.Invoke("3/4 Comprobacion")
    # Una comprobacion que no puede fallar no es una comprobacion: se cuenta lo
    # que tiene que estar y se compara con lo que esta.
    $pedidos = @("pokemon-anil.nro", "mkxp.json", "Game.ini", "preload.rb", "lib\nx-compat.rb", "lib\nx-rutas.rb", "lib\socket.rb")
    if ($modo -eq "zip") { $pedidos += $NombrePaquete; $pedidos += "Game.rgssad" } else { $pedidos += "Data\Scripts.rxdata" }
    $faltan = @($pedidos | Where-Object { -not (Test-Path (Join-Path $destino $_)) })
    if ($faltan.Count -gt 0) { throw ("Faltan en la salida: " + ($faltan -join ", ")) }
    if ($modo -eq "zip") { Comprueba-Contenedor $paquete $cuenta $avisa }
    $nroLocal = (Get-Item (Join-Path $Entrega "pokemon-anil.nro")).Length
    $nroSalida = (Get-Item (Join-Path $destino "pokemon-anil.nro")).Length
    if ($nroLocal -ne $nroSalida) { throw "El .nro copiado no tiene el mismo tamano que el original." }

    # Los dos modos no se estorban, pero el contenedor manda sobre las carpetas
    # sueltas (PhysFS resuelve por orden de montaje y el .nro lo monta primero).
    # Quedarse con los dos es ocupar el doble y jugar con los datos del zip.
    $avisos = @()
    if ($modo -eq "zip" -and (Test-Path (Join-Path $destino "Data\Scripts.rxdata"))) {
        $avisos += "AVISO: en la salida quedan tambien las carpetas sueltas de un empaquetado anterior. El juego leera del $NombrePaquete; borra Data\, Graphics\, Audio\ y Fonts\ para recuperar 700 MB."
    }
    if ($modo -eq "carpetas" -and (Test-Path $paquete)) {
        $avisos += "AVISO: en la salida queda un $NombrePaquete de un empaquetado anterior, y el juego lo monta ANTES que las carpetas: borralo o seguiras jugando con los datos viejos."
    }
    # La llave sin contenedor no abre nada y ademas estorba: con ella presente el
    # juego pregunta por sus ficheros a traves de load_data en vez de al sistema,
    # que es el camino largo. Se retira solo la nuestra, la de ocho bytes; un
    # Game.rgssad de verdad del juego no se toca.
    $llave = Join-Path $destino "Game.rgssad"
    if ($modo -eq "carpetas" -and (Test-Path $llave) -and (Get-Item $llave).Length -eq 8) {
        Remove-Item $llave -Force
        $avisa.Invoke("     (retirada la llave Game.rgssad de un empaquetado con contenedor)")
    }
    foreach ($a in $avisos) { $avisa.Invoke(""); $avisa.Invoke($a) }

    $avisa.Invoke("4/4 NSP")
    $nsp = Join-Path $Entrega "pokemon-anil.nsp"
    if (Test-Path $nsp) {
        Copy-Item $nsp (Join-Path $salida "pokemon-anil.nsp") -Force
        $avisa.Invoke("     pokemon-anil.nsp copiado a la salida. Instalalo con Awoo/DBI/Goldleaf; el juego sigue en SD:/switch/pokemon-anil/")
    } else {
        $avisa.Invoke("     (esta entrega no trae .nsp; el juego se lanza desde el menu homebrew)")
    }

    $tam = [math]::Round(((Get-ChildItem $destino -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))
    $cuantos = (Get-ChildItem $destino -Recurse -File).Count
    $comoQuedo = "recursos sueltos: el arranque mas rapido, 22.148 ficheros que copiar"
    if ($modo -eq "zip") { $comoQuedo = "un solo contenedor: copia rapida, unos segundos mas de arranque" }
    return "Listo: $destino ($tam MB en $cuantos ficheros, $comoQuedo). Copia la carpeta 'switch' a la raiz de la tarjeta SD."
}

# ---------------------------------------------------------------- sin interfaz
if ($SinInterfaz -or ($Juego -and $Salida)) {
    $e = Comprueba-Entrega; if ($e) { Write-Error $e; exit 1 }
    $e = Comprueba-Juego $Juego; if ($e) { Write-Error $e; exit 1 }
    $r = Empaqueta $Juego $Salida $Contenedor { param($m) Write-Host $m }
    Write-Host $r
    exit 0
}

# ---------------------------------------------------------------- interfaz
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$f = New-Object System.Windows.Forms.Form
$f.Text = "Pokemon Anil para Nintendo Switch - empaquetador"
$f.Size = New-Object System.Drawing.Size(640, 480)
$f.StartPosition = "CenterScreen"
$f.FormBorderStyle = "FixedDialog"
$f.MaximizeBox = $false

function Etiqueta($texto, $y) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $texto; $l.Location = New-Object System.Drawing.Point(16, $y); $l.AutoSize = $true
    $f.Controls.Add($l); return $l
}
function Caja($y, $valor) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point(16, $y); $t.Size = New-Object System.Drawing.Size(500, 24); $t.Text = $valor
    $f.Controls.Add($t); return $t
}
function Boton($texto, $x, $y, $ancho) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $texto; $b.Location = New-Object System.Drawing.Point($x, $y); $b.Size = New-Object System.Drawing.Size($ancho, 26)
    $f.Controls.Add($b); return $b
}

Etiqueta "1. Carpeta de TU copia de Pokemon Anil 4.0 para PC (la que tiene Game.exe, Data, Graphics...)" 16 | Out-Null
$cajaJuego = Caja 40 $Juego
$bJuego = Boton "Buscar..." 524 39 90
$bJuego.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Carpeta de Pokemon Anil 4.0"
    if ($d.ShowDialog() -eq "OK") { $cajaJuego.Text = $d.SelectedPath }
})

Etiqueta "2. Donde dejar el resultado (una carpeta vacia, o directamente la raiz de la tarjeta SD)" 80 | Out-Null
$cajaSalida = Caja 104 $Salida
$bSalida = Boton "Buscar..." 524 103 90
$bSalida.Add_Click({
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = "Carpeta de salida (o la tarjeta SD)"
    if ($d.ShowDialog() -eq "OK") { $cajaSalida.Text = $d.SelectedPath }
})

# La casilla decide entre un fichero de 700 MB y 22.000 de 30 KB. Marcada por
# omision porque copiar a una SD lo agradece muchisimo y porque un solo fichero
# se puede enviar y comprobar; se desmarca para parchear el juego a mano.
#
# Debajo va el trato explicado, porque las dos opciones son razonables y quien
# elige tiene derecho a saber que pierde: una casilla sin explicacion es una
# trampa para el que la desmarca por curiosidad.
$casillaZip = New-Object System.Windows.Forms.CheckBox
$casillaZip.Location = New-Object System.Drawing.Point(16, 132)
$casillaZip.Size = New-Object System.Drawing.Size(598, 22)
$casillaZip.Checked = ($Contenedor -eq "zip")
$casillaZip.Text = "3. Juntar los recursos en un solo fichero ($NombrePaquete)"
$f.Controls.Add($casillaZip)

$explica = New-Object System.Windows.Forms.Label
$explica.Location = New-Object System.Drawing.Point(36, 155)
$explica.Size = New-Object System.Drawing.Size(580, 46)
$explica.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
$explica.Text = ("MARCADA: un solo fichero de ~650 MB. Copiar a la tarjeta pasa de decenas de minutos a unos pocos," + [Environment]::NewLine +
                 "y se envia y comprueba de una pieza. A cambio el juego tarda unos segundos mas en arrancar, siempre." + [Environment]::NewLine +
                 "SIN MARCAR: 22.148 ficheros sueltos. Arranca lo mas rapido posible y permite cambiar graficos a mano.")
$f.Controls.Add($explica)

$estado = New-Object System.Windows.Forms.TextBox
$estado.Location = New-Object System.Drawing.Point(16, 208); $estado.Size = New-Object System.Drawing.Size(598, 176)
$estado.Multiline = $true; $estado.ReadOnly = $true; $estado.ScrollBars = "Vertical"
$estado.Font = New-Object System.Drawing.Font("Consolas", 9)
$f.Controls.Add($estado)
$e = Comprueba-Entrega
if ($e) { $estado.Text = "AVISO: $e" } else { $estado.Text = "Entrega encontrada junto a este guion. Elige las dos carpetas y pulsa Empaquetar." }

$bIr = Boton "Empaquetar" 16 394 140
$bIr.Font = New-Object System.Drawing.Font($bIr.Font, [System.Drawing.FontStyle]::Bold)
$bIr.Add_Click({
    $estado.Clear()
    $avisa = { param($m) $estado.AppendText($m + [Environment]::NewLine); [System.Windows.Forms.Application]::DoEvents() }
    $err = Comprueba-Entrega; if ($err) { $avisa.Invoke("ERROR: $err"); return }
    $err = Comprueba-Juego $cajaJuego.Text; if ($err) { $avisa.Invoke("ERROR: $err"); return }
    if (-not $cajaSalida.Text) { $avisa.Invoke("ERROR: elige la carpeta de salida."); return }
    $bIr.Enabled = $false
    $modo = "carpetas"; if ($casillaZip.Checked) { $modo = "zip" }
    try {
        $r = Empaqueta $cajaJuego.Text $cajaSalida.Text $modo $avisa
        $avisa.Invoke(""); $avisa.Invoke($r)
        [System.Windows.Forms.MessageBox]::Show($r, "Hecho", "OK", "Information") | Out-Null
    } catch {
        $avisa.Invoke("ERROR: " + $_.Exception.Message)
    } finally { $bIr.Enabled = $true }
})

$bGuia = Boton "Abrir la guia" 476 394 138
$bGuia.Add_Click({ $g = Join-Path $Entrega "GUIA.md"; if (Test-Path $g) { Start-Process notepad.exe $g } })

[void]$f.ShowDialog()
