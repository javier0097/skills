# check_deploy_readiness.ps1
# Valida que el repo esté en condiciones de hacer deploy:
#   1. Working directory limpio (ignora archivos en whitelist).
#   2. Rama objetivo existe localmente (si no, la crea desde origin).
#   3. Checkout de la rama objetivo.
#   4. Fetch de la rama objetivo y de las fuentes esperadas.
#   5. Sincronización local con origin/<target> usando fast-forward only.
#      - Si está al día: no-op.
#      - Si está atrasado y limpio: avanza con fast-forward.
#      - Si está adelantado o divergente: aborta con error.
#   6. Checks de propagación: cuenta y lista los commits que están en cada
#      rama fuente esperada pero no en la rama objetivo.
#
# El script ejecuta el checkout y el pull --ff-only por sí mismo. Los checks
# de propagación son informativos: NO abortan el script (queda a criterio de
# Claude mostrarlos y pedir confirmación al usuario).
#
# Parámetros:
#   -TargetBranch       Nombre de la rama objetivo (ej: "staging", "master").
#   -ExpectedSources    Array de nombres de ramas que deberían estar propagadas
#                       en la rama objetivo (ej: "develop","master" para QA;
#                       "staging" para PROD).
#   -Whitelist          Array de nombres de archivo cuyos cambios sin commitear
#                       se permiten (típicamente "appsettings.Development.json").
#
# Salida: JSON con la estructura documentada en SKILL.md.
# Exit code:
#   0  - ok=true. Repo en condiciones de deployar. Puede haber propagación
#        pendiente (Claude decide qué hacer con eso).
#   1  - ok=false. Algún problema bloqueante: working dir dirty, rama divergente,
#        commits locales sin pushear, o error de git.

param(
    [Parameter(Mandatory = $true)]
    [string]$TargetBranch,

    [Parameter(Mandatory = $true)]
    [string[]]$ExpectedSources,

    [Parameter(Mandatory = $false)]
    [string[]]$Whitelist = @()
)

$ErrorActionPreference = "Stop"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Emit-Result {
    param(
        [bool]$Ok,
        [hashtable]$WorkingDirectory,
        [hashtable]$LocalSync,
        [array]$Propagation,
        [string]$Error = $null
    )

    $result = @{
        ok                = $Ok
        working_directory = $WorkingDirectory
        local_sync        = $LocalSync
        propagation       = $Propagation
    }
    if ($Error) {
        $result.error = $Error
    }

    # Depth 6 alcanza para la estructura más anidada (propagation[].missing_commits[].sha).
    $json = $result | ConvertTo-Json -Depth 6 -Compress:$false
    Write-Output $json
    exit ($(if ($Ok) { 0 } else { 1 }))
}

function Invoke-Git {
    # Ejecuta git capturando stdout y stderr juntos pero SIN usar 2>&1 en pipeline,
    # para evitar el NativeCommandError en Windows PowerShell 5.1.
    # Usa Start-Process redirigiendo a archivos temporales.
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Args
    )

    $stdoutFile = [System.IO.Path]::GetTempFileName()
    $stderrFile = [System.IO.Path]::GetTempFileName()

    try {
        $proc = Start-Process -FilePath "git" `
            -ArgumentList $Args `
            -NoNewWindow `
            -Wait `
            -PassThru `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue

        return [PSCustomObject]@{
            ExitCode = $proc.ExitCode
            Stdout   = if ($null -eq $stdout) { "" } else { $stdout }
            Stderr   = if ($null -eq $stderr) { "" } else { $stderr }
        }
    }
    finally {
        Remove-Item $stdoutFile -ErrorAction SilentlyContinue
        Remove-Item $stderrFile -ErrorAction SilentlyContinue
    }
}

# ----------------------------------------------------------------------------
# Paso 1: Working directory limpio (ignora whitelist)
# ----------------------------------------------------------------------------

$statusResult = Invoke-Git -Args @("status", "--porcelain")
if ($statusResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "error"; files = @() } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "git status falló: $($statusResult.Stderr.Trim())"
}

$dirtyFiles = @()
if (-not [string]::IsNullOrWhiteSpace($statusResult.Stdout)) {
    $lines = $statusResult.Stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($line in $lines) {
        $fileName = $line.Substring(3).Trim()
        if ($fileName.StartsWith('"') -and $fileName.EndsWith('"')) {
            $fileName = $fileName.Substring(1, $fileName.Length - 2)
        }
        $baseName = Split-Path $fileName -Leaf

        $isWhitelisted = $false
        foreach ($allowed in $Whitelist) {
            if ($baseName -eq $allowed -or $fileName -eq $allowed) {
                $isWhitelisted = $true
                break
            }
        }
        if (-not $isWhitelisted) {
            $dirtyFiles += $fileName
        }
    }
}

if ($dirtyFiles.Count -gt 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory @{ status = "dirty"; files = $dirtyFiles } `
        -LocalSync @{ status = "not_checked"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "Hay archivos modificados sin commitear (fuera del whitelist). Hacé commit o stash antes de seguir."
}

$workingDirectory = @{ status = "clean"; files = @() }

# ----------------------------------------------------------------------------
# Paso 2: Fetch de todas las ramas relevantes (objetivo + fuentes)
# ----------------------------------------------------------------------------

$branchesToFetch = @($TargetBranch) + $ExpectedSources | Select-Object -Unique
$fetchArgs = @("fetch", "origin") + $branchesToFetch + @("--quiet")
$fetchResult = Invoke-Git -Args $fetchArgs
if ($fetchResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "git fetch falló: $($fetchResult.Stderr.Trim())"
}

# ----------------------------------------------------------------------------
# Paso 3: Asegurar que la rama objetivo existe localmente y hacer checkout
# ----------------------------------------------------------------------------

$branchExistsResult = Invoke-Git -Args @("show-ref", "--verify", "--quiet", "refs/heads/$TargetBranch")
if ($branchExistsResult.ExitCode -ne 0) {
    # No existe localmente: crearla trackeando origin/<target>
    $createResult = Invoke-Git -Args @("checkout", "-b", $TargetBranch, "origin/$TargetBranch")
    if ($createResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
            -Propagation @() `
            -Error "No se pudo crear la rama local '$TargetBranch' desde origin/$($TargetBranch): $($createResult.Stderr.Trim())"
    }
}
else {
    $checkoutResult = Invoke-Git -Args @("checkout", $TargetBranch)
    if ($checkoutResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
            -Propagation @() `
            -Error "git checkout $TargetBranch falló: $($checkoutResult.Stderr.Trim())"
    }
}

# ----------------------------------------------------------------------------
# Paso 4: Calcular sincronización local antes de pull
# ----------------------------------------------------------------------------

$aheadResult = Invoke-Git -Args @("rev-list", "--count", "origin/$TargetBranch..HEAD")
$behindResult = Invoke-Git -Args @("rev-list", "--count", "HEAD..origin/$TargetBranch")

if ($aheadResult.ExitCode -ne 0 -or $behindResult.ExitCode -ne 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "error"; ahead_count = 0; behind_count = 0 } `
        -Propagation @() `
        -Error "No se pudo calcular el estado de sincronización local."
}

$ahead = [int]($aheadResult.Stdout.Trim())
$behind = [int]($behindResult.Stdout.Trim())

# Caso 1: adelantado (commits locales sin pushear) -> abortar
if ($ahead -gt 0 -and $behind -eq 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "ahead"; ahead_count = $ahead; behind_count = 0 } `
        -Propagation @() `
        -Error "La rama local '$TargetBranch' tiene $ahead commit(s) que no están en origin/$TargetBranch. Hacé git push antes de deployar."
}

# Caso 2: divergente -> abortar
if ($ahead -gt 0 -and $behind -gt 0) {
    Emit-Result -Ok $false `
        -WorkingDirectory $workingDirectory `
        -LocalSync @{ status = "diverged"; ahead_count = $ahead; behind_count = $behind } `
        -Propagation @() `
        -Error "La rama local '$TargetBranch' divergió de origin/$TargetBranch ($ahead local, $behind remoto). Resolvé el merge/rebase antes de deployar."
}

# Caso 3: atrasado y limpio -> pull --ff-only
if ($behind -gt 0) {
    $pullResult = Invoke-Git -Args @("pull", "--ff-only", "origin", $TargetBranch)
    if ($pullResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync @{ status = "error"; ahead_count = 0; behind_count = $behind } `
            -Propagation @() `
            -Error "git pull --ff-only falló: $($pullResult.Stderr.Trim())"
    }
    $localSync = @{ status = "behind"; ahead_count = 0; behind_count = $behind }
}
else {
    # Caso 4: ya al día
    $localSync = @{ status = "ok"; ahead_count = 0; behind_count = 0 }
}

# ----------------------------------------------------------------------------
# Paso 5: Checks de propagación
# ----------------------------------------------------------------------------

$propagation = @()
foreach ($source in $ExpectedSources) {
    # Commits que están en origin/<source> pero no en origin/<target>
    $countResult = Invoke-Git -Args @("rev-list", "--count", "origin/$TargetBranch..origin/$source")
    if ($countResult.ExitCode -ne 0) {
        Emit-Result -Ok $false `
            -WorkingDirectory $workingDirectory `
            -LocalSync $localSync `
            -Propagation @() `
            -Error "No se pudo contar commits de origin/$source no propagados a origin/$($TargetBranch): $($countResult.Stderr.Trim())"
    }

    $missingCount = [int]($countResult.Stdout.Trim())
    $missingCommits = @()

    if ($missingCount -gt 0) {
        # Traer hasta 10 commits con sha corto y subject
        $logResult = Invoke-Git -Args @(
            "log",
            "origin/$TargetBranch..origin/$source",
            "--pretty=format:%h%x09%s",
            "-n", "10"
        )
        if ($logResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($logResult.Stdout)) {
            $lines = $logResult.Stdout -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            foreach ($line in $lines) {
                $parts = $line -split "`t", 2
                if ($parts.Length -eq 2) {
                    $missingCommits += @{
                        sha     = $parts[0].Trim()
                        message = $parts[1].Trim()
                    }
                }
            }
        }
    }

    $propagation += @{
        source          = $source
        missing_count   = $missingCount
        missing_commits = $missingCommits
    }
}

# ----------------------------------------------------------------------------
# Resultado final: ok=true (propagación pendiente NO bloquea acá)
# ----------------------------------------------------------------------------

Emit-Result -Ok $true `
    -WorkingDirectory $workingDirectory `
    -LocalSync $localSync `
    -Propagation $propagation
