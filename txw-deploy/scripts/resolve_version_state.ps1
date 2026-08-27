# resolve_version_state.ps1
#
# Lee el estado de versionado del repo y propone el número de versión para
# este deploy, aplicando la convención Major.Sprint.Patch del proyecto.
#
# Qué lee (NO escribe nada):
#   - version.props (raíz de la solución)  -> <TruextendVersion>
#   - published-versions.props              -> <PublishedVersion Include="QA|Production" Version="..." />
#
# Convención del proyecto (ver comentarios en los propios .props):
#   - Major  : cambia bajo criterio humano. El script NUNCA lo propone.
#   - Minor  : número de sprint. Sube en el primer deploy a QA de un sprint nuevo,
#              es decir, cuando la versión actual ya salió a Production.
#   - Patch  : sube en cada deploy a QA dentro del mismo sprint.
#   - PROD   : NO se bumpea. Production publica exactamente la versión que QA
#              publicó último (lo enforcea ValidatePublishVersion).
#
# Además valida por adelantado las reglas de ValidatePublishVersion, para que un
# deploy destinado a fallar se corte ANTES de compilar y no después de varios
# minutos de build.
#
# Parámetros:
#   -ConfigPath    Ruta absoluta al config.json de la skill.
#   -Environment   "QA" o "PROD".
#
# Salida: JSON.
# Exit code:
#   0  - ok=true. Revisá igual validation.status: puede ser "warning".
#   1  - ok=false. No se encontraron los archivos, no se pudo parsear, o
#        validation.status="error" (el publish fallaría).

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("QA", "PROD")]
    [string]$Environment
)

$ErrorActionPreference = "Stop"

# El nombre del ambiente en published-versions.props no es el mismo que usa la
# skill: la skill dice "PROD", el archivo dice "Production".
$EnvKeyMap = @{ "QA" = "QA"; "PROD" = "Production" }
$EnvKey = $EnvKeyMap[$Environment]

function Emit-Result {
    param(
        [bool]$Ok,
        [hashtable]$Payload,
        [string]$ErrorMessage = $null
    )
    if ($ErrorMessage) { $Payload.error = $ErrorMessage }
    $Payload.ok = $Ok
    Write-Output ($Payload | ConvertTo-Json -Depth 6 -Compress:$false)
    exit ($(if ($Ok) { 0 } else { 1 }))
}

function New-Payload {
    return @{
        versions_props_path           = ""
        published_versions_props_path = ""
        version_element               = ""
        current_version               = ""
        baselines                     = @{}
        environment                   = $Environment
        bump_required                 = $false
        suggested_version             = ""
        suggestion_reason             = ""
        validation                    = @{ status = "ok"; messages = @() }
    }
}

function Add-Message {
    param([hashtable]$Payload, [string]$Status, [string]$Message)
    # error gana sobre warning; warning gana sobre ok.
    $rank = @{ "ok" = 0; "warning" = 1; "error" = 2 }
    if ($rank[$Status] -gt $rank[$Payload.validation.status]) {
        $Payload.validation.status = $Status
    }
    $Payload.validation.messages += $Message
}

function Compare-SemVer {
    # Devuelve -1, 0 o 1. Asume major.minor.patch numérico (sin sufijos), que es
    # lo que el proyecto exige porque el valor alimenta AssemblyVersion.
    param([string]$A, [string]$B)
    $pa = @($A -split '\.' | ForEach-Object { [int]$_ })
    $pb = @($B -split '\.' | ForEach-Object { [int]$_ })
    for ($i = 0; $i -lt 3; $i++) {
        $va = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $vb = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($va -gt $vb) { return 1 }
        if ($va -lt $vb) { return -1 }
    }
    return 0
}

function Test-SemVerFormat {
    param([string]$V)
    return ($V -match '^\d+\.\d+\.\d+$')
}

$payload = New-Payload

# ----------------------------------------------------------------------------
# Paso 0: Config
# ----------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Emit-Result -Ok $false -Payload $payload -ErrorMessage "No se encontró el config.json en '$ConfigPath'."
}

try {
    $config = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Emit-Result -Ok $false -Payload $payload -ErrorMessage "No se pudo parsear config.json: $($_.Exception.Message)"
}

$vfConfig = $config.version_files
$versionElement = if ($vfConfig -and $vfConfig.version_element) { [string]$vfConfig.version_element } else { "TruextendVersion" }
$payload.version_element = $versionElement

$bumpRequired = $false
if ($config.branches.$Environment -and $null -ne $config.branches.$Environment.bump_version) {
    $bumpRequired = [bool]$config.branches.$Environment.bump_version
}
$payload.bump_required = $bumpRequired

# ----------------------------------------------------------------------------
# Paso 1: Ubicar version.props
#
# El archivo real se llama "version.props" (singular) y vive en la raíz de la
# solución. Aceptamos también "versions.props" porque la documentación interna
# del proyecto usa los dos nombres, y no queremos fallar por una 's'.
# ----------------------------------------------------------------------------

$versionsCandidates = @()
if ($vfConfig -and $vfConfig.versions_props) { $versionsCandidates += [string]$vfConfig.versions_props }
$versionsCandidates += @("version.props", "versions.props")

$versionsPath = $null
foreach ($cand in $versionsCandidates) {
    if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path $cand)) {
        $versionsPath = $cand
        break
    }
}

if (-not $versionsPath) {
    Emit-Result -Ok $false -Payload $payload `
        -ErrorMessage "No se encontró version.props (ni versions.props) en la raíz del repo. Probé: $($versionsCandidates -join ', '). Working directory: $(Get-Location)."
}

$payload.versions_props_path = $versionsPath

# ----------------------------------------------------------------------------
# Paso 2: Leer la versión actual
# ----------------------------------------------------------------------------

try {
    [xml]$versionsXml = Get-Content $versionsPath -Raw -ErrorAction Stop
}
catch {
    Emit-Result -Ok $false -Payload $payload -ErrorMessage "No se pudo parsear '$versionsPath' como XML: $($_.Exception.Message)"
}

$versionNode = $versionsXml.SelectSingleNode("//*[local-name()='$versionElement']")
if (-not $versionNode) {
    Emit-Result -Ok $false -Payload $payload `
        -ErrorMessage "No se encontró el elemento <$versionElement> en '$versionsPath'. Revisá config.version_files.version_element."
}

$currentVersion = $versionNode.InnerText.Trim()
$payload.current_version = $currentVersion

if (-not (Test-SemVerFormat $currentVersion)) {
    Add-Message -Payload $payload -Status "error" `
        -Message "La versión actual '$currentVersion' no tiene formato major.minor.patch numérico. El proyecto no admite sufijos (-rc1, etc.) porque el valor alimenta AssemblyVersion."
    Emit-Result -Ok $false -Payload $payload -ErrorMessage "Formato de versión inválido en '$versionsPath'."
}

# ----------------------------------------------------------------------------
# Paso 3: Ubicar y leer published-versions.props (los baselines)
# ----------------------------------------------------------------------------

$publishedCandidates = @()
if ($vfConfig -and $vfConfig.published_versions_props) { $publishedCandidates += [string]$vfConfig.published_versions_props }

$publishedPath = $null
foreach ($cand in $publishedCandidates) {
    if (-not [string]::IsNullOrWhiteSpace($cand) -and (Test-Path $cand)) {
        $publishedPath = $cand
        break
    }
}

# Fallback: buscarlo en el repo si la ruta del config no existe (por ejemplo si
# alguien movió la carpeta PublishProfiles).
if (-not $publishedPath) {
    $found = Get-ChildItem -Path . -Recurse -File -Filter "published-versions.props" -ErrorAction SilentlyContinue `
    | Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|\.git)\\' } `
    | Select-Object -First 1
    if ($found) {
        $publishedPath = Resolve-Path -Relative $found.FullName
    }
}

if (-not $publishedPath) {
    Emit-Result -Ok $false -Payload $payload `
        -ErrorMessage "No se encontró published-versions.props. Probé: $($publishedCandidates -join ', ') y una búsqueda recursiva en el repo."
}

$payload.published_versions_props_path = $publishedPath

try {
    [xml]$publishedXml = Get-Content $publishedPath -Raw -ErrorAction Stop
}
catch {
    Emit-Result -Ok $false -Payload $payload -ErrorMessage "No se pudo parsear '$publishedPath' como XML: $($_.Exception.Message)"
}

$baselines = @{}
$publishedNodes = $publishedXml.SelectNodes("//*[local-name()='PublishedVersion']")
foreach ($node in $publishedNodes) {
    $include = $node.GetAttribute("Include")
    $ver = $node.GetAttribute("Version")
    if (-not [string]::IsNullOrWhiteSpace($include)) {
        $baselines[$include] = $ver
    }
}
$payload.baselines = $baselines

$qaBaseline = $baselines["QA"]
$prodBaseline = $baselines["Production"]

# Validar el formato ANTES de comparar: Compare-SemVer hace [int] sobre cada
# parte y un valor vacío o con sufijo tiraría una excepción no capturada, y el
# script saldría sin emitir JSON (que es justo lo que SKILL.md promete).
foreach ($entry in @(@{ Name = "QA"; Value = $qaBaseline }, @{ Name = "Production"; Value = $prodBaseline })) {
    if (-not [string]::IsNullOrWhiteSpace($entry.Value) -and -not (Test-SemVerFormat $entry.Value)) {
        Add-Message -Payload $payload -Status "error" `
            -Message "El baseline de $($entry.Name) en '$publishedPath' es '$($entry.Value)', que no tiene formato major.minor.patch numérico. No puedo compararlo con la versión actual; corregí el archivo a mano."
        Emit-Result -Ok $false -Payload $payload -ErrorMessage "Baseline con formato inválido en '$publishedPath'."
    }
}

if ([string]::IsNullOrWhiteSpace($qaBaseline)) {
    Add-Message -Payload $payload -Status "warning" `
        -Message "No hay baseline registrado para QA en '$publishedPath'. No puedo deducir el sprint; vas a tener que indicar la versión a mano."
}

# ----------------------------------------------------------------------------
# Paso 4: Proponer versión / validar según ambiente
# ----------------------------------------------------------------------------

$parts = @($currentVersion -split '\.' | ForEach-Object { [int]$_ })
$major = $parts[0]; $minor = $parts[1]; $patch = $parts[2]

if ($Environment -eq "QA") {

    if (-not [string]::IsNullOrWhiteSpace($qaBaseline) -and (Compare-SemVer $currentVersion $qaBaseline) -gt 0) {
        # version.props ya está por delante del baseline de QA: el bump ya se
        # hizo (probablemente un publish anterior falló). No sumamos otro, o
        # saltearíamos un número.
        $payload.suggested_version = $currentVersion
        $payload.suggestion_reason = "El bump ya está aplicado en version.props ($currentVersion) y todavía no se publicó a QA (baseline: $qaBaseline). Se reutiliza ese número en lugar de sumar otro."
        Add-Message -Payload $payload -Status "warning" `
            -Message "version.props ya estaba adelantado respecto del baseline de QA. Confirmá que sea intencional (suele indicar un publish anterior que falló)."
    }
    elseif (-not [string]::IsNullOrWhiteSpace($prodBaseline) -and (Compare-SemVer $prodBaseline $currentVersion) -ge 0) {
        # La versión actual ya salió a Production => el sprint está cerrado.
        $payload.suggested_version = "$major.$($minor + 1).0"
        $payload.suggestion_reason = "La versión $currentVersion ya se publicó a Production, así que el sprint está cerrado. Este sería el primer deploy a QA del sprint siguiente."
    }
    else {
        # Seguimos dentro del sprint: redeploy a QA.
        $basePatch = $patch
        if (-not [string]::IsNullOrWhiteSpace($qaBaseline)) {
            $qaParts = @($qaBaseline -split '\.' | ForEach-Object { [int]$_ })
            if ($qaParts[0] -eq $major -and $qaParts[1] -eq $minor -and $qaParts[2] -gt $basePatch) {
                $basePatch = $qaParts[2]
            }
        }
        $payload.suggested_version = "$major.$minor.$($basePatch + 1)"
        $payload.suggestion_reason = "Production está en $prodBaseline, atrás de $($currentVersion): el sprint $minor sigue abierto, así que esto es un redeploy a QA."
    }

}
else {
    # PROD: no se bumpea. Se publica exactamente lo que QA publicó último.
    $payload.suggested_version = $currentVersion
    $payload.suggestion_reason = "En Production no se bumpea: se publica la misma versión que QA validó."

    if (-not [string]::IsNullOrWhiteSpace($qaBaseline)) {
        if ((Compare-SemVer $currentVersion $qaBaseline) -ne 0) {
            Add-Message -Payload $payload -Status "error" `
                -Message "version.props está en $currentVersion pero QA publicó $qaBaseline. ValidatePublishVersion va a rechazar el publish: Production solo acepta exactamente la versión que QA publicó último. Revisá si falta mergear staging a master, o si alguien bumpeó sin publicar a QA."
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($prodBaseline)) {
        if ((Compare-SemVer $currentVersion $prodBaseline) -le 0) {
            Add-Message -Payload $payload -Status "error" `
                -Message "La versión $currentVersion no es estrictamente mayor que la última publicada a Production ($prodBaseline). ValidatePublishVersion va a rechazar el publish. Puede que esta versión ya se haya desplegado."
        }
    }
}

$ok = ($payload.validation.status -ne "error")
Emit-Result -Ok $ok -Payload $payload
