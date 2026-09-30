# Installs the `fsp` binary (the fespalier code generator) on Windows, without needing Rust.
#
#   irm https://raw.githubusercontent.com/vaam-apps/fespalier/main/install.ps1 | iex
#
# Environment:
#   FSP_VERSION      release tag to install, e.g. v0.2.0 (default: latest release)
#   FSP_INSTALL_DIR  where to put fsp.exe (default: %LOCALAPPDATA%\fespalier\bin)
#   FSP_BASE_URL     where releases are downloaded from
#                    (default: https://github.com/vaam-apps/fespalier/releases/download)
#
# Works in Windows PowerShell 5.1 and PowerShell 7. Everything lives in one function so
# that piping the script into `iex` never closes your terminal on an error.

function Install-Fsp {
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version 2.0
    # Invoke-WebRequest's progress bar makes downloads many times slower in PowerShell 5.1.
    $ProgressPreference = 'SilentlyContinue'
    # PowerShell 5.1 defaults to TLS 1.0/1.1, which GitHub refuses.
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    $repo = 'vaam-apps/fespalier'
    $releasesUrl = "https://github.com/$repo/releases"
    $baseUrl = if ($env:FSP_BASE_URL) { $env:FSP_BASE_URL.TrimEnd('/') } else { "$releasesUrl/download" }

    # --- platform ---------------------------------------------------------------
    # $IsWindows only exists in PowerShell 6+; Windows PowerShell 5.1 is always Windows.
    if ((Test-Path variable:IsWindows) -and -not $IsWindows) {
        throw "install.ps1 is for Windows. On Linux and macOS use install.sh (see $releasesUrl)."
    }
    $arch = $null
    try { $arch = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { }
    if (-not $arch) {
        $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    }
    # Only an x64 build is published; Windows on ARM runs it under emulation.
    if ($arch -notin @('X64', 'AMD64', 'Arm64', 'ARM64')) {
        throw "unsupported architecture: $arch (supported: x64, arm64). Prebuilt binaries are listed at $releasesUrl; otherwise build from source with cargo."
    }
    $target = 'x86_64-pc-windows-msvc'
    $installDir = if ($env:FSP_INSTALL_DIR) { $env:FSP_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'fespalier\bin' }

    # --- version ----------------------------------------------------------------
    $version = $env:FSP_VERSION
    if (-not $version) {
        # /releases/latest redirects to /releases/tag/<tag>; the response URI is the final one.
        try {
            $request = [Net.HttpWebRequest]::Create("$releasesUrl/latest")
            $request.Method = 'GET'
            $request.UserAgent = 'fespalier-install'
            $response = $request.GetResponse()
            try { $latest = $response.ResponseUri.AbsoluteUri } finally { $response.Close() }
        } catch {
            throw "could not look up the latest release ($($_.Exception.Message)); set `$env:FSP_VERSION (e.g. v0.2.0)"
        }
        $version = ($latest -split '/')[-1]
        if ($version -notmatch '^v\d') {
            throw "could not determine the latest release (got '$version'); set `$env:FSP_VERSION (e.g. v0.2.0)"
        }
    }
    if (-not $version.StartsWith('v')) { $version = "v$version" }

    # --- download and verify ----------------------------------------------------
    $archive = "fsp-$target.zip"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("fsp-install-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "Installing fsp $version ($target)"
        $zipPath = Join-Path $tmp $archive
        $sumPath = "$zipPath.sha256"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$version/$archive" -OutFile $zipPath
        } catch {
            throw "could not download $baseUrl/$version/$archive (does release $version exist?): $($_.Exception.Message)"
        }
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$baseUrl/$version/$archive.sha256" -OutFile $sumPath
        } catch {
            throw "could not download $baseUrl/$version/$archive.sha256: $($_.Exception.Message)"
        }

        $expected = ((Get-Content -Raw -LiteralPath $sumPath).Trim() -split '\s+')[0].ToLowerInvariant()
        if (-not $expected) { throw "checksum file for $archive is empty" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
        if ($expected -ne $actual) {
            throw "checksum mismatch for ${archive}: expected $expected, got $actual"
        }

        # --- install --------------------------------------------------------------
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force
        $exe = Join-Path $tmp 'fsp.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw "could not find fsp.exe in $archive" }
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $installDir 'fsp.exe') -Force
    } finally {
        Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    }

    Write-Host "Installed $(Join-Path $installDir 'fsp.exe')"

    $onPath = @($env:PATH -split ';' | Where-Object { $_ }) | Where-Object { $_.TrimEnd('\') -ieq $installDir.TrimEnd('\') }
    if (-not $onPath) {
        Write-Host ''
        Write-Host "$installDir is not on your PATH. Add it for your user (then open a new terminal):"
        Write-Host "  [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ';$installDir', 'User')"
    }
}

Install-Fsp
