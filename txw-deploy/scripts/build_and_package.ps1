# build_and_package.ps1
#
# Hace el flujo completo de build + limpieza + compresión + armado de carpeta de deploy.
# Esto lo hacemos en un solo script para ahorrar tokens (evitar muchos bash_tool separados).
#
# Uso (desde el working directory = raíz del repo):
#   pwsh -File build_and_package.ps1 `
#        -StartupProjectRelativePath "TruextendWebsite.Web" `
#        -PublishProfile "QA" `
#        -BuildOutputPath "TruextendWebsite.Web\bin\Release\net10.0\publish" `
#        -DeployFolder "C:\...\deploy builds\TruextendWebsite\20260419-QA" `
#        -ZipName "PublishTXWebsite_20260419.zip" `
#        -VersionsPropsPath "version.props" `
#        -PublishedVersionsPropsPath "TruextendWebsite.Web\Properties\PublishProfiles\published-versions.props" `
#        -RevertVersionsPropsOnFailure
#
# Salida: código 0 si todo OK, código 1 si hubo error. Mensajes informativos a stdout.
# La última línea del output incluye un marcador parseable:
#   [RESULT] published_versions_changed=true|false|unknown

param(
    [Parameter(Mandatory=$true)] [string]$StartupProjectRelativePath,
    [Parameter(Mandatory=$true)] [string]$PublishProfile,
    [Parameter(Mandatory=$true)] [string]$BuildOutputPath,
    [Parameter(Mandatory=$true)] [string]$DeployFolder,
    [Parameter(Mandatory=$true)] [string]$ZipName,

    # Rutas resueltas por resolve_version_state.ps1 (Paso 2.5 de la skill).
    [Parameter(Mandatory=$false)] [string]$VersionsPropsPath = "",
    [Parameter(Mandatory=$false)] [string]$PublishedVersionsPropsPath = "",

    # Si el bump de version.props ya se hizo (deploy a QA) y el publish falla,
    # revertimos el archivo para no dejar la rama sucia con un bump de un build
    # que nunca existió.
    [Parameter(Mandatory=$false)] [switch]$RevertVersionsPropsOnFailure
)

$ErrorActionPreference = "Stop"

$script:PublishedVersionsChanged = "unknown"

function Emit-Result {
    Write-Host "[RESULT] published_versions_changed=$($script:PublishedVersionsChanged)"
}

function Fail($message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    Emit-Result
    exit 1
}

function Info($message) {
    Write-Host "[INFO] $message" -ForegroundColor Cyan
}

function Get-FileHashSafe($path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    if (-not (Test-Path $path)) { return $null }
    return (Get-FileHash -Path $path -Algorithm SHA256).Hash
}

function Revert-VersionsProps {
    # Best effort. Si falla, avisamos pero no tapamos el error original.
    if (-not $RevertVersionsPropsOnFailure) { return }
    if ([string]::IsNullOrWhiteSpace($VersionsPropsPath)) { return }
    if (-not (Test-Path $VersionsPropsPath)) { return }

    Write-Host "[INFO] Revirtiendo $VersionsPropsPath (el publish falló, el bump no debe quedar en la rama)" -ForegroundColor Yellow
    git checkout -- $VersionsPropsPath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[WARN] No se pudo revertir $VersionsPropsPath automáticamente. Revisá 'git status' y revertilo a mano." -ForegroundColor Yellow
    }
}

# -------- Paso 0: Snapshot de published-versions.props antes del publish --------
# Lo usamos después para confirmar que el publish efectivamente regeneró el archivo.
$publishedVersionsHashBefore = Get-FileHashSafe $PublishedVersionsPropsPath

# -------- Paso 1: Publish --------
Info "Ejecutando dotnet publish con profile '$PublishProfile'..."

# Resolvemos el path del startup project relativo al working directory actual
$startupFullPath = Resolve-Path $StartupProjectRelativePath -ErrorAction SilentlyContinue
if (-not $startupFullPath) {
    Revert-VersionsProps
    Fail "No se encontró el proyecto startup en: $StartupProjectRelativePath (working directory: $(Get-Location))"
}

# Si ya existe un build previo, limpiarlo para empezar fresco
if (Test-Path $BuildOutputPath) {
    Info "Limpiando build anterior en $BuildOutputPath"
    Remove-Item -Recurse -Force $BuildOutputPath
}

# El comando dotnet publish se ejecuta desde el working directory actual.
# IMPORTANTE: No usar `2>&1` para mezclar stderr con stdout. En Windows PowerShell 5.1
# eso convierte cualquier escritura a stderr (incluso informativa) en NativeCommandError,
# que con $ErrorActionPreference="Stop" aborta el script aunque dotnet haya salido con 0.
# Capturamos solo stdout en la variable; stderr va por su canal natural y solo lo
# vemos si dotnet falla (en cuyo caso el output capturado suele tener el detalle).
$publishOutput = dotnet publish $StartupProjectRelativePath -p:PublishProfile=$PublishProfile --configuration Release
$publishExitCode = $LASTEXITCODE

if ($publishExitCode -ne 0) {
    Write-Host "--- Output de dotnet publish ---" -ForegroundColor Yellow
    Write-Host $publishOutput
    Write-Host "--- Fin del output ---" -ForegroundColor Yellow
    Revert-VersionsProps
    Fail "dotnet publish falló con código $publishExitCode"
}

# Validar que el build apareció
if (-not (Test-Path $BuildOutputPath)) {
    Revert-VersionsProps
    Fail "El build no se generó en la ruta esperada: $BuildOutputPath"
}

$buildContents = Get-ChildItem $BuildOutputPath
if ($buildContents.Count -eq 0) {
    Revert-VersionsProps
    Fail "La carpeta del build está vacía: $BuildOutputPath"
}

Info "Publish completado. Build generado en: $BuildOutputPath"

# -------- Paso 1.5: Verificar que el publish regeneró published-versions.props --------
# El publish debería actualizar este archivo. Si no cambió, puede ser que el
# target de versionado no corrió. NO abortamos (el build es válido igual), pero
# lo reportamos para que la skill decida si preguntarle al usuario.
if (-not [string]::IsNullOrWhiteSpace($PublishedVersionsPropsPath)) {
    $publishedVersionsHashAfter = Get-FileHashSafe $PublishedVersionsPropsPath

    if ($null -eq $publishedVersionsHashAfter) {
        Write-Host "[WARN] No se encontró '$PublishedVersionsPropsPath' después del publish. Revisá la ruta en config.version_files." -ForegroundColor Yellow
        $script:PublishedVersionsChanged = "unknown"
    }
    elseif ($publishedVersionsHashBefore -ne $publishedVersionsHashAfter) {
        Info "published-versions.props fue actualizado por el publish."
        $script:PublishedVersionsChanged = "true"
    }
    else {
        Write-Host "[WARN] El publish NO modificó '$PublishedVersionsPropsPath'. Puede ser esperado si no hubo cambios de versión, pero verificalo antes de propagar." -ForegroundColor Yellow
        $script:PublishedVersionsChanged = "false"
    }
}

# -------- Paso 2: Limpieza del build --------
Info "Limpiando archivos del build (tenants.json, Sites/Default/*)..."

$tenantsJsonPath = Join-Path $BuildOutputPath "App_Data\tenants.json"
if (Test-Path $tenantsJsonPath) {
    Remove-Item -Force $tenantsJsonPath
    Info "Eliminado: $tenantsJsonPath"
} else {
    Write-Host "[WARN] No se encontró tenants.json (puede ser esperado)" -ForegroundColor Yellow
}

$sitesDefaultPath = Join-Path $BuildOutputPath "App_Data\Sites\Default"
if (Test-Path $sitesDefaultPath) {
    Get-ChildItem -Path $sitesDefaultPath -Recurse | Remove-Item -Recurse -Force
    Info "Vaciado: $sitesDefaultPath"
} else {
    Write-Host "[WARN] No se encontró App_Data\Sites\Default (puede ser esperado)" -ForegroundColor Yellow
}

# -------- Paso 3: Crear carpeta de deploy --------
if (Test-Path $DeployFolder) {
    Write-Host "[WARN] La carpeta de deploy ya existe: $DeployFolder" -ForegroundColor Yellow
    Write-Host "       Se reutilizará (no se borra)."
} else {
    New-Item -ItemType Directory -Path $DeployFolder | Out-Null
    Info "Carpeta de deploy creada: $DeployFolder"
}

# -------- Paso 4: Comprimir build dentro de la carpeta de deploy --------
$zipPath = Join-Path $DeployFolder $ZipName
Info "Comprimiendo build a: $zipPath"

if (Test-Path $zipPath) {
    Remove-Item -Force $zipPath
}

try {
    # Comprimir el CONTENIDO de la carpeta del build (no la carpeta en sí).
    # Por eso usamos \* al final.
    Compress-Archive -Path "$BuildOutputPath\*" -DestinationPath $zipPath -CompressionLevel Optimal
}
catch {
    Fail "La compresión falló: $($_.Exception.Message)"
}

# -------- Paso 5: Validar el zip --------
if (-not (Test-Path $zipPath)) {
    Fail "El zip no se creó: $zipPath"
}

$zipSize = (Get-Item $zipPath).Length
if ($zipSize -le 0) {
    Fail "El zip se creó pero está vacío: $zipPath"
}

Info "Zip creado correctamente ($([math]::Round($zipSize / 1MB, 2)) MB)"

# -------- Paso 6: Borrar el build original (solo ahora, después de validar el zip) --------
Info "Borrando carpeta original del build: $BuildOutputPath"
Remove-Item -Recurse -Force $BuildOutputPath

Info "Empaquetado completado. Deploy folder: $DeployFolder"
Emit-Result
exit 0
