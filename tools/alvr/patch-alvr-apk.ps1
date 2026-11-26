[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BaseApk,

    [string]$OutputApk,

    [ValidateSet('3dof', '6dof', 'none')]
    [string]$ManifestValue = '3dof',

    [string]$AndroidSdk,

    [string]$JavaHome,

    [string]$Keystore,

    [string]$KeystoreAlias = 'hvrcompat',

    [string]$KeystorePassword = 'android',

    [string]$KeyPassword = 'android',

    [string]$ExpectedSha256,

    [switch]$NoSign
)

$ErrorActionPreference = 'Stop'

function Resolve-FullPath([string]$Path, [string]$Base) {
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $Base $Path))
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Find-BuildTool([string]$SdkRoot, [string]$Name) {
    $buildTools = Join-Path $SdkRoot 'build-tools'
    if (-not (Test-Path -LiteralPath $buildTools -PathType Container)) {
        throw "Android build-tools not found: $buildTools"
    }
    $candidates = Get-ChildItem -LiteralPath $buildTools -Directory |
        Sort-Object { [version]($_.Name -replace '[^0-9.]', '') } -Descending
    foreach ($dir in $candidates) {
        $tool = Join-Path $dir.FullName $Name
        if (Test-Path -LiteralPath $tool -PathType Leaf) {
            return $tool
        }
    }
    throw "$Name not found under $buildTools"
}

function Copy-ZipEntry([System.IO.Compression.ZipArchiveEntry]$Entry, [System.IO.Compression.ZipArchive]$Output) {
    if ($Entry.FullName.EndsWith('/')) {
        return
    }
    $compression = [System.IO.Compression.CompressionLevel]::Optimal
    if ($Entry.Length -eq 0 -or $Entry.CompressedLength -eq $Entry.Length) {
        $compression = [System.IO.Compression.CompressionLevel]::NoCompression
    }
    $newEntry = $Output.CreateEntry($Entry.FullName, $compression)
    $newEntry.LastWriteTime = $Entry.LastWriteTime
    $inputStream = $Entry.Open()
    $outputStream = $newEntry.Open()
    try {
        $inputStream.CopyTo($outputStream)
    }
    finally {
        $outputStream.Dispose()
        $inputStream.Dispose()
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$basePath = Resolve-FullPath $BaseApk (Get-Location).Path
if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
    throw "Base APK not found: $basePath"
}

if ([string]::IsNullOrWhiteSpace($OutputApk)) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($basePath)
    $suffix = if ($ManifestValue -eq 'none') { 'resigned' } else { $ManifestValue }
    $OutputApk = Join-Path $repoRoot "build\$name-$suffix.apk"
}
$outputPath = Resolve-FullPath $OutputApk (Get-Location).Path
if ($outputPath -eq $basePath) {
    throw 'OutputApk must be different from BaseApk.'
}

if ($PSBoundParameters.ContainsKey('ExpectedSha256')) {
    $actualHash = Get-Sha256 $basePath
    if ($actualHash -ne $ExpectedSha256.ToUpperInvariant()) {
        throw "Base APK SHA-256 mismatch.`nExpected: $($ExpectedSha256.ToUpperInvariant())`nActual:   $actualHash"
    }
}

if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
        $AndroidSdk = $env:ANDROID_HOME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
        $AndroidSdk = $env:ANDROID_SDK_ROOT
    }
    elseif (Test-Path -LiteralPath 'U:\hvr\android-sdk' -PathType Container) {
        $AndroidSdk = 'U:\hvr\android-sdk'
    }
    else {
        throw 'Android SDK not found. Pass -AndroidSdk.'
    }
}
$AndroidSdk = Resolve-FullPath $AndroidSdk (Get-Location).Path

$zipalign = Find-BuildTool $AndroidSdk 'zipalign.exe'
$apksigner = Find-BuildTool $AndroidSdk 'apksigner.bat'

if ([string]::IsNullOrWhiteSpace($JavaHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
        $JavaHome = $env:JAVA_HOME
    }
    elseif (Test-Path -LiteralPath (Join-Path $AndroidSdk 'jdk17tmp\jbr') -PathType Container) {
        $JavaHome = Join-Path $AndroidSdk 'jdk17tmp\jbr'
    }
}
if (-not [string]::IsNullOrWhiteSpace($JavaHome)) {
    $env:JAVA_HOME = $JavaHome
    $env:Path = "$(Join-Path $JavaHome 'bin');$env:Path"
}

if (-not $NoSign) {
    if ([string]::IsNullOrWhiteSpace($Keystore)) {
        $Keystore = Join-Path $repoRoot 'signing\hvr-compat-debug.jks'
    }
    $Keystore = Resolve-FullPath $Keystore (Get-Location).Path
    if (-not (Test-Path -LiteralPath $Keystore -PathType Leaf)) {
        throw "Keystore not found: $Keystore"
    }
}

$outputDir = Split-Path -Parent $outputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir)) {
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("alvr-apk-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$unsignedAligned = Join-Path $tempRoot 'unsigned-aligned.apk'
$unsignedRaw = Join-Path $tempRoot 'unsigned-raw.apk'

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    Add-Type -AssemblyName System.IO.Compression

    $source = [System.IO.Compression.ZipFile]::OpenRead($basePath)
    try {
        $manifestEntry = $source.GetEntry('AndroidManifest.xml')
        if ($null -eq $manifestEntry) {
            throw 'AndroidManifest.xml not found in APK.'
        }

        $manifestBytes = $null
        if ($ManifestValue -ne 'none') {
            $stream = $manifestEntry.Open()
            try {
                $memory = New-Object System.IO.MemoryStream
                $stream.CopyTo($memory)
                $manifestBytes = $memory.ToArray()
            }
            finally {
                $stream.Dispose()
            }

            $sourceValue = if ($ManifestValue -eq '3dof') { '6dof' } else { '3dof' }
            $targetValue = $ManifestValue

            $asciiFrom = [System.Text.Encoding]::ASCII.GetBytes($sourceValue)
            $asciiTo = [System.Text.Encoding]::ASCII.GetBytes($targetValue)
            $utf16From = [System.Text.Encoding]::Unicode.GetBytes($sourceValue)
            $utf16To = [System.Text.Encoding]::Unicode.GetBytes($targetValue)

            $replacements = 0
            for ($i = 0; $i -le $manifestBytes.Length - $asciiFrom.Length; $i++) {
                $match = $true
                for ($j = 0; $j -lt $asciiFrom.Length; $j++) {
                    if ($manifestBytes[$i + $j] -ne $asciiFrom[$j]) {
                        $match = $false
                        break
                    }
                }
                if ($match) {
                    for ($j = 0; $j -lt $asciiTo.Length; $j++) {
                        $manifestBytes[$i + $j] = $asciiTo[$j]
                    }
                    $replacements++
                    $i += $asciiFrom.Length - 1
                }
            }
            for ($i = 0; $i -le $manifestBytes.Length - $utf16From.Length; $i++) {
                $match = $true
                for ($j = 0; $j -lt $utf16From.Length; $j++) {
                    if ($manifestBytes[$i + $j] -ne $utf16From[$j]) {
                        $match = $false
                        break
                    }
                }
                if ($match) {
                    for ($j = 0; $j -lt $utf16To.Length; $j++) {
                        $manifestBytes[$i + $j] = $utf16To[$j]
                    }
                    $replacements++
                    $i += $utf16From.Length - 1
                }
            }

            if ($replacements -eq 0) {
                throw "No '$sourceValue' found in AndroidManifest.xml; the APK may already be '$targetValue' or use a different manifest."
            }
            Write-Host "Manifest: $sourceValue -> $targetValue ($replacements replacement(s))"
        }
        else {
            Write-Host 'Manifest: unchanged'
        }

        $zipOutput = [System.IO.Compression.ZipFile]::Open($unsignedRaw, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $source.Entries) {
                if ($entry.FullName -match '^META-INF/.*\.(RSA|DSA|EC|SF|MF)$') {
                    continue
                }
                if ($entry.FullName -eq 'AndroidManifest.xml' -and $null -ne $manifestBytes) {
                    $newEntry = $zipOutput.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::NoCompression)
                    $newEntry.LastWriteTime = $entry.LastWriteTime
                    $outStream = $newEntry.Open()
                    try {
                        $outStream.Write($manifestBytes, 0, $manifestBytes.Length)
                    }
                    finally {
                        $outStream.Dispose()
                    }
                    continue
                }
                Copy-ZipEntry $entry $zipOutput
            }
        }
        finally {
            $zipOutput.Dispose()
        }
    }
    finally {
        $source.Dispose()
    }

    & $zipalign -p -f 4 $unsignedRaw $unsignedAligned
    if ($LASTEXITCODE -ne 0) {
        throw "zipalign failed with exit code $LASTEXITCODE"
    }

    if ($NoSign) {
        Copy-Item -LiteralPath $unsignedAligned -Destination $outputPath -Force
    }
    else {
        & $apksigner sign `
            --ks $Keystore `
            --ks-key-alias $KeystoreAlias `
            --ks-pass "pass:$KeystorePassword" `
            --key-pass "pass:$KeyPassword" `
            --v1-signing-enabled true `
            --v2-signing-enabled true `
            --v3-signing-enabled true `
            --out $outputPath `
            $unsignedAligned
        if ($LASTEXITCODE -ne 0) {
            throw "apksigner sign failed with exit code $LASTEXITCODE"
        }

        & $apksigner verify --verbose --print-certs $outputPath
        if ($LASTEXITCODE -ne 0) {
            throw "apksigner verify failed with exit code $LASTEXITCODE"
        }
    }

    $outputItem = Get-Item -LiteralPath $outputPath
    $outputHash = Get-Sha256 $outputPath
    Write-Host ''
    Write-Host "Output:  $outputPath"
    Write-Host "Size:    $($outputItem.Length) bytes"
    Write-Host "SHA-256: $outputHash"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
