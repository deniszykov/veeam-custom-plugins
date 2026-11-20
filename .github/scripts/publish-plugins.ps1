<#
.SYNOPSIS
    Builds every vspc-* plugin in the repository and publishes the resulting
    .nupkg files into the static NuGet feed under /repository using Sleet.

.DESCRIPTION
    Single source of truth for the CI pipeline; also runnable locally on Windows.

      .github\scripts\publish-plugins.ps1            # build + publish + commit + push
      .github\scripts\publish-plugins.ps1 -SkipTests
      .github\scripts\publish-plugins.ps1 -NoPush    # build + publish only, no git push

    Steps:
      1. Discover top-level vspc-* directories that contain source\build.ps1.
      2. Ensure the Veeam UIKit tarballs are present in each plugin's
         source\src\UI\vendor (see Resolve-UiSdk below).
      3. Run source\build.ps1 per plugin (runs unit tests by default and
         self-signs the .nupkg).
      4. Collect the built .nupkg files and push them into the Sleet local feed
         defined in sleet.json (writes to /repository).
      5. Commit the feed and push it to origin/main, resolving any concurrent
         feed change in our favor ("resolve conflicts in our side").
#>
[CmdletBinding()]
param(
    [switch]$SkipTests,
    [switch]$NoPush
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Split-Path -Parent (Split-Path -Parent $scriptDir)
Set-Location $repoRoot

$SleetVersion = '7.2.0'

function Resolve-UiSdk {
    param(
        [string]$PluginDir,
        [string]$PluginName
    )

    $vendor     = Join-Path $PluginDir 'source\src\UI\vendor'
    $packageJson = Join-Path $PluginDir 'source\src\UI\package.json'

    if (-not (Test-Path $packageJson)) {
        # Plugin has no webpack UI build; nothing to resolve.
        return
    }

    $pkg = Get-Content $packageJson -Raw | ConvertFrom-Json

    $fileRefs = @()
    foreach ($section in @('dependencies', 'devDependencies')) {
        if ($pkg.$section) {
            $fileRefs += @(
                $pkg.$section.PSObject.Properties |
                    Where-Object { $_.Value -like 'file:vendor/*' } |
                    ForEach-Object { $_.Value -replace '^file:vendor/', '' }
            )
        }
    }
    $fileRefs = @($fileRefs | Sort-Object -Unique)
    if ($fileRefs.Count -eq 0) {
        return
    }

    $missing = @($fileRefs | Where-Object { -not (Test-Path (Join-Path $vendor $_)) })
    if ($missing.Count -eq 0) {
        return
    }

    # The VSPC SDK tarballs are not redistributed. Support a gitignored local
    # stash folder (npm_packages/) so local builds can find them without
    # committing them. In CI this is the seam where a download step should be
    # wired once a private storage location exists.
    $stash = Join-Path $repoRoot 'npm_packages'
    if (Test-Path $stash) {
        New-Item -ItemType Directory -Force $vendor | Out-Null
        foreach ($file in $missing) {
            $src = Join-Path $stash $file
            if (Test-Path $src) {
                Copy-Item $src (Join-Path $vendor $file) -Force
            }
        }
    }

    $stillMissing = @($fileRefs | Where-Object { -not (Test-Path (Join-Path $vendor $_)) })
    if ($stillMissing.Count -gt 0) {
        $msg  = "Veeam UIKit tarballs missing for '{0}': {1}`n" -f $PluginName, ($stillMissing -join ', ')
        $msg += "They come from the VSPC plugin SDK (Veeam KB4311) and are not redistributed.`n"
        $msg += "Place them in '{0}' or in a gitignored 'npm_packages' folder at the repo root,`n" -f $vendor
        $msg += "or wire a download step in Resolve-UiSdk before the CI build."
        throw $msg
    }
}

# --- Discover plugins -------------------------------------------------------
$plugins = @(
    Get-ChildItem -Directory $repoRoot |
        Where-Object { $_.Name -like 'vspc-*' -and (Test-Path (Join-Path $_.FullName 'source\build.ps1')) }
)
if ($plugins.Count -eq 0) {
    throw "No plugins found under '$repoRoot' matching 'vspc-*' with a source\build.ps1."
}

# --- Staging directory for the built packages ------------------------------
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$staging  = Join-Path $tempRoot ('vspc-nupkgs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $staging | Out-Null

# --- Build each plugin ------------------------------------------------------
foreach ($plugin in $plugins) {
    $name = $plugin.Name
    Write-Host ''
    Write-Host ("===== Building {0} =====" -f $name)

    Resolve-UiSdk -PluginDir $plugin.FullName -PluginName $name

    $buildScript = Join-Path $plugin.FullName 'source\build.ps1'
    $buildParams = @{}
    if ($SkipTests) { $buildParams['SkipTests'] = $true }

    & $buildScript @buildParams
    if ($LASTEXITCODE -ne 0) {
        throw ("build.ps1 failed for '{0}' (exit code {1})." -f $name, $LASTEXITCODE)
    }

    $buildOut = Join-Path $plugin.FullName 'source\build'
    $built    = @(Get-ChildItem $buildOut -Filter '*.nupkg' -ErrorAction SilentlyContinue)
    if ($built.Count -eq 0) {
        throw ("build.ps1 produced no .nupkg in '{0}'." -f $buildOut)
    }
    foreach ($nupkg in $built) {
        Copy-Item $nupkg.FullName (Join-Path $staging $nupkg.Name) -Force
        Write-Host ("  collected {0} ({1:N1} MB)" -f $nupkg.Name, ($nupkg.Length / 1MB))
    }
}

# --- Install Sleet ----------------------------------------------------------
$toolDir = Join-Path $tempRoot ('sleet-tool-' + $SleetVersion)
$sleet   = Join-Path $toolDir 'sleet.exe'
if (-not (Test-Path $sleet)) {
    dotnet tool install Sleet --tool-path $toolDir --version $SleetVersion
    if ($LASTEXITCODE -ne 0) { throw 'Failed to install the Sleet tool.' }
}

# --- Publish the packages into the static feed (/repository) ---------------
$config = Join-Path $repoRoot 'sleet.json'
if (-not (Test-Path $config)) {
    throw "sleet.json not found at '$config'."
}

& $sleet push $staging --config $config --source repository --skip-existing
if ($LASTEXITCODE -ne 0) { throw 'sleet push failed.' }

# --- Commit and push the feed ----------------------------------------------
if ($NoPush) {
    Write-Host 'NoPush specified: skipping git commit and push.'
    return
}

git config user.name  'github-actions[bot]'
git config user.email '41898282+github-actions[bot]@users.noreply.github.com'

git add -- repository sleet.json
$staged = git status --porcelain -- repository sleet.json
if (-not $staged) {
    Write-Host 'No feed changes to commit (all packages are already published).'
    return
}

git commit -m 'chore(repository): publish plugin packages [skip ci]'
if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }

$pushed = $false
for ($attempt = 1; $attempt -le 5 -and -not $pushed; $attempt++) {
    git fetch origin
    if ($LASTEXITCODE -ne 0) { throw 'git fetch failed.' }

    # Resolve any concurrent change in /repository in our favor: the feed we
    # just regenerated from the current source is authoritative.
    git merge origin/main -X ours --no-edit
    if ($LASTEXITCODE -ne 0) { throw 'git merge failed.' }

    git push origin main
    if ($LASTEXITCODE -eq 0) {
        $pushed = $true
    }
    else {
        Write-Warning ("Push rejected; retrying ({0}/5)..." -f $attempt)
        Start-Sleep -Seconds 3
    }
}

if (-not $pushed) {
    throw 'Failed to push the /repository feed to origin/main after 5 attempts.'
}

Write-Host 'Published packages to the /repository feed and pushed to origin/main.'
