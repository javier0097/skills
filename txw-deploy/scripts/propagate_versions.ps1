# propagate_versions.ps1
#
# Commitea los archivos de versión en la rama del deploy y los propaga hacia
# abajo por la cadena de backmerge definida en el config.
#
# Contexto: el publish se hace desde la rama del ambiente (staging para QA,
# master para PROD). Eso deja modificados dos archivos:
#   - version.props            -> editado a mano antes del publish (solo QA)
#   - published-versions.props  -> regenerado automáticamente por el publish
#
# Este script los commitea en la rama actual (que debe ser la del deploy),
# pushea, y después mergea esa rama hacia las ramas inferiores para que todas
# queden con los archivos de versión actualizados:
#
#   QA:    staging -> develop
#   PROD:  master  -> staging -> develop
#
# Cada merge se hace desde la rama anterior de la cadena, no siempre desde la
# rama del deploy. Así el backmerge arrastra también cualquier trabajo que ya
# viviera en la rama intermedia, en vez de saltearla.
#
# IMPORTANTE: este script debe correr DESPUÉS de que el zip esté validado.
# Si el publish falla, no querés haber pusheado una versión que no existe en
# ningún artefacto.
#
# Parámetros:
#   -ConfigPath    Ruta absoluta al config.json de la skill.
#   -Environment   "QA" o "PROD". Resuelve branches[<Environment>].
#   -Version       (Opcional) Número de versión, solo para el mensaje de commit.
#
# Salida: JSON.
# Exit code:
#   0  - ok=true. Incluye el caso "no había nada que commitear" (committed=false).
#   1  - ok=false. Conflicto de merge, push rechazado, rama equivocada, etc.

param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [ValidateSet("QA", "PROD")]
    [string]$Environment,

    [Parameter(Mandatory = $false)]
    [string]$Version = "",

    # Rutas ya resueltas por resolve_version_state.ps1. Si vienen vacías se usan
    # las del config. Pasarlas evita depender de que el config esté al día si
    # alguien movió los archivos de lugar.
    [Parameter(Mandatory = $false)]
    [string]$VersionsPropsPath = "",

    [Parameter(Mandatory = $false)]
    [string]$PublishedVersionsPropsPath = ""
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

$script:Steps = @()

function Emit-Result {
    param(
        [bool]$Ok,
        [bool]$Committed = $false,
        [string]$CommitSha = "",
        [array]$ChangedFiles = @(),
        [array]$PropagatedBranches = @(),
        [string]$ErrorMessage = $null
    )

    $result = @{
        ok                  = $Ok
        committed           = $Committed
        commit_sha          = $CommitSha
        changed_files       = $ChangedFiles
        propagated_branches = $PropagatedBranches
        steps               = $script:Steps
    }
    if ($ErrorMessage) {
        $result.error = $ErrorMessage
    }

    $json = $result | ConvertTo-Json -Depth 6 -Compress:$false
    Write-Output $json
    exit ($(if ($Ok) { 0 } else { 1 }))
}

function ConvertTo-NativeArgString {
    # Quoting según las reglas de CommandLineToArgvW (Windows). Solo se usa en
    # Windows PowerShell 5.1, donde ProcessStartInfo.ArgumentList no existe
    # (se agregó en .NET Core 2.1).
    param([string[]]$Arguments)

    $quoted = foreach ($arg in $Arguments) {
        if ($arg -eq "") {
            '""'
        }
        elseif ($arg -notmatch '[\s"]') {
            $arg
        }
        else {
            # Duplicar los backslashes que preceden a una comilla y escapar la comilla.
            $escaped = [regex]::Replace($arg, '(\\*)"', '$1$1\"')
            # Duplicar los backslashes finales, que quedarían pegados a la comilla de cierre.
            $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
            '"' + $escaped + '"'
        }
    }

    return ($quoted -join ' ')
}

function Invoke-Git {
    # Ejecuta git capturando stdout y stderr por separado.
    #
    # NO usar Start-Process -ArgumentList: une los argumentos con espacios SIN
    # entrecomillar los que contienen espacios, así que un mensaje de commit se
    # parte en tokens y git toma los sobrantes como pathspecs.
    #
    # NO usar `2>&1` en pipeline: en Windows PowerShell 5.1 convierte cualquier
    # escritura a stderr (incluso informativa) en NativeCommandError, que con
    # $ErrorActionPreference="Stop" aborta el script aunque git haya salido con 0.
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "git"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    if ($psi.PSObject.Properties.Name -contains "ArgumentList") {
        # PowerShell 7 / .NET Core: cada argumento se escapa por separado.
        foreach ($arg in $Arguments) { [void]$psi.ArgumentList.Add($arg) }
    }
    else {
        # Windows PowerShell 5.1: armamos la línea a mano con el quoting correcto.
        $psi.Arguments = ConvertTo-NativeArgString -Arguments $Arguments
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    try {
        [void]$proc.Start()

        # Leemos de forma asíncrona ANTES del WaitForExit: si el buffer de un pipe
        # se llena (un `git diff` grande, por ejemplo) y nadie lo drena, el proceso
        # queda bloqueado y WaitForExit no vuelve nunca.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $proc.WaitForExit()

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Stdout   = if ($null -eq $stdout) { "" } else { $stdout }
            Stderr   = if ($null -eq $stderr) { "" } else { $stderr }
        }
    }
    finally {
        $proc.Dispose()
    }
}

function Add-Step {
    param([string]$Message)
    $script:Steps += $Message
}

function Restore-DeployBranch {
    param([string]$Branch)
    # Best effort: volver a la rama del deploy para dejar el repo en un estado
    # predecible aunque algo haya fallado a mitad de camino.
    Invoke-Git -Arguments @("checkout", $Branch) | Out-Null
}

# ----------------------------------------------------------------------------
# Paso 0: Leer config
# ----------------------------------------------------------------------------

if (-not (Test-Path $ConfigPath)) {
    Emit-Result -Ok $false -ErrorMessage "No se encontró el config.json en '$ConfigPath'."
}

try {
    $config = Get-Content $ConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Emit-Result -Ok $false -ErrorMessage "No se pudo parsear config.json: $($_.Exception.Message)"
}

$branchConfig = $config.branches.$Environment
if (-not $branchConfig) {
    Emit-Result -Ok $false -ErrorMessage "config.branches.$Environment no existe en el config.json."
}

$DeployBranch = [string]$branchConfig.target
$BackmergeChain = @($branchConfig.backmerge_chain)

if (-not $DeployBranch) {
    Emit-Result -Ok $false -ErrorMessage "config.branches.$Environment.target está vacío."
}

$versionFilesConfig = $config.version_files

# Preferimos las rutas que ya resolvió resolve_version_state.ps1; el config es
# el fallback.
$VersionFiles = @()

if (-not [string]::IsNullOrWhiteSpace($VersionsPropsPath)) {
    $VersionFiles += $VersionsPropsPath
}
elseif ($versionFilesConfig -and $versionFilesConfig.versions_props) {
    $VersionFiles += [string]$versionFilesConfig.versions_props
}

if (-not [string]::IsNullOrWhiteSpace($PublishedVersionsPropsPath)) {
    $VersionFiles += $PublishedVersionsPropsPath
}
elseif ($versionFilesConfig -and $versionFilesConfig.published_versions_props) {
    $VersionFiles += [string]$versionFilesConfig.published_versions_props
}

if ($VersionFiles.Count -eq 0) {
    Emit-Result -Ok $false -ErrorMessage "No se recibió ninguna ruta de archivo de versión (ni por parámetro ni en config.version_files)."
}

# ----------------------------------------------------------------------------
# Paso 1: Validar que estamos parados en la rama del deploy
# ----------------------------------------------------------------------------

$currentBranchResult = Invoke-Git -Arguments @("rev-parse", "--abbrev-ref", "HEAD")
if ($currentBranchResult.ExitCode -ne 0) {
    Emit-Result -Ok $false -ErrorMessage "No se pudo determinar la rama actual: $($currentBranchResult.Stderr.Trim())"
}

$currentBranch = $currentBranchResult.Stdout.Trim()
if ($currentBranch -ne $DeployBranch) {
    Emit-Result -Ok $false `
        -ErrorMessage "Se esperaba estar en la rama '$DeployBranch' (rama del deploy a $Environment) pero el repo está en '$currentBranch'. No se commiteó nada."
}

Add-Step "Rama actual verificada: $DeployBranch"

# ----------------------------------------------------------------------------
# Paso 2: Stagear los archivos de versión y ver si hay algo que commitear
#
# En QA siempre debería haber cambios (version.props editado a mano +
# published-versions.props regenerado). En PROD normalmente cambia solo
# published-versions.props. Igual contemplamos el caso de que no haya nada:
# si el publish no tocó ningún archivo de versión, no hay nada que propagar
# y salimos ok sin hacer commits vacíos ni merges innecesarios.
# ----------------------------------------------------------------------------

$existingFiles = @()
foreach ($vf in $VersionFiles) {
    if (Test-Path $vf) {
        $existingFiles += $vf
    }
    else {
        Add-Step "AVISO: no se encontró '$vf' en el repo (se ignora)."
    }
}

if ($existingFiles.Count -eq 0) {
    Emit-Result -Ok $false `
        -ErrorMessage "Ninguno de los archivos de versión configurados existe en el repo: $($VersionFiles -join ', '). Revisá config.version_files."
}

$addResult = Invoke-Git -Arguments (@("add", "--") + $existingFiles)
if ($addResult.ExitCode -ne 0) {
    Emit-Result -Ok $false -ErrorMessage "git add falló: $($addResult.Stderr.Trim())"
}

$stagedResult = Invoke-Git -Arguments (@("diff", "--cached", "--name-only", "--") + $existingFiles)
$stagedFiles = @()
if (-not [string]::IsNullOrWhiteSpace($stagedResult.Stdout)) {
    $stagedFiles = $stagedResult.Stdout -split "`n" `
    | ForEach-Object { $_.Trim() } `
    | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

if ($stagedFiles.Count -eq 0) {
    Add-Step "No hubo cambios en los archivos de versión. Nada que commitear ni propagar."
    Emit-Result -Ok $true -Committed $false -ChangedFiles @() -PropagatedBranches @()
}

Add-Step "Archivos de versión con cambios: $($stagedFiles -join ', ')"

# ----------------------------------------------------------------------------
# Paso 3: Commit en la rama del deploy
# ----------------------------------------------------------------------------

$versionLabel = if ([string]::IsNullOrWhiteSpace($Version)) { "" } else { " $Version" }
$commitMessage = "chore(version): update version files after$versionLabel deploy to $Environment"

# Acotamos el commit a los archivos de versión con `-- <paths>`: si por lo que
# fuera quedó algo más staged, no se cuela en este commit.
$commitResult = Invoke-Git -Arguments (@("commit", "-m", $commitMessage, "--") + $existingFiles)
if ($commitResult.ExitCode -ne 0) {
    Emit-Result -Ok $false -ErrorMessage "git commit falló: $($commitResult.Stderr.Trim())$($commitResult.Stdout.Trim())"
}

$shaResult = Invoke-Git -Arguments @("rev-parse", "--short", "HEAD")
$commitSha = if ($shaResult.ExitCode -eq 0) { $shaResult.Stdout.Trim() } else { "" }

Add-Step "Commit creado en $($DeployBranch): $commitSha"

# ----------------------------------------------------------------------------
# Paso 4: Push de la rama del deploy
#
# Si el push se rechaza (alguien pusheó mientras corría el deploy), abortamos
# ANTES de tocar las demás ramas. El commit queda local y el usuario resuelve.
# ----------------------------------------------------------------------------

$pushResult = Invoke-Git -Arguments @("push", "origin", $DeployBranch)
if ($pushResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -Committed $true `
        -CommitSha $commitSha `
        -ChangedFiles $stagedFiles `
        -ErrorMessage "El commit de versiones se creó en '$DeployBranch' pero el push falló: $($pushResult.Stderr.Trim()). El commit quedó local; resolvé el push a mano y volvé a correr la propagación."
}

Add-Step "Push a origin/$DeployBranch OK"

# ----------------------------------------------------------------------------
# Paso 5: Backmerge por la cadena
#
# Cada rama de la cadena se mergea desde la ANTERIOR, no siempre desde la rama
# del deploy. Para PROD: master -> staging, y después staging -> develop.
# ----------------------------------------------------------------------------

$propagated = @()
$previousBranch = $DeployBranch

foreach ($branch in $BackmergeChain) {

    $fetchResult = Invoke-Git -Arguments @("fetch", "origin", $branch, "--quiet")
    if ($fetchResult.ExitCode -ne 0) {
        Restore-DeployBranch -Branch $DeployBranch
        Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
            -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
            -ErrorMessage "git fetch de '$branch' falló: $($fetchResult.Stderr.Trim())"
    }

    $branchExists = Invoke-Git -Arguments @("show-ref", "--verify", "--quiet", "refs/heads/$branch")
    if ($branchExists.ExitCode -ne 0) {
        $createResult = Invoke-Git -Arguments @("checkout", "-b", $branch, "origin/$branch")
        if ($createResult.ExitCode -ne 0) {
            Restore-DeployBranch -Branch $DeployBranch
            Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
                -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
                -ErrorMessage "No se pudo crear la rama local '$branch': $($createResult.Stderr.Trim())"
        }
    }
    else {
        $checkoutResult = Invoke-Git -Arguments @("checkout", $branch)
        if ($checkoutResult.ExitCode -ne 0) {
            Restore-DeployBranch -Branch $DeployBranch
            Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
                -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
                -ErrorMessage "git checkout $branch falló: $($checkoutResult.Stderr.Trim())"
        }

        # Traer lo remoto antes de mergear. Si la local divergió, abortamos:
        # resolverlo automáticamente sería adivinar.
        $pullResult = Invoke-Git -Arguments @("pull", "--ff-only", "origin", $branch)
        if ($pullResult.ExitCode -ne 0) {
            Restore-DeployBranch -Branch $DeployBranch
            Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
                -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
                -ErrorMessage "La rama local '$branch' no se pudo actualizar con fast-forward (¿tiene commits locales sin pushear o divergió?). Resolvela a mano y volvé a correr la propagación. Detalle: $($pullResult.Stderr.Trim())"
        }
    }

    $mergeResult = Invoke-Git -Arguments @("merge", $previousBranch, "--no-edit")
    if ($mergeResult.ExitCode -ne 0) {
        # Dejar la rama limpia antes de salir.
        Invoke-Git -Arguments @("merge", "--abort") | Out-Null
        Restore-DeployBranch -Branch $DeployBranch
        Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
            -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
            -ErrorMessage "El merge de '$previousBranch' a '$branch' tuvo conflictos y se abortó. Las ramas ya propagadas ($($propagated -join ', ')) quedaron OK. Resolvé el merge a mano. Detalle: $($mergeResult.Stdout.Trim()) $($mergeResult.Stderr.Trim())"
    }

    $pushBranchResult = Invoke-Git -Arguments @("push", "origin", $branch)
    if ($pushBranchResult.ExitCode -ne 0) {
        Restore-DeployBranch -Branch $DeployBranch
        Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
            -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
            -ErrorMessage "El merge a '$branch' se hizo localmente pero el push falló: $($pushBranchResult.Stderr.Trim())"
    }

    $propagated += $branch
    Add-Step "Backmerge $previousBranch -> $branch OK (pusheado)"

    $previousBranch = $branch
}

# ----------------------------------------------------------------------------
# Paso 6: Volver a la rama del deploy
#
# Dejamos el repo parado en la rama que se deployó, que es lo que el usuario
# espera después de correr la skill.
# ----------------------------------------------------------------------------

$finalCheckout = Invoke-Git -Arguments @("checkout", $DeployBranch)
if ($finalCheckout.ExitCode -ne 0) {
    Emit-Result -Ok $false -Committed $true -CommitSha $commitSha `
        -ChangedFiles $stagedFiles -PropagatedBranches $propagated `
        -ErrorMessage "Todo se propagó bien, pero no se pudo volver a la rama '$DeployBranch': $($finalCheckout.Stderr.Trim())"
}

Add-Step "Repo devuelto a la rama $DeployBranch"

Emit-Result -Ok $true `
    -Committed $true `
    -CommitSha $commitSha `
    -ChangedFiles $stagedFiles `
    -PropagatedBranches $propagated
