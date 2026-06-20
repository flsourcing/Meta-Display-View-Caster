# Patch Team ID into View Caster IPA before sideloading (Meta AI needs this to match your signature).
# Usage: .\patch-ipa-teamid.ps1 -TeamId ABCDE12345 -Ipa ViewCasterRelay-unsigned.ipa

param(
    [Parameter(Mandatory = $true)]
    [string]$TeamId,
    [Parameter(Mandatory = $true)]
    [string]$Ipa
)

$Ipa = (Resolve-Path $Ipa).Path
$work = Join-Path $env:TEMP "vc-patch-$(Get-Random)"
New-Item -ItemType Directory -Path $work | Out-Null

try {
    $zip = Join-Path $work "in.zip"
    Copy-Item $Ipa $zip
    Expand-Archive -Path $zip -DestinationPath $work -Force

    $plistPath = Get-ChildItem -Path $work -Recurse -Filter "Info.plist" |
        Where-Object { $_.FullName -match "ViewCasterRelay\.app\\Info\.plist$" } |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $plistPath) { throw "Could not find ViewCasterRelay.app/Info.plist in IPA" }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { throw "Python required to edit binary plists. Install Python 3, then re-run." }

    $py = @"
import plistlib, sys
path, team = sys.argv[1], sys.argv[2]
with open(path, 'rb') as f:
    pl = plistlib.load(f)
mw = pl.setdefault('MWDAT', {})
mw['AppLinkURLScheme'] = 'viewcaster://'
mw['MetaAppID'] = '0'
mw.pop('ClientToken', None)
mw.pop('DAMEnabled', None)
mw['TeamID'] = team
with open(path, 'wb') as f:
    plistlib.dump(pl, f)
print('Patched MWDAT:', mw)
"@
    & python -c $py $plistPath $TeamId
    if ($LASTEXITCODE -ne 0) { throw "Python plist patch failed" }

    $payloadDir = Join-Path $work "Payload"
    $outBase = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($Ipa),
        [System.IO.Path]::GetFileNameWithoutExtension($Ipa) + "-patched"
    )
    $outZip = "$outBase.zip"
    $outIpa = "$outBase.ipa"
    if (Test-Path $outZip) { Remove-Item $outZip -Force }
    if (Test-Path $outIpa) { Remove-Item $outIpa -Force }

    Push-Location $work
    Compress-Archive -Path "Payload" -DestinationPath $outZip -Force
    Pop-Location
    Rename-Item $outZip $outIpa -Force

    Write-Host ""
    Write-Host "Patched IPA: $outIpa"
    Write-Host "Install that file with Sideloadly (not the original)."
} finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
