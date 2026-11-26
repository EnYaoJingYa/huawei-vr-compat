# ALVR APK 变体工具

`patch-alvr-apk.ps1` 用于对已有的 HuaweiVRGlass-ALVR APK 做：

- 二进制 `AndroidManifest.xml` 里的 `6dof` ↔ `3dof` 等长替换；
- `zipalign -p -f 4`；
- APK v1/v2/v3 重签；
- `apksigner verify` 和 SHA-256 输出。

它不是 ALVR 客户端构建器，也不包含 Huawei SDK、Loader、Bridge、`libalvr_client_openxr.so` 或官方签名密钥。

## 前置

- Windows PowerShell 5.1 或 7；
- Android SDK `build-tools`（含 `zipalign.exe`、`apksigner.bat`）；
- JDK 17（脚本会尝试 `%JAVA_HOME%` 或 `%ANDROID_HOME%\jdk17tmp\jbr`）；
- 一个已有 APK；
- 签名密钥库（默认 `signing/hvr-compat-debug.jks`，alias `hvrcompat`，口令 `android`）。

## 用法

### 1. 只改 Manifest 为 3DoF

适合「只用头部 3DoF，不要手柄按键」：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\alvr\patch-alvr-apk.ps1 `
  -BaseApk .\build\HuaweiVRGlass-ALVR-Android-v0.5.0.apk `
  -ManifestValue 3dof `
  -ExpectedSha256 EA8EA7DFE02D34B25AADACC13E456844E25BAD4528806FC8CBFF0853F22574DA
```

> 原版 `libalvr_client_openxr.so` 只绑定 `/interaction_profiles/huawei/6dof_controller`。改成 `3dof` 后 Runtime 对应 `/huawei/controller`，原版 .so 没有这个 profile，手柄按键/扳机会失效。要手柄就保留 `6dof` Manifest，用 Dashboard 的服务端 3DoF mode（该开关在附件源码的 Windows 构建里，官方 v0.5.0 Windows 包没有）。

### 2. 只重签，不改 Manifest

适合保留 6DoF Manifest、只换签名或替换原生库后重新打包：

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\alvr\patch-alvr-apk.ps1 `
  -BaseApk .\build\HuaweiVRGlass-ALVR-Android-v0.5.0.apk `
  -ManifestValue none
```

### 3. 自定义签名

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\alvr\patch-alvr-apk.ps1 `
  -BaseApk .\input.apk `
  -OutputApk .\build\output.apk `
  -ManifestValue 3dof `
  -Keystore .\signing\my-release.jks `
  -KeystoreAlias myalias `
  -KeystorePassword '***' `
  -KeyPassword '***'
```

### 4. 只对齐、不签名

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\alvr\patch-alvr-apk.ps1 `
  -BaseApk .\input.apk `
  -ManifestValue 3dof `
  -NoSign
```

## 参数

| 参数 | 说明 |
| --- | --- |
| `-BaseApk` | 输入 APK，必填 |
| `-OutputApk` | 输出路径；默认 `build/<原名>-<3dof/6dof/resigned>.apk` |
| `-ManifestValue` | `3dof`、`6dof` 或 `none`，默认 `3dof` |
| `-AndroidSdk` | Android SDK 根目录；默认 `%ANDROID_HOME%` 或 `U:\hvr\android-sdk` |
| `-JavaHome` | JDK 17 根目录；默认 `%JAVA_HOME%` 或 SDK 下的 `jdk17tmp\jbr` |
| `-Keystore` | 签名密钥库；默认 `signing/hvr-compat-debug.jks` |
| `-KeystoreAlias` | 默认 `hvrcompat` |
| `-KeystorePassword` / `-KeyPassword` | 默认 `android` |
| `-ExpectedSha256` | 校验输入 APK，不匹配直接失败 |
| `-NoSign` | 只做 Manifest 替换和 zipalign |

## 注意

- 重签后的 APK 与官方 APK 签名不同；手机上已装官方包时先卸载，不能直接覆盖安装。
- 需要覆盖官方包时必须使用官方签名密钥；本仓库不持有该密钥。
- 该脚本只改 Manifest 字符串，不做 native 代码/协议适配；不能把 6DoF 客户端变成真正的 6DoF 追踪，也不能修 Huawei Runtime 的 profile 限制。
- 官方发布包 SHA-256 见 [`docs/ALVR_HUAWEI_VR_GLASS.md`](../../docs/ALVR_HUAWEI_VR_GLASS.md)。
