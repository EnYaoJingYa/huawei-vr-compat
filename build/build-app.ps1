<#
Builds a from-source app module (currently: shell/ = the VR app, package com.hvr.shell).

    <module>/AndroidManifest.xml + <module>/res + <module>/java
      -> aapt2 compile / link（清单 + 资源 + R.java）
      -> javac（-source 8 -target 8，classpath 只有 android.jar）
      -> d8（classes.dex）
      -> 注入骨架 APK
      -> zipalign + apksigner（与仓库同一把 signing/hvr-compat-debug.jks）

为什么不用 Gradle：仓库现有构建链是 javac + d8 + apktool，没有 Gradle 依赖；
这套应用只用平台 API，不需要任何第三方库，一条命令就能出包。

用法：
    .\build\build-app.ps1                                  # 默认 shell / r1
    .\build\build-app.ps1 -Module shell -Revision r3
    .\build\build-app.ps1 -Module shell -Sdk F:\Tools\AndroidSDK -Jdk F:\Tools\jdk17
#>
param(
    [string]$Module = 'shell',
    [string]$Revision = 'r1',
    [string]$Sdk,
    [string]$Jdk
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$source = Join-Path $repo $Module
if (!(Test-Path -LiteralPath (Join-Path $source 'AndroidManifest.xml'))) {
    throw "模块不存在或缺少清单：$source"
}

. (Join-Path $repo 'tools/sdk-path.ps1')

if (-not $Sdk) {
    if ($env:HVR_ANDROID_SDK) { $Sdk = $env:HVR_ANDROID_SDK }
    else { $Sdk = Resolve-HvrAndroidSdk -RepoRoot $repo }
}
if (!(Test-Path -LiteralPath $Sdk)) { throw "SDK 不存在：$Sdk" }

if (-not $Jdk) {
    $jdkRoot = Join-Path $Sdk 'jdk17tmp'
    if (Test-Path -LiteralPath $jdkRoot) {
        $Jdk = (Get-ChildItem -LiteralPath $jdkRoot -Directory |
            Sort-Object Name -Descending | Select-Object -First 1).FullName
    } elseif ($env:JAVA_HOME) {
        $Jdk = $env:JAVA_HOME
    }
}
if (-not $Jdk -or !(Test-Path -LiteralPath (Join-Path $Jdk 'bin/javac.exe'))) {
    throw "找不到 JDK17（javac）。用 -Jdk 指定，或设 JAVA_HOME。"
}
$env:JAVA_HOME = $Jdk
$javac = Join-Path $Jdk 'bin/javac.exe'

# build-tools / platform 取现有最高版本，不写死 —— 复刻机上可能只有 34/30。
$btRoot = Join-Path $Sdk 'build-tools'
$bt = (Get-ChildItem -LiteralPath $btRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'aapt2.exe') } |
    Sort-Object { [version]($_.Name -replace '[^0-9.]', '') } -Descending |
    Select-Object -First 1).FullName
if (-not $bt) { throw "build-tools 里没有 aapt2.exe" }
$platform = (Get-ChildItem -LiteralPath (Join-Path $Sdk 'platforms') -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'android.jar') } |
    Sort-Object Name -Descending | Select-Object -First 1).FullName
if (-not $platform) { throw "platforms 里没有 android.jar" }
$androidJar = Join-Path $platform 'android.jar'

$aapt = Join-Path $bt 'aapt2.exe'
$zipalign = Join-Path $bt 'zipalign.exe'
$apksigner = Join-Path $bt 'apksigner.bat'
$d8 = Join-Path $bt 'd8.bat'
$keystore = Join-Path $repo 'signing/hvr-compat-debug.jks'

Write-Host "模块     : $Module"
Write-Host "SDK      : $Sdk"
Write-Host "JDK      : $Jdk"
Write-Host "build-tools: $(Split-Path $bt -Leaf)   platform: $(Split-Path $platform -Leaf)"

# aapt2 打不开中文路径：暂存目录放到工作区所在盘的根下。
$workspace = Split-Path $repo -Parent
$stageRoot = Join-Path ([System.IO.Path]::GetPathRoot($workspace)) '.hvrbuild'
$stage = Join-Path $stageRoot ("$Module-$Revision-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$resZip = Join-Path $stage 'res.zip'
$gen = Join-Path $stage 'gen'
$classes = Join-Path $stage 'classes'
$dexDir = Join-Path $stage 'dex'
$baseApk = Join-Path $stage 'base.apk'
$withDex = Join-Path $stage 'with-dex.apk'
$aligned = Join-Path $stage 'aligned.apk'
$outDir = Join-Path $repo 'build/out'
New-Item -ItemType Directory -Force -Path $stage, $gen, $classes, $dexDir, $outDir | Out-Null

function Invoke-Step([string]$name, [scriptblock]$body) {
    Write-Host "== $name"
    # PowerShell 5.1 会把原生命令写到 stderr 的正常提示（javac 的 "注:"、
    # aapt2 的进度）包成 NativeCommandError，配合 $ErrorActionPreference='Stop'
    # 就会在完全成功的情况下抛错。这里临时放开，用退出码判断成功与否。
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $body 2>&1 | ForEach-Object { Write-Host $_ }
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
        throw "$name 失败（exit $LASTEXITCODE）"
    }
}

Invoke-Step 'aapt2 编译资源' {
    & $aapt compile --dir (Join-Path $source 'res') -o $resZip
}

Invoke-Step 'aapt2 链接' {
    & $aapt link -o $baseApk `
        -I $androidJar `
        --manifest (Join-Path $source 'AndroidManifest.xml') `
        -R $resZip `
        --java $gen `
        --auto-add-overlay
}

$sources = @()
$sources += Get-ChildItem -LiteralPath (Join-Path $source 'java') -Recurse -Filter '*.java' |
    ForEach-Object { $_.FullName }
$sources += Get-ChildItem -LiteralPath $gen -Recurse -Filter '*.java' |
    ForEach-Object { $_.FullName }
Write-Host "源码 $($sources.Count) 个"

Invoke-Step 'javac' {
    & $javac -nowarn -encoding UTF-8 -source 8 -target 8 `
        -classpath $androidJar -d $classes $sources
}

$classFiles = Get-ChildItem -LiteralPath $classes -Recurse -Filter '*.class' |
    ForEach-Object { $_.FullName }
$d8Args = Join-Path $stage 'd8-args.txt'
$d8Lines = @(
    '--lib', $androidJar,
    '--min-api', '26',
    '--output', $dexDir
) + $classFiles
# d8 的 argfile 不认引号（会把引号当成路径的第一个字符），所以路径一律裸写。
# 暂存目录在盘根下的 ASCII 路径里，本来就没有空格。
[System.IO.File]::WriteAllLines($d8Args, $d8Lines, (New-Object System.Text.UTF8Encoding($false)))

Invoke-Step 'd8' { & $d8 "@$d8Args" }
$dex = Join-Path $dexDir 'classes.dex'
if (!(Test-Path -LiteralPath $dex)) { throw 'd8 没有产出 classes.dex' }

Invoke-Step '注入 dex' {
    Copy-Item -LiteralPath $baseApk -Destination $withDex -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($withDex, 'Update')
    try {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $dex, 'classes.dex',
            [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
    } finally {
        $zip.Dispose()
    }
}

Invoke-Step '对齐' { & $zipalign -f -p 4 $withDex $aligned }

$packageName = (& $aapt dump packagename $baseApk | Select-Object -First 1).Trim()
if (-not $packageName) { throw '读不出包名' }
$out = Join-Path $outDir "$packageName-$Revision.apk"

Invoke-Step '签名' {
    & $apksigner sign --ks $keystore --ks-key-alias hvrcompat `
        --ks-pass pass:android --key-pass pass:android `
        --out $out $aligned
}
Invoke-Step '验签' { & $apksigner verify $out }

$manifestXml = (& $aapt dump xmltree --file AndroidManifest.xml $out) -join "`n"
# 清单里组件名写的是相对形式（.ShellService），aapt2 不会补全包名，
# 所以断言只比对类名。
foreach ($needle in @('ShellService', 'BootReceiver', 'UsbAttachReceiver', 'MirrorService')) {
    if ($manifestXml -notmatch [regex]::Escape($needle)) {
        throw "清单里缺少：$needle"
    }
}

$size = [math]::Round((Get-Item -LiteralPath $out).Length / 1KB, 1)
Write-Host ""
Write-Host "OK  $out  ($size KB)"
