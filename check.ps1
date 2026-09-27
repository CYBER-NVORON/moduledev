param(
    [ValidateSet(1, 2, 3)] [int] $Week = 3,
    [switch] $KeepStack,
    [string] $Distro
)

$ErrorActionPreference = 'Stop'
try {
    if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        throw 'WSL is required. Install a Linux distribution with Python 3.10+, Git, Bash and Docker Compose access.'
    }
    $distributionOutput = & wsl.exe --list --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Cannot list WSL distributions.' }
    # Windows PowerShell can retain NUL characters from WSL's UTF-16 output.
    $distributions = @($distributionOutput | ForEach-Object { ($_ -replace "`0", '').Trim() } |
        Where-Object { $_ -and $_ -notin @('docker-desktop', 'docker-desktop-data') })
    if (-not $Distro) {
        if ($distributions.Count -eq 0) {
            throw 'Install a Linux WSL distribution (for example Debian or Ubuntu) and enable its Docker Desktop WSL integration.'
        }
        if ($distributions.Count -gt 1) {
            throw "Choose a WSL distribution with -Distro. Available: $($distributions -join ', ')"
        }
        $Distro = $distributions[0]
    }
    if ($Distro -notin $distributions) {
        throw "Unknown or unsupported distribution '$Distro'. Available: $($distributions -join ', ')"
    }
    $wslArguments = @('--distribution', $Distro)
    & wsl.exe @wslArguments --exec sh -c 'command -v bash >/dev/null 2>&1'
    if ($LASTEXITCODE -ne 0) { throw "Bash is unavailable in '$Distro'. Install Bash there or select another -Distro." }
    $linuxRoot = & wsl.exe @wslArguments --exec wslpath -a -u $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve the solution path in WSL distribution '$Distro'." }
    Write-Host "Checker WSL distribution: $Distro"
    $checkerArguments = $wslArguments + @('--exec', 'bash', "$($linuxRoot.Trim())/check.sh", '--week', "$Week")
    if ($KeepStack) { $checkerArguments += '--keep-stack' }
    & wsl.exe @checkerArguments
    exit $LASTEXITCODE
}
catch {
    Write-Error -Message $_ -ErrorAction Continue
    exit 2
}
