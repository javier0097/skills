# check_git_status.ps1
# Valida que el repo esté limpio, ignorando los archivos en el whitelist.
# Se ejecuta sobre el working directory actual (que debe ser la raíz del repo).
#
# El script se auto-localiza usando $PSScriptRoot y lee config.json del directorio padre.
# NO requiere parámetros.
#
# Uso: pwsh -File <ruta>/check_git_status.ps1
# Salida: código 0 si está limpio (o solo hay cambios whitelisted), código 1 si hay cambios no permitidos.

$ErrorActionPreference = "Stop"

# El script vive en <skill_root>/scripts/check_git_status.ps1
# Entonces config.json está en <skill_root>/config.json
$skillRoot = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $skillRoot "config.json"

# Leer el whitelist del config.json
if (-not (Test-Path $ConfigPath)) {
    Write-Error "No se encontró el archivo config.json en: $ConfigPath"
    exit 1
}

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $whitelist = @($config.git_status_whitelist)
}
catch {
    Write-Error "Error al leer/parsear config.json: $($_.Exception.Message)"
    exit 1
}

$statusOutput = git status --porcelain 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Error al ejecutar git status: $statusOutput"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($statusOutput)) {
    Write-Output "CLEAN"
    exit 0
}

# Parsear cada línea del output de git status
# Formato: "XY filename" donde X es status del index, Y status del working tree
$lines = $statusOutput -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$notWhitelisted = @()
foreach ($line in $lines) {
    # Extraer el nombre del archivo (desde el caracter 3 en adelante)
    $fileName = $line.Substring(3).Trim()

    # Si el archivo tiene comillas (por espacios), removerlas
    if ($fileName.StartsWith('"') -and $fileName.EndsWith('"')) {
        $fileName = $fileName.Substring(1, $fileName.Length - 2)
    }

    # Obtener solo el nombre base del archivo
    $baseName = Split-Path $fileName -Leaf

    # Verificar si está en el whitelist (comparamos contra nombre base y ruta completa)
    $isWhitelisted = $false
    foreach ($allowed in $whitelist) {
        if ($baseName -eq $allowed -or $fileName -eq $allowed) {
            $isWhitelisted = $true
            break
        }
    }

    if (-not $isWhitelisted) {
        $notWhitelisted += $fileName
    }
}

if ($notWhitelisted.Count -eq 0) {
    Write-Output "CLEAN"
    exit 0
} else {
    Write-Output "DIRTY"
    Write-Output "Archivos con cambios sin commitear (no whitelisted):"
    foreach ($f in $notWhitelisted) {
        Write-Output "  - $f"
    }
    exit 1
}
