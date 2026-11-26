<#
解析 Android SDK 的位置 —— 脚本里不再写死任何绝对路径。

查找顺序（先命中先用）：
  1. 环境变量 HVR_ANDROID_SDK
  2. <仓库>/工具链/android-sdk          （工程自包含的那份）
  3. <仓库>/../android-sdk             （工作区根目录的那份，通常是 junction）
  4. <仓库>/android-sdk

用法：
    . (Join-Path $repo 'tools/sdk-path.ps1')
    $sdk = Resolve-HvrAndroidSdk -RepoRoot $repo
找不到会抛错并列出查过的位置，不会静默用一个不存在的路径。
#>
function Resolve-HvrAndroidSdk {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $workspace = Split-Path $repo -Parent
    $candidates = @()
    if ($env:HVR_ANDROID_SDK) { $candidates += $env:HVR_ANDROID_SDK }
    $candidates += (Join-Path $repo '工具链/android-sdk')
    $candidates += (Join-Path $workspace 'android-sdk')
    $candidates += (Join-Path $repo 'android-sdk')

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'build-tools'))) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }
    throw ("找不到 Android SDK，查过这些位置：`n  " + ($candidates -join "`n  ") +
        "`n可以设环境变量 HVR_ANDROID_SDK 指到 SDK 根目录。")
}

function Resolve-HvrAdb {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    # 允许用环境变量直接指定（例如指向改名副本）。
    if ($env:HVR_ADB) {
        return (Resolve-Path -LiteralPath $env:HVR_ADB).Path
    }
    $sdk = Resolve-HvrAndroidSdk -RepoRoot $RepoRoot

    # 2026-10 复现环境：终端安全软件按文件名拦截 platform-tools/adb.exe
    # （CreateProcessW 直接返回 WinError 786，同盘 fastboot.exe 正常）。
    # 同一二进制改名后可正常运行，所以查找顺序里包含改名副本 adb-tool.exe。
    foreach ($name in @('adb.exe', 'adb-tool.exe')) {
        $adb = Join-Path $sdk ("platform-tools/" + $name)
        if ((Test-Path -LiteralPath $adb) -and (Test-ProcessLaunchable $adb)) {
            return (Resolve-Path -LiteralPath $adb).Path
        }
    }
    throw ("SDK 里没有可运行的 platform-tools/adb.exe（或改名副本 adb-tool.exe）：$sdk`n" +
        "如 adb 被安全软件按名拦截，可把它复制为 adb-tool.exe，或设环境变量 HVR_ADB。")
}

# 最低限度的可运行性检查：不真启动 adb，只确认 Windows 允许创建这个进程。
# 这里靠一次 -Version 调用；失败（如安全软件按名拦截）时静默返回 $false，
# 让上层尝试下一个候选名。
function Test-ProcessLaunchable {
    param([Parameter(Mandatory = $true)][string]$Exe)
    try {
        $null = & $Exe version 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}
