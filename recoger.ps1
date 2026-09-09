# recoger.ps1 - saca de la tarjeta SD todo lo que la consola tenga que contar.
#
# En Ryujinx los registros se leen en caliente: la SD virtual es una carpeta del
# PC y iterate.sh hace cat sobre ella. En una consola de verdad no hay nada de
# eso. Si el juego se cae, la pantalla se queda negra o salta el panel de error
# de Horizon, y lo unico que sobrevive es lo que llego a escribirse en la SD
# antes de morir. Este guion recoge esas huellas de una vez, porque hacerlo a
# mano es garantia de olvidarse justo de la que hacia falta.
#
# Son cuatro fuentes y solo la primera es nuestra:
#
#   1. Los registros del juego.  mkxp-boot.log lleva marca de tiempo por linea
#      (§5.48) y mkxp-ruby.log va con fsync (§5.52), asi que los dos llegan
#      enteros hasta el instante del fallo.
#   2. atmosphere/crash_reports/.  Los escribe Atmosphere cuando un proceso
#      revienta, con registros y pila. Es el equivalente en consola a la traza
#      de nx_excepcion.c, y ademas funciona cuando el fallo ha sido tan pronto
#      que nuestro manejador aun no estaba puesto.
#   3. atmosphere/fatal_errors/.  Los del panel de error con codigo.
#   4. Las partidas .rxdata, para comprobar que se guardaron de verdad y que se
#      pueden volver a leer en el PC.
#
# La SD se busca sola: es la unica unidad extraible que tiene a la vez
# /atmosphere y /switch.
#
#   .\recoger.ps1 -Juego pokemon-anil
#
# El slug es obligatorio y decide de que carpeta de la tarjeta se recogen los
# registros y las partidas: SD:/switch/<slug>/. Los informes de Atmosphere son
# de la consola entera y se traen igual.
param(
    [Parameter(Mandatory=$true)][string]$Juego,
    [string]$Unidad = "",
    [string]$Destino = "",
    [int]$Ultimos = 6,        # cuantos informes de Atmosphere traerse
    [switch]$Limpiar          # borra los registros de la SD tras copiarlos
)
$ErrorActionPreference = "Stop"

function Buscar-SD {
    foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        $r = $d.RootDirectory.FullName
        if ((Test-Path (Join-Path $r "atmosphere")) -and (Test-Path (Join-Path $r "switch"))) {
            return $r
        }
    }
    return $null
}

if ($Unidad -eq "") { $Unidad = Buscar-SD }
if (-not $Unidad) {
    Write-Output "No encuentro la SD. Debe tener /atmosphere y /switch en la raiz."
    Write-Output "Si esta montada en otro sitio: .\recoger.ps1 -Unidad E:\"
    exit 1
}
Write-Output "SD encontrada en $Unidad"

if (-not $Destino) { $Destino = Join-Path $PSScriptRoot "docs\consola" }
$sello = Get-Date -Format "yyyyMMdd-HHmmss"
$dir = Join-Path $Destino "$sello-$Juego"
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$juego = Join-Path $Unidad "switch\$Juego"
if (-not (Test-Path $juego)) {
    Write-Output "AVISO: no esta $juego; solo se recogen los informes de Atmosphere"
}
$copiados = 0

# 1. Registros y partidas del juego.
foreach ($n in @("mkxp-boot.log", "mkxp-debug.log", "mkxp-ruby.log", "errorlog.txt")) {
    $f = Join-Path $juego $n
    if (Test-Path $f) {
        Copy-Item $f (Join-Path $dir $n)
        $lineas = (Get-Content $f | Measure-Object -Line).Lines
        Write-Output ("  {0,-16} {1,6} lineas" -f $n, $lineas)
        $copiados++
        if ($Limpiar) { Remove-Item $f }
    } else {
        Write-Output ("  {0,-16} (no existe)" -f $n)
    }
}
Get-ChildItem -Path $juego -Filter "*.rxdata" -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $dir $_.Name)
    Write-Output ("  {0,-16} {1,6} B  (partida)" -f $_.Name, $_.Length)
    $copiados++
}

# 2 y 3. Lo que anota Atmosphere por su cuenta. La carpeta acumula todos los
# cuelgues de la consola desde siempre, asi que hay que quedarse solo con los
# ultimos.
#
# El filtro NO puede ser por fecha. El reloj de la consola no tiene por que
# coincidir con el del PC —en esta va 24 anos adelantado, y sus ficheros salen
# fechados en 2050—, asi que "lo de las ultimas 24 horas" cogia el archivo
# entero. Ordenar por fecha y quedarse con los N primeros da igual el desfase:
# solo hace falta que el reloj sea consistente consigo mismo.
foreach ($sub in @("crash_reports", "fatal_errors")) {
    $orig = Join-Path $Unidad "atmosphere\$sub"
    if (-not (Test-Path $orig)) { continue }
    $recientes = Get-ChildItem -Path $orig -Recurse -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First $Ultimos
    if (-not $recientes) { Write-Output "  $sub : vacio"; continue }
    $dst = Join-Path $dir $sub
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    foreach ($f in $recientes) {
        Copy-Item $f.FullName (Join-Path $dst $f.Name)
        Write-Output ("  {0}\{1}  {2}" -f $sub, $f.Name, $f.LastWriteTime)
        $copiados++
    }
}

Write-Output ""
Write-Output "$copiados ficheros en $dir"

# Lo primero que uno quiere mirar, sin tener que abrir nada.
$boot = Join-Path $dir "mkxp-boot.log"
if (Test-Path $boot) {
    Write-Output ""
    Write-Output "--- memoria y pantalla ---"
    Select-String -Path $boot -Pattern "\[mem\]|\[gfx\]" | ForEach-Object { $_.Line }
    Write-Output ""
    Write-Output "--- ultimas 5 lineas del arranque ---"
    Get-Content $boot -Tail 5
}
$err = Join-Path $dir "errorlog.txt"
if ((Test-Path $err) -and (Get-Item $err).Length -gt 0) {
    Write-Output ""
    Write-Output "--- errorlog.txt: EL JUEGO REGISTRO UN ERROR ---"
    Get-Content $err -Tail 20
}
