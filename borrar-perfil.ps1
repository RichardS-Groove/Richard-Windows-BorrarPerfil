#Requires -Version 5.1
<#
.SYNOPSIS
  Escanea y borra por completo un perfil de usuario de Windows: carpeta, registro, tareas,
  reglas de firewall, papelera y (opcional) la cuenta. Deja un checklist en informes\.

.EXAMPLE
  .\borrar-perfil.ps1 -Usuario "ts-in"                          # solo escanea (no toca nada)
  .\borrar-perfil.ps1 -Usuario "ts-in" -Modo Borrar -BorrarCuenta # borra todo (pide confirmacion)
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$false)][string]$Usuario,
  [ValidateSet('Escanear', 'Borrar')][string]$Modo = 'Escanear',
  [switch]$BorrarCuenta,
  [switch]$SinConfirmar,
  [switch]$SinRegistroCompleto,   # salta la busqueda en todo el registro (mas rapido, menos completo)
  [string]$Informes = ''
)

$ErrorActionPreference = 'Stop'
$Version = '1.0.0'
$dirScript = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
if (-not $dirScript) { $dirScript = (Get-Location).Path }
if (-not $Informes) { $Informes = Join-Path $dirScript 'informes' }
$ProfileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
}
# Existe? (si Windows niega el acceso, existe pero no se puede leer)
function Test-Existe([string]$p) { try { Test-Path -LiteralPath $p -ErrorAction Stop } catch { $true } }
function Write-Paso([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Ok([string]$t)   { Write-Host "   [OK] $t" -ForegroundColor Green }
function Write-Mal([string]$t)  { Write-Host "   [!!] $t" -ForegroundColor Red }
function Write-Inf([string]$t)  { Write-Host "   $t" }

# ---------------------------------------------------------------- 1. Quien es el usuario
function Get-Objetivo {
  $cuenta = Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue
  $sid = $null
  if ($cuenta) { $sid = $cuenta.SID.Value }
  $perfiles = @(Get-CimInstance Win32_UserProfile)
  $perfil = $null
  if ($sid) { $perfil = $perfiles | Where-Object { $_.SID -eq $sid } | Select-Object -First 1 }
  if (-not $perfil) {
    $perfil = $perfiles | Where-Object { $_.LocalPath -and (Split-Path $_.LocalPath -Leaf) -ieq $Usuario } | Select-Object -First 1
    if ($perfil -and -not $sid) { $sid = $perfil.SID }
  }
  if (-not $sid) {
    foreach ($k in Get-ChildItem $ProfileList -ErrorAction SilentlyContinue) {
      $p = (Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
      if ($p -and (Split-Path $p -Leaf) -ieq $Usuario) { $sid = $k.PSChildName -replace '\.bak$', '' }
    }
  }
  $usersDir = (Get-ItemProperty $ProfileList).ProfilesDirectory -replace '%SystemDrive%', $env:SystemDrive
  $ruta = if ($perfil -and $perfil.LocalPath) { $perfil.LocalPath } else { Join-Path $usersDir $Usuario }
  [pscustomobject]@{ Cuenta = $cuenta; Sid = $sid; Perfil = $perfil; Ruta = $ruta; UsersDir = $usersDir }
}

# ---------------------------------------------------------------- 2. Lista de hallazgos
$Items = New-Object System.Collections.Generic.List[object]
function Add-Item {
  param([string]$Grupo, [string]$Que, [string]$Ruta, [string]$Tipo, [string]$Detalle = '', $Dato = $null)
  # Tipo: Cuenta | PerfilWmi | Carpeta | Clave | Valor | Tarea | Firewall | Revisar | Info
  $Items.Add([pscustomobject]@{
      N = $Items.Count + 1; Grupo = $Grupo; Que = $Que; Ruta = $Ruta; Tipo = $Tipo
      Detalle = $Detalle; Dato = $Dato; Estado = 'pendiente'; Error = ''
    })
}

function Get-Tamano([string]$p) {
  $s = (Get-ChildItem -LiteralPath $p -Recurse -Force -File -ErrorAction SilentlyContinue |
    Measure-Object Length -Sum).Sum
  if (-not $s) { return '0 MB (o sin permiso para leer)' }
  '{0:N1} MB' -f ($s / 1MB)
}

# Recorre el registro buscando claves con el SID en el nombre y valores que lo nombren.
function Search-Registro($o) {
  $escSid = [regex]::Escape($o.Sid)
  $reNombre = "^$escSid(\.bak|_Classes)?$"
  $reSid = "$escSid(?!\d)"
  $reRuta = [regex]::Escape($o.Ruta) + '(?=\\|"|''|;|,|$)'
  $raices = @(
    @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; Sub = 'SOFTWARE'; Ps = 'HKLM:\SOFTWARE' },
    @{ Hive = [Microsoft.Win32.Registry]::LocalMachine; Sub = 'SYSTEM\CurrentControlSet'; Ps = 'HKLM:\SYSTEM\CurrentControlSet' }
  )
  $script:clavesVistas = 0
  foreach ($r in $raices) {
    $pila = New-Object System.Collections.Generic.Stack[string]
    $pila.Push($r.Sub)
    while ($pila.Count) {
      $sub = $pila.Pop()
      try { $k = $r.Hive.OpenSubKey($sub, $false) } catch { continue }
      if (-not $k) { continue }
      $script:clavesVistas++
      $psPath = 'HKLM:\' + $sub
      # La base de apps de Windows se cuida sola: no se toca (borrar a mano la deja inconsistente)
      if ($sub -match '\\AppModel\\StateRepository$') { $k.Close(); continue }
      $nombre = $sub.Substring($sub.LastIndexOf('\') + 1)
      if ($nombre -match $reNombre) {
        Add-Item 'Registro' "Clave con el SID en el nombre" $psPath 'Clave'
        $k.Close(); continue   # se borra entera, no hace falta mirar adentro
      }
      try {
        foreach ($vn in $k.GetValueNames()) {
          $v = $k.GetValue($vn, $null, 'DoNotExpandEnvironmentNames')
          if ($null -eq $v) { continue }
          $txt = if ($v -is [array]) { ($v | ForEach-Object { "$_" }) -join ';' } else { "$v" }
          if ($txt.Length -gt 4096) { continue }
          $porSid = $txt -match $reSid
          $porRuta = $txt -match $reRuta
          if (-not ($porSid -or $porRuta)) { continue }
          if ($sub -match '\\ProfileGuid\\\{' -and $vn -eq 'SidString') {
            Add-Item 'Registro' 'ProfileGuid del perfil' $psPath 'Clave'
          } elseif ($sub -match '\\Authentication\\LogonUI\\SessionData\\\d+$') {
            Add-Item 'Registro' 'Sesion guardada en la pantalla de inicio' $psPath 'Clave'
          } elseif ($sub -match '\\Authentication\\LogonUI$' -and $vn -match '^(LastLoggedOn|SelectedUser)') {
            Add-Item 'Registro' "Ultimo usuario en la pantalla de inicio ($vn)" $psPath 'Valor' -Dato $vn
          } else {
            $por = if ($porSid) { 'SID' } else { 'ruta del perfil' }
            Add-Item 'Registro' "Valor que nombra al usuario ($por): $vn" $psPath 'Revisar' ($txt.Substring(0, [Math]::Min(160, $txt.Length)))
          }
        }
        foreach ($h in $k.GetSubKeyNames()) { $pila.Push("$sub\$h") }
      } catch { }
      $k.Close()
    }
  }
  # La seccion de la clave ProfileGuid puede salir repetida (un valor por clave): quitar duplicados
}

function Invoke-Escaneo($o) {
  $Items.Clear()

  Write-Paso '1/8 Cuenta de usuario'
  if ($o.Cuenta) {
    $grupos = foreach ($g in Get-LocalGroup) {
      try { if (Get-LocalGroupMember $g -ErrorAction Stop | Where-Object { $_.SID.Value -eq $o.Sid }) { $g.Name } } catch { }
    }
    $tipo = if ($BorrarCuenta) { 'Cuenta' } else { 'Info' }
    $det = "Habilitada: $($o.Cuenta.Enabled). Grupos: $(@($grupos) -join ', '). " +
    $(if ($BorrarCuenta) { 'Se borra.' } else { 'NO se borra (falta -BorrarCuenta).' })
    Add-Item 'Cuenta' "Cuenta local '$($o.Cuenta.Name)'" $o.Sid $tipo $det
    Write-Inf $det
  } else { Write-Inf 'No hay cuenta local con ese nombre (puede ser de Microsoft/Azure o ya borrada).' }

  Write-Paso '2/8 Perfil registrado en Windows'
  if ($o.Perfil) {
    Add-Item 'Perfil' 'Perfil en Windows (Win32_UserProfile)' $o.Perfil.LocalPath 'PerfilWmi' "Cargado ahora: $($o.Perfil.Loaded)"
    Write-Inf "$($o.Perfil.LocalPath)  (cargado: $($o.Perfil.Loaded))"
  } else { Write-Inf 'Windows no tiene el perfil registrado.' }

  Write-Paso '3/8 Archivos (Documentos, Descargas, Escritorio, AppData...)'
  if (Test-Existe $o.Ruta) {
    $det = foreach ($s in 'Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music', 'OneDrive', 'AppData') {
      $p = Join-Path $o.Ruta $s
      if (Test-Existe $p) { $t = Get-Tamano $p; Write-Inf ("{0,-10} {1}" -f $s, $t); "$s=$t" }
    }
    Add-Item 'Archivos' 'Carpeta completa del perfil' $o.Ruta 'Carpeta' (@($det) -join '; ')
  } else { Write-Inf "No existe $($o.Ruta)" }
  # Copias con sufijo (X.000, X.DOMINIO) que no son de otro perfil
  $usadas = @(Get-CimInstance Win32_UserProfile | ForEach-Object LocalPath)
  Get-ChildItem -LiteralPath $o.UsersDir -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "$Usuario.*" -and $usadas -notcontains $_.FullName } | ForEach-Object {
      Add-Item 'Archivos' 'Carpeta vieja del mismo usuario' $_.FullName 'Carpeta'
      Write-Inf "Carpeta vieja: $($_.FullName)"
    }

  Write-Paso '4/8 Papelera de reciclaje (todas las unidades)'
  if ($o.Sid) {
    Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' } | ForEach-Object {
      $p = Join-Path $_.Root ('$Recycle.Bin\' + $o.Sid)
      if (Test-Existe $p) { Add-Item 'Archivos' 'Papelera del usuario' $p 'Carpeta'; Write-Inf $p }
    }
  }

  Write-Paso '5/8 Tareas programadas y servicios'
  $ids = @($Usuario, "$env:COMPUTERNAME\$Usuario", $o.Sid) | Where-Object { $_ }
  Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $ids -contains $_.Principal.UserId } | ForEach-Object {
    Add-Item 'Tareas' "Tarea programada '$($_.TaskName)'" ($_.TaskPath + $_.TaskName) 'Tarea' -Dato $_
    Write-Inf "Tarea: $($_.TaskPath)$($_.TaskName)"
  }
  Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
    Where-Object { $_.StartName -and ($_.StartName -match ('(^|\\)' + [regex]::Escape($Usuario) + '$')) } | ForEach-Object {
      Add-Item 'Servicios' "Servicio que corre como el usuario: $($_.Name)" $_.PathName 'Revisar' 'No se borra solo: cambiarle la cuenta o desinstalarlo.'
      Write-Inf "Servicio: $($_.Name)"
    }

  Write-Paso '6/8 Reglas del firewall de programas del perfil'
  try {
    $pref = $o.Ruta.TrimEnd('\') + '\*'
    Get-NetFirewallApplicationFilter -ErrorAction Stop | Where-Object { $_.Program -like $pref } | ForEach-Object {
      $regla = $_ | Get-NetFirewallRule
      Add-Item 'Firewall' "Regla '$($regla.DisplayName)'" $_.Program 'Firewall' -Dato $regla.Name
      Write-Inf "Regla: $($regla.DisplayName)"
    }
  } catch { Write-Inf "No se pudo leer el firewall: $($_.Exception.Message)" }

  Write-Paso '7/8 Registro de Windows'
  if ($o.Sid) {
    if (Test-Path "Registry::HKEY_USERS\$($o.Sid)") {
      Add-Item 'Registro' 'Registro del usuario CARGADO (HKU)' "HKU\$($o.Sid)" 'Revisar' 'El usuario esta en uso: cerrar su sesion o reiniciar.'
    }
    if ($SinRegistroCompleto) {
      foreach ($c in "$ProfileList\$($o.Sid)", "$ProfileList\$($o.Sid).bak") {
        if (Test-Path $c) { Add-Item 'Registro' 'Clave del perfil (ProfileList)' $c 'Clave' }
      }
    } else {
      Write-Inf 'Buscando en todo HKLM\SOFTWARE y HKLM\SYSTEM (puede tardar 1-3 minutos)...'
      $t = [Diagnostics.Stopwatch]::StartNew()
      Search-Registro $o
      Write-Inf ("{0:N0} claves revisadas en {1:N0} s" -f $script:clavesVistas, $t.Elapsed.TotalSeconds)
    }
    # Sin duplicados (ProfileGuid / SessionData pueden salir por varios valores)
    $vistos = @{}
    foreach ($i in $Items.ToArray()) {
      $clave = "$($i.Tipo)|$($i.Ruta)|$($i.Dato)"
      if ($i.Tipo -in 'Clave', 'Valor' -and $vistos.ContainsKey($clave)) { [void]$Items.Remove($i) } else { $vistos[$clave] = 1 }
    }
    $Items | Where-Object Grupo -eq 'Registro' | ForEach-Object { Write-Inf "[$($_.Tipo)] $($_.Ruta)" }
  } else { Write-Inf 'Sin SID no hay nada que buscar en el registro.' }

  Write-Paso '8/8 Lo que Windows guarda aparte (solo informativo)'
  Add-Item 'Info' 'Windows Hello (PIN/huella)' 'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc' 'Info' 'Es de SYSTEM; Windows lo limpia al borrar la cuenta. No se toca.'
  Add-Item 'Info' 'Visor de eventos' 'eventvwr' 'Info' 'Los registros de eventos mencionan el SID. No se borran: borrarlos borra el historial de toda la PC.'
  Add-Item 'Info' 'Base de apps de Windows (StateRepository)' 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModel\StateRepository' 'Info' 'La maneja Windows; borrarla a mano rompe la Tienda. No se toca.'
  Write-Inf 'Windows Hello, Visor de eventos y base de apps: no se tocan (ver checklist).'

  # Renumerar
  $n = 0; foreach ($i in $Items) { $n++; $i.N = $n }
}

# ---------------------------------------------------------------- 3. Borrado
function Remove-CarpetaSegura([string]$p) {
  if (-not (Test-Path -LiteralPath $p)) { return }
  # 1) Quitar enlaces (junctions/symlinks) para no borrar NADA fuera del perfil
  $links = cmd /c "dir /aL /s /b `"$p`" 2>nul"
  # De afuera hacia adentro: al quitar un enlace, lo que se veia "a traves" de el desaparece y se saltea
  foreach ($l in @($links) | Where-Object { $_ } | Sort-Object Length) {
    if (-not (Test-Path -LiteralPath $l)) { continue }
    $it = Get-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue
    if ($it -and $it.PSIsContainer) { cmd /c "rmdir `"$l`"" 2>$null } else { cmd /c "del /f /q /a `"$l`"" 2>$null }
  }
  # 2) Tomar propiedad y dar permiso a Administradores (S-1-5-32-544)
  takeown /F "$p" /A /R /D S 2>$null | Out-Null
  takeown /F "$p" /A /R /D Y 2>$null | Out-Null
  icacls "$p" /grant '*S-1-5-32-544:(OI)(CI)F' /T /C /Q 2>$null | Out-Null
  # 3) Vaciar con robocopy (rutas largas) y borrar
  $vacia = Join-Path $env:TEMP ('vacia-' + [guid]::NewGuid())
  New-Item -ItemType Directory $vacia | Out-Null
  robocopy "$vacia" "$p" /MIR /XJ /B /R:0 /W:0 /NFL /NDL /NJH /NJS /NP | Out-Null
  Remove-Item -LiteralPath $vacia -Force
  cmd /c "rmdir /s /q `"$p`"" 2>$null
  if (Test-Existe $p) { throw "Quedo la carpeta $p (algun archivo en uso: reiniciar y volver a correr)" }
}

function Invoke-Borrado($o, [string]$dirInforme) {
  $resp = Join-Path $dirInforme 'respaldo-registro'
  New-Item -ItemType Directory $resp -Force | Out-Null

  Write-Paso 'Cerrando programas del usuario que sigan abiertos'
  Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
    Where-Object { $_.UserName -and ($_.UserName -split '\\')[-1] -ieq $Usuario } | ForEach-Object {
      Write-Inf "Cierro $($_.ProcessName) ($($_.Id))"; Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }

  # Orden: tareas y firewall -> perfil oficial de Windows -> restos -> registro -> cuenta
  $orden = @{ Tarea = 1; Firewall = 2; PerfilWmi = 3; Carpeta = 4; Valor = 5; Clave = 6; Cuenta = 7 }
  $aBorrar = $Items | Where-Object { $orden.ContainsKey($_.Tipo) } | Sort-Object { $orden[$_.Tipo] }, N
  $nr = 0
  foreach ($i in $aBorrar) {
    Write-Host ("   #{0,-3} {1} -> {2}" -f $i.N, $i.Que, $i.Ruta)
    try {
      switch ($i.Tipo) {
        'Tarea'     { Unregister-ScheduledTask -TaskName $i.Dato.TaskName -TaskPath $i.Dato.TaskPath -Confirm:$false }
        'Firewall'  { Remove-NetFirewallRule -Name $i.Dato }
        'PerfilWmi' { Get-CimInstance Win32_UserProfile -Filter "SID='$($o.Sid)'" | Remove-CimInstance }
        'Carpeta'   { Remove-CarpetaSegura $i.Ruta }
        'Valor'     {
          $nr++; reg export ($i.Ruta -replace '^HKLM:', 'HKLM') (Join-Path $resp "$nr-valor.reg") /y 2>$null | Out-Null
          Remove-ItemProperty -LiteralPath $i.Ruta -Name $i.Dato -ErrorAction SilentlyContinue
        }
        'Clave'     {
          if (Test-Path -LiteralPath $i.Ruta) {
            $nr++; reg export ($i.Ruta -replace '^HKLM:', 'HKLM') (Join-Path $resp "$nr-clave.reg") /y 2>$null | Out-Null
            Remove-Item -LiteralPath $i.Ruta -Recurse -Force
          }
        }
        'Cuenta'    { Remove-LocalUser -SID $o.Sid }
      }
      $i.Estado = 'borrado'; Write-Ok 'hecho'
    } catch { $i.Estado = 'fallo'; $i.Error = $_.Exception.Message; Write-Mal $i.Error }
  }
}

# ---------------------------------------------------------------- 4. Checklist
function Write-Checklist($o, [string]$archivo, [string]$titulo) {
  $l = New-Object System.Collections.Generic.List[string]
  $l.Add("# $titulo"); $l.Add('')
  $l.Add("- Usuario: **$Usuario** | SID: ``$($o.Sid)`` | Carpeta: ``$($o.Ruta)``")
  $l.Add("- Maquina: $env:COMPUTERNAME | Fecha: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Script v$Version | Modo: $Modo"); $l.Add('')
  $l.Add('Marcas: `[ ]` se va a borrar · `[x]` borrado · `[!]` fallo · `[?]` revisar a mano · `[i]` solo informativo'); $l.Add('')
  foreach ($g in $Items | Group-Object Grupo) {
    $l.Add("## $($g.Name)"); $l.Add('')
    foreach ($i in $g.Group) {
      $m = switch ($i.Estado) { 'borrado' { '[x]' } 'fallo' { '[!]' } default {
          switch ($i.Tipo) { 'Revisar' { '[?]' } 'Info' { '[i]' } default { '[ ]' } } } }
      $linea = "- $m **#$($i.N)** $($i.Que) — ``$($i.Ruta)``"
      if ($i.Detalle) { $linea += " — $($i.Detalle)" }
      if ($i.Error) { $linea += " — FALLO: $($i.Error)" }
      $l.Add($linea)
    }
    $l.Add('')
  }
  [IO.File]::WriteAllLines($archivo, $l, (New-Object Text.UTF8Encoding $true))
}

# ================================================================ Principal
Write-Host "Borrar perfil de Windows v$Version  |  usuario: $Usuario  |  modo: $Modo" -ForegroundColor Yellow
$admin = Test-Admin
if (-not $admin) { Write-Host 'Aviso: sin permisos de administrador el escaneo ve menos cosas.' -ForegroundColor DarkYellow }

$o = Get-Objetivo
if (-not $o.Sid -and -not (Test-Existe $o.Ruta)) {
  Write-Host "No encontre ningun usuario ni perfil llamado '$Usuario'." -ForegroundColor Red; exit 3
}
Write-Host "SID: $($o.Sid)   Carpeta: $($o.Ruta)"

# --- Frenos de seguridad
$frenos = @()
$miSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($o.Sid -eq $miSid) { $frenos += 'Es el usuario con el que estas conectado ahora.' }
if ($o.Sid -match '^S-1-5-(18|19|20)$' -or $o.Sid -match '-500$') { $frenos += 'Es una cuenta del sistema o el Administrador incorporado.' }
if ($Usuario -in 'Default', 'Public', 'Administrador', 'Administrator', 'Todos', 'All Users', 'Default User') { $frenos += 'Es una carpeta o cuenta especial de Windows.' }
if ($o.Perfil -and $o.Perfil.Special) { $frenos += 'Windows lo marca como perfil especial.' }
if ($o.Perfil -and $o.Perfil.Loaded) { $frenos += 'El perfil esta en uso (sesion abierta). Cerrar su sesion o reiniciar.' }
$aqui = $dirScript.TrimEnd('\') + '\'
if ($aqui -like ($o.Ruta.TrimEnd('\') + '\*') -or ((Resolve-Path $Informes -ErrorAction SilentlyContinue) -and $Informes -like ($o.Ruta.TrimEnd('\') + '\*'))) { $frenos += "El script esta DENTRO del perfil a borrar. Copiar la carpeta a C:\BorrarPerfil y correrlo desde ahi." }
$sesiones = (quser 2>$null) -join "`n"
if ($sesiones -match ('(?im)^\s*>?' + [regex]::Escape($Usuario) + '\s')) { $frenos += 'El usuario tiene una sesion abierta (quser).' }

$dirInforme = Join-Path $Informes ((Get-Date -Format 'yyyy-MM-dd_HHmm') + '_' + ($Usuario -replace '[^\w.-]', '_'))
New-Item -ItemType Directory $dirInforme -Force | Out-Null

Invoke-Escaneo $o
$checklist = Join-Path $dirInforme 'checklist.md'
Write-Checklist $o $checklist 'Checklist: lo que se encontro del usuario'

$porBorrar = @($Items | Where-Object { $_.Tipo -notin 'Revisar', 'Info' }).Count
$revisar = @($Items | Where-Object Tipo -eq 'Revisar').Count
Write-Paso 'Resumen del escaneo'
Write-Inf "Para borrar: $porBorrar   |   Revisar a mano: $revisar"
Write-Inf "Checklist: $checklist"
foreach ($f in $frenos) { Write-Mal "FRENO: $f" }

if ($Modo -eq 'Escanear') { Write-Host "`nSolo escaneo: no se toco nada." -ForegroundColor Green; exit 0 }

# --- Modo Borrar
if ($frenos.Count) { Write-Host "`nNo se borra nada mientras haya frenos." -ForegroundColor Red; exit 4 }
if (-not $admin) { Write-Host "`nPara borrar hace falta abrirlo como administrador (usar el .bat)." -ForegroundColor Red; exit 5 }
if ($porBorrar -eq 0) { Write-Host "`nNo queda nada para borrar." -ForegroundColor Green; exit 0 }
if (-not $SinConfirmar) {
  Write-Host "`nEsto NO se puede deshacer. Se borran $porBorrar elementos de '$Usuario' (archivos incluidos)." -ForegroundColor Red
  $r = Read-Host "Para seguir escribi exactamente:  BORRAR $Usuario"
  if ($r -cne "BORRAR $Usuario") { Write-Host 'Cancelado. No se toco nada.' -ForegroundColor Yellow; exit 6 }
}

Invoke-Borrado $o $dirInforme
Write-Checklist $o $checklist 'Checklist: borrado del usuario'

Write-Paso 'Verificacion: escaneo de nuevo'
$antes = $Items.ToArray()
Invoke-Escaneo (Get-Objetivo)
$quedan = @($Items | Where-Object { $_.Tipo -notin 'Revisar', 'Info' })
# Si se pidio no borrar la cuenta, esa linea no cuenta como resto
Write-Checklist $o (Join-Path $dirInforme 'verificacion.md') 'Verificacion: lo que quedo despues del borrado'
$fallos = @($antes | Where-Object Estado -eq 'fallo').Count
if ($quedan.Count -eq 0 -and $fallos -eq 0) {
  Write-Host "`nLISTO: no quedo nada de '$Usuario'. Informe en $dirInforme" -ForegroundColor Green
  Write-Host "El respaldo del registro (por las dudas) esta en $dirInforme\respaldo-registro: se puede borrar." -ForegroundColor Green
  exit 0
}
Write-Host "`nQuedaron $($quedan.Count) restos y $fallos fallos. Ver $dirInforme\verificacion.md (reiniciar y volver a correr suele alcanzar)." -ForegroundColor Red
exit 2
