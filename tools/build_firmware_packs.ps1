param(
    [string]$BiosRoot = "C:\Users\carter\Downloads\bios",
    [string]$OutDir = "C:\Users\carter\Downloads\bios\finals",
    [string]$PlatformsJson = "C:\Users\carter\Documents\GitHub\kyodai\data\platforms.json"
)

$ErrorActionPreference = "Stop"

$packs = [ordered]@{
    "3do" = @(
        @{ Src = "panafz*.bin"; Dst = "" },
        @{ Src = "goldstar.bin"; Dst = "" },
        @{ Src = "sanyotry.bin"; Dst = "" },
        @{ Src = "3do_arcade_saot.bin"; Dst = "" }
    )
    "atomiswave" = @(
        @{ Src = "dc\*"; Dst = "dc"; Exclude = @("dc_nvmem.bin") }
    )
    "c64" = @(
        @{ Src = "vice\JiffyDOS_C64.bin"; Dst = "vice" },
        @{ Src = "vice\JiffyDOS_1541-II.bin"; Dst = "vice" },
        @{ Src = "vice\JiffyDOS_1571_repl310654.bin"; Dst = "vice" },
        @{ Src = "vice\JiffyDOS_1581.bin"; Dst = "vice" },
        @{ Src = "vice\JiffyDOS_C128.bin"; Dst = "vice" },
        @{ Src = "vice\JiffyDOS_SX-64.bin"; Dst = "vice" },
        @{ Src = "scpu-dos-1.4.bin"; Dst = "vice\SCPU64" },
        @{ Src = "scpu-dos-2.04.bin"; Dst = "vice\SCPU64" }
    )
    "dos" = @(
        @{ Src = "MT32_CONTROL.ROM"; Dst = "" },
        @{ Src = "MT32_PCM.ROM"; Dst = "" },
        @{ Src = "CM32L_CONTROL.ROM"; Dst = "" },
        @{ Src = "CM32L_PCM.ROM"; Dst = "" },
        @{ Src = "CM32LN_CONTROL.ROM"; Dst = "" }
    )
    "dc" = @(
        @{ Src = "dc\*"; Dst = "dc"; Exclude = @("dc_nvmem.bin") }
    )
    "fds" = @(
        @{ Src = "disksys.rom"; Dst = "" },
        @{ Src = "NstDatabase.xml"; Dst = "" }
    )
    "gb" = @(
        @{ Src = "gb_bios.bin"; Dst = "" },
        @{ Src = "dmg_boot.bin"; Dst = "" },
        @{ Src = "dmg_rom.bin"; Dst = "" },
        @{ Src = "cgb_boot.bin"; Dst = "" },
        @{ Src = "cgb_bios.bin"; Dst = "" }
    )
    "gba" = @(
        @{ Src = "gba_bios.bin"; Dst = "" },
        @{ Src = "agb_boot.bin"; Dst = "" }
    )
    "gbc" = @(
        @{ Src = "gbc_bios.bin"; Dst = "" },
        @{ Src = "cgb_boot.bin"; Dst = "" },
        @{ Src = "cgb_bios.bin"; Dst = "" }
    )
    "lynx" = @(
        @{ Src = "lynxboot.img"; Dst = "" }
    )
    "msx" = @(
        @{ Src = "Machines"; Dst = ""; Dir = $true },
        @{ Src = "Databases"; Dst = ""; Dir = $true },
        @{ Src = "MSX.ROM"; Dst = "" },
        @{ Src = "MSX2.ROM"; Dst = "" },
        @{ Src = "MSX2EXT.ROM"; Dst = "" },
        @{ Src = "MSX2P.ROM"; Dst = "" },
        @{ Src = "MSX2PEXT.ROM"; Dst = "" },
        @{ Src = "MSXDOS2.ROM"; Dst = "" },
        @{ Src = "DISK.ROM"; Dst = "" },
        @{ Src = "FMPAC.ROM"; Dst = "" },
        @{ Src = "FMPAC16.ROM"; Dst = "" },
        @{ Src = "KANJI.ROM"; Dst = "" },
        @{ Src = "PAINTER.ROM"; Dst = "" },
        @{ Src = "RS232.ROM"; Dst = "" }
    )
    "naomi" = @(
        @{ Src = "dc\*"; Dst = "dc"; Exclude = @("dc_nvmem.bin") }
    )
    "naomi2" = @(
        @{ Src = "dc\*"; Dst = "dc"; Exclude = @("dc_nvmem.bin") }
    )
    "nds" = @(
        @{ Src = "bios7.bin"; Dst = "" },
        @{ Src = "bios9.bin"; Dst = "" },
        @{ Src = "firmware.bin"; Dst = "" },
        @{ Src = "dsi_bios7.bin"; Dst = "" },
        @{ Src = "dsi_bios9.bin"; Dst = "" },
        @{ Src = "dsi_firmware.bin"; Dst = "" }
    )
    "psx" = @(
        @{ Src = "scph*.bin"; Dst = "" },
        @{ Src = "psxonpsp660.bin"; Dst = "" },
        @{ Src = "ps1_rom.bin"; Dst = "" },
        @{ Src = "openbios.bin"; Dst = "" }
    )
    "ps2" = @(
        @{ Src = "pcsx2\bios\ps2-02*.bin"; Dst = "bios" }
    )
    "saturn" = @(
        @{ Src = "saturn_bios.bin"; Dst = "" },
        @{ Src = "sega_100.bin"; Dst = "" },
        @{ Src = "sega_100a.bin"; Dst = "" },
        @{ Src = "sega_101.bin"; Dst = "" },
        @{ Src = "mpr-17933.bin"; Dst = "" },
        @{ Src = "mpr-18100.bin"; Dst = "" },
        @{ Src = "mpr-18811-mx.ic1"; Dst = "" },
        @{ Src = "mpr-19367-mx.ic1"; Dst = "" },
        @{ Src = "hisaturn.bin"; Dst = "" },
        @{ Src = "vsaturn.bin"; Dst = "" },
        @{ Src = "satar4mp.bin"; Dst = "" },
        @{ Src = "kronos\saturn_bios.bin"; Dst = "kronos" },
        @{ Src = "kronos\stvbios.zip"; Dst = "kronos" }
    )
    "segacd" = @(
        @{ Src = "bios_CD_U.bin"; Dst = "" },
        @{ Src = "bios_CD_E.bin"; Dst = "" },
        @{ Src = "bios_CD_J.bin"; Dst = "" },
        @{ Src = "us_scd1_9210.bin"; Dst = "" },
        @{ Src = "us_scd2_9306.bin"; Dst = "" },
        @{ Src = "eu_mcd1_9210.bin"; Dst = "" },
        @{ Src = "eu_mcd2_9303.bin"; Dst = "" },
        @{ Src = "eu_mcd2_9306.bin"; Dst = "" },
        @{ Src = "jp_mcd1_9111.bin"; Dst = "" },
        @{ Src = "jp_mcd1_9112.bin"; Dst = "" },
        @{ Src = "jp_mcd2_921222.bin"; Dst = "" },
        @{ Src = "SegaCDBIOS9303.bin"; Dst = "" }
    )
    "gamegear" = @(
        @{ Src = "bios.gg"; Dst = "" }
    )
    "sms" = @(
        @{ Src = "bios_U.sms"; Dst = "" },
        @{ Src = "bios_E.sms"; Dst = "" },
        @{ Src = "bios_J.sms"; Dst = "" },
        @{ Src = "bios.sms"; Dst = "" }
    )
    "genesis" = @(
        @{ Src = "bios_MD.bin"; Dst = "" },
        @{ Src = "sk.bin"; Dst = "" },
        @{ Src = "sk2chip.bin"; Dst = "" }
    )
    "snes" = @(
        @{ Src = "BS-X*.bin"; Dst = "" },
        @{ Src = "STBIOS.bin"; Dst = "" },
        @{ Src = "sgb.boot.rom"; Dst = "" },
        @{ Src = "dsp*.rom"; Dst = "" },
        @{ Src = "st0*.rom"; Dst = "" },
        @{ Src = "cx4.data.rom"; Dst = "" }
    )
    "tg16" = @(
        @{ Src = "syscard1.pce"; Dst = "" },
        @{ Src = "syscard2.pce"; Dst = "" },
        @{ Src = "syscard2u.pce"; Dst = "" },
        @{ Src = "syscard3.pce"; Dst = "" },
        @{ Src = "syscard3u.pce"; Dst = "" },
        @{ Src = "gexpress.pce"; Dst = "" },
        @{ Src = "gecard.pce"; Dst = "" }
    )
    "turbografx-cd" = @(
        @{ Src = "syscard1.pce"; Dst = "" },
        @{ Src = "syscard2.pce"; Dst = "" },
        @{ Src = "syscard2u.pce"; Dst = "" },
        @{ Src = "syscard3.pce"; Dst = "" },
        @{ Src = "syscard3u.pce"; Dst = "" },
        @{ Src = "gexpress.pce"; Dst = "" },
        @{ Src = "gecard.pce"; Dst = "" }
    )
    "win3x" = @(
        @{ Src = "MT32_CONTROL.ROM"; Dst = "" },
        @{ Src = "MT32_PCM.ROM"; Dst = "" },
        @{ Src = "CM32L_CONTROL.ROM"; Dst = "" },
        @{ Src = "CM32L_PCM.ROM"; Dst = "" },
        @{ Src = "CM32LN_CONTROL.ROM"; Dst = "" }
    )
}

$platforms = Get-Content -Raw $PlatformsJson | ConvertFrom-Json

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stageRoot = Join-Path $OutDir ".staging"
if (Test-Path $stageRoot) { Remove-Item -Recurse -Force $stageRoot }
New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null

$report = New-Object System.Collections.Generic.List[string]
$report.Add("KYODAI FIRMWARE PACK BUILD REPORT - $(Get-Date -Format 'yyyy-MM-dd HH:mm')")
$report.Add("Source: $BiosRoot")
$report.Add("")

foreach ($slug in $packs.Keys) {
    $stage = Join-Path $stageRoot $slug
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    $missing = New-Object System.Collections.Generic.List[string]
    $packed = 0

    foreach ($entry in $packs[$slug]) {
        $src = Join-Path $BiosRoot $entry.Src
        if ($entry.Dir) {
            if (Test-Path -LiteralPath $src) {
                $destDir = if ($entry.Dst) { Join-Path $stage $entry.Dst } else { $stage }
                Copy-Item -LiteralPath $src -Destination $destDir -Recurse -Force
                $packed++
            } else {
                $missing.Add($entry.Src)
            }
            continue
        }
        $hits = Get-ChildItem -Path $src -File -ErrorAction SilentlyContinue
        if (-not $hits) {
            $missing.Add($entry.Src)
            continue
        }
        foreach ($h in $hits) {
            if ($entry.Exclude -and ($entry.Exclude -contains $h.Name)) { continue }
            $destDir = if ($entry.Dst) { Join-Path $stage $entry.Dst } else { $stage }
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            Copy-Item -LiteralPath $h.FullName -Destination (Join-Path $destDir $h.Name) -Force
            $packed++
        }
    }

    $expected = @()
    $plat = $platforms.PSObject.Properties[$slug]
    if ($plat -and $plat.Value.firmware -and $plat.Value.firmware.expected_files) {
        $expected = @($plat.Value.firmware.expected_files)
    }
    $stagedFiles = Get-ChildItem -Recurse -File $stage | ForEach-Object { $_.FullName.Substring($stage.Length + 1).Replace('\', '/') }
    $unmet = New-Object System.Collections.Generic.List[string]
    foreach ($exp in $expected) {
        $found = $false
        foreach ($sf in $stagedFiles) {
            $leaf = Split-Path $sf -Leaf
            if ($sf -ieq $exp -or $leaf -ieq $exp -or $sf.EndsWith("/" + $exp)) { $found = $true; break }
        }
        if (-not $found) { $unmet.Add($exp) }
    }

    $zipPath = Join-Path $OutDir "$slug.zip"
    if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in (Get-ChildItem -Recurse -File $stage)) {
            $entryName = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
            $entry = $zip.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
            $es = $entry.Open()
            $fs = [System.IO.File]::OpenRead($f.FullName)
            $fs.CopyTo($es)
            $fs.Dispose()
            $es.Dispose()
        }
    } finally {
        $zip.Dispose()
    }
    $hash = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
    $size = (Get-Item $zipPath).Length

    $report.Add("=== $slug.zip ($size bytes, sha256: $hash) ===")
    foreach ($sf in $stagedFiles) { $report.Add("  + $sf") }
    if ($unmet.Count -gt 0) {
        foreach ($u in $unmet) { $report.Add("  ! UNMET expected_file: $u") }
    }
    if ($missing.Count -gt 0) {
        foreach ($m in $missing) { $report.Add("  ! MISSING source: $m") }
    }
    $report.Add("")
    Write-Output ("{0,-16} files={1,-4} unmet={2} missing={3}" -f $slug, $packed, $unmet.Count, $missing.Count)
}

Remove-Item -Recurse -Force $stageRoot

$report.Add("=== SKIPPED PLATFORMS / SHOPPING LIST ===")
$report.Add("switch : keys/prod.keys + keys/title.keys - console key dump (Lockpick_RCM), not in pack. Zip layout: keys/prod.keys, keys/title.keys")
$report.Add("ps3    : dev_flash comes from installing official PS3UPDAT.PUP inside RPCS3 (File > Install Firmware). Not a droppable BIOS file.")
$report.Add("psvita : vs0/vsh/shell/shell.self comes from Vita3K's firmware installer (official PUP). Not a droppable BIOS file.")
$report.Add("xbox   : Complex_4627.bin (MCPX boot ROM) MISSING from pack. mcpx_1.0.bin is present. Both needed by xemu -> zip layout: Complex_4627.bin, mcpx_1.0.bin at root.")
$report.Add("")
$report.Add("=== NOTES (from libretro per-core docs) ===")
$report.Add("ngc/wii: Dolphin IPL.bin (gc-ntsc-*.bin / gc-pal-*.bin) must live in the SAVES tree (saves/dolphin-emu/User/GC/<USA|EUR|JAP>/IPL.bin), NOT system/ - kyodai's pipeline extracts firmware to system, so these were intentionally not packed. Dolphin Sys folder comes from RetroArch's Core System Files Downloader.")
$report.Add("psp    : PPSSPP needs its assets folder (Core System Files Downloader), no BIOS. Optional original fonts go to system/PPSSPP/flash0/font.")
$report.Add("arcade/neogeoaes: fbneo reads neogeo.zip from the ROMS folder (or system/fbneo/), not a system firmware file - not packed.")
$report.Add("msx    : Machines/ + Databases/ trees packed for bluemsx (default core); *.ROM files cover fmsx.")
$report.Add("saturn : root files cover beetle_saturn (default) + yabasanshiro; kronos/ subfolder packed for kronos.")
$report.Add("c64    : JiffyDOS packed under vice/ per vice_x64 docs; SuperCPU kernals under vice/SCPU64/.")
$report.Add("ps2    : packed under bios/ (lands in system/pcsx2/bios/ via kyodai's per-core firmware dir).")

$reportPath = Join-Path $OutDir "REPORT.txt"
$report | Set-Content -Path $reportPath -Encoding UTF8
Write-Output ""
Write-Output "Report written to $reportPath"
