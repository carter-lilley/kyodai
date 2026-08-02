param(
    [Parameter(Position = 0)]
    [string]$Message
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$m3 = Join-Path $root 'addons\m3'

function Fail($msg) {
    Write-Host "sync-m3: $msg" -ForegroundColor Red
    exit 1
}

Push-Location $root
try {
    $branch = git -C $m3 symbolic-ref --short -q HEAD
    if ($branch -ne 'main') {
        Write-Host "m3: switching from detached HEAD to main"
        git -C $m3 checkout main | Out-Null
    }

    git -C $m3 fetch origin main | Out-Null
    $counts = (git -C $m3 rev-list --left-right --count main...origin/main) -split '\s+'
    $ahead = [int]$counts[0]
    $behind = [int]$counts[1]

    if ($ahead -gt 0 -and $behind -gt 0) {
        Fail "m3 has diverged from origin/main. Run 'git -C addons\m3 pull --rebase' first."
    }
    if ($behind -gt 0) {
        Write-Host "m3: fast-forwarding $behind commit(s) from origin/main"
        git -C $m3 pull --ff-only | Out-Null
    }

    $dirty = git -C $m3 status --porcelain
    if ($dirty) {
        if (-not $Message) {
            $Message = Read-Host "m3 has uncommitted changes - commit message"
            if (-not $Message) { Fail "commit message required" }
        }
        git -C $m3 add -A
        git -C $m3 commit -q -m $Message
        Write-Host "m3: committed local changes ($Message)"
        $ahead = 1
    }

    if ($ahead -gt 0) {
        git -C $m3 push origin main
        Write-Host "m3: pushed to M3Godot"
    } elseif (-not $dirty) {
        Write-Host "m3: nothing to commit or push"
    }

    $pointerChanged = git status --porcelain -- addons/m3
    if ($pointerChanged) {
        $bumpMsg = if ($Message) { "m3: $Message" } else { "m3: update submodule" }
        git add addons/m3
        git commit -q -m $bumpMsg
        Write-Host "kyodai: bumped m3 submodule pointer ($bumpMsg)"
        Write-Host "kyodai: run 'git push' when ready"
    } else {
        Write-Host "kyodai: pointer already up to date"
    }
}
finally {
    Pop-Location
}
