# build_and_package.ps1
#
# Hace el flujo completo de build + limpieza + compresión + armado de carpeta de deploy.
# Esto lo hacemos en un solo script para ahorrar tokens (evitar muchos bash_tool separados).
#
# Uso (desde el working directory = raíz del repo):
#   pwsh -File build_and_package.ps1 `
#        -StartupProjectRelativePath "src\TruextendWebsite.Web" `
#        -PublishProfile "FolderProfile.QA" `
#        -BuildOutputPath "C:\...\deploy builds\TruextendWebsite\build" `
#        -DeployFolder "C:\...\deploy builds\TruextendWebsite\20260419-QA" `
#        -ZipName "PublishTXWebsite_20260419.zip"
#
# Salida: código 0 si todo OK, código 1 si hubo error. Mensajes informativos a stdout.

param(
    [Parameter(Mandatory=$true)] [string]$StartupProjectRelativePath,
    [Parameter(Mandatory=$true)] [string]$PublishProfile,
    [Parameter(Mandatory=$true)] [string]$BuildOutputPath,
    [Parameter(Mandatory=$true)] [string]$DeployFolder,
    [Parameter(Mandatory=$true)] [string]$ZipName
)

$ErrorActionPreference = "Stop"

function Fail($message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
    exit 1
}

function Info($message) {
    Write-Host "[INFO] $message" -ForegroundColor Cyan
}

# -------- Paso 1: Publish --------
Info "Ejecutando dotnet publish con profile '$PublishProfile'..."

# Resolvemos el path del startup project relativo al working directory actual
$startupFullPath = Resolve-Path $StartupProjectRelativePath -ErrorAction SilentlyContinue
if (-not $startupFullPath) {
    Fail "No se encontró el proyecto startup en: $StartupProjectRelativePath (working directory: $(Get-Location))"
}

# Si ya existe un build previo, limpiarlo para empezar fresco
if (Test-Path $BuildOutputPath) {
    Info "Limpiando build anterior en $BuildOutputPath"
    Remove-Item -Recurse -Force $BuildOutputPath
}

# El comando dotnet publish se ejecuta desde el working directory actual
# (no hacemos Push-Location porque el path relativo ya funciona desde acá)
$publishOutput = dotnet publish $StartupProjectRelativePath -p:PublishProfile=$PublishProfile --configuration Release 2>&1
$publishExitCode = $LASTEXITCODE

if ($publishExitCode -ne 0) {
    Write-Host "--- Output de dotnet publish ---" -ForegroundColor Yellow
    Write-Host $publishOutput
    Write-Host "--- Fin del output ---" -ForegroundColor Yellow
    Fail "dotnet publish falló con código $publishExitCode"
}

# Validar que el build apareció
if (-not (Test-Path $BuildOutputPath)) {
    Fail "El build no se generó en la ruta esperada: $BuildOutputPath"
}

$buildContents = Get-ChildItem $BuildOutputPath
if ($buildContents.Count -eq 0) {
    Fail "La carpeta del build está vacía: $BuildOutputPath"
}

Info "Publish completado. Build generado en: $BuildOutputPath"

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
exit 0
