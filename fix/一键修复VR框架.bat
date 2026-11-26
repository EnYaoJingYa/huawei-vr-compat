@echo off
chcp 65001 >nul
setlocal
rem ==========================================================================
rem  一键修复 VR 框架 / 打通 VR 桌面链路（Windows 双击即可）
rem  用法：双击，或  一键修复VR框架.bat [设备序列号] [install^|check^|off^|rollback^|launcher]
rem
rem  四个最终补丁包（统一 hvr-compat 签名），各自解决一段真实根因：
rem    ① launcherx-full.apk  compat dex + 去空壳桩 + 恢复 runUpdate +
rem       HvrSdkBridge（统一 SetClass 类副本、vr_system 动态代理、真实 VRMode）
rem    ② vrservice-full.apk  ctx0 归位 + 定义 signature 级 VR 权限
rem    ③ hvrsdkserverapp-full.apk  组件归位 + 27 个 64 位库 +
rem       HvrStatePublisher 发布 vr_system_state
rem    ④ com.huawei.vrhandle-pose.apk  4 个 ELF32 姿态库 + extractNativeLibs
rem       + HvrPoseLibPath，修掉 helmetPoseStart() 无 native 实现导致的崩溃循环
rem
rem  不改开机脚本、不重启、不动系统分区；rollback 可一键装回四个原版基线。
rem  VRService / VrGlassWatchService 由启动 MainActivity 时系统自动带起，
rem  不再写死 su 10073/10070（重装后 uid 会变化）。
rem
rem  2026-11-05 真机验收：helmetPoseStart 执行、getHelmetPose 回传 launcherx、
rem  RenderModule "Init VR end"、无 UnsatisfiedLinkError / ApplicationQuit /
rem  VRPromptActivity，栈顶保持 com.huawei.vrlauncherx/.MainActivity。
rem  剩余阻塞：约 2 分钟后 ArvrRuntimeService ANR → ServiceTermActivity
rem  级联崩溃、No valid frame to display，见手册第 8 章。
rem ==========================================================================

set "SERIAL=%~1"
if "%SERIAL%"=="" set "SERIAL=192.168.43.133:5555"
set "ACTION=%~2"
if "%ACTION%"=="" set "ACTION=install"
set "HERE=%~dp0"
set "PATCH=%HERE%patches\vrdesktop"
set "L=%PATCH%\com.huawei.vrlauncherx-full.apk"
set "V=%PATCH%\com.huawei.vrservice-full.apk"
set "R=%PATCH%\com.huawei.hvrsdkserverapp-full.apk"
set "H=%PATCH%\com.huawei.vrhandle-pose.apk"
set "LB=%PATCH%\rollback-launcherx.apk"
set "VB=%PATCH%\rollback-vrservice.apk"
set "RB=%HERE%apks\com.huawei.hvrsdkserverapp.apk"
set "HB=%HERE%apks\com.huawei.vrhandle.apk"

set "ADBEXE="
if defined ADB if exist "%ADB%" set "ADBEXE=%ADB%"
if not defined ADBEXE if exist "D:\Tools\AndroidSDK\platform-tools\adb.exe" set "ADBEXE=D:\Tools\AndroidSDK\platform-tools\adb.exe"
if not defined ADBEXE if exist "F:\Tools\AndroidSDK\platform-tools\adb.exe" set "ADBEXE=F:\Tools\AndroidSDK\platform-tools\adb.exe"
if not defined ADBEXE if exist "C:\platform-tools\adb.exe" set "ADBEXE=C:\platform-tools\adb.exe"
if not defined ADBEXE (
    for /f "delims=" %%i in ('where adb 2^>nul') do if not defined ADBEXE set "ADBEXE=%%i"
)
if not defined ADBEXE (
    echo [FATAL] 找不到 adb.exe，请把 AndroidSDK\platform-tools 加进 PATH
    pause
    exit /b 1
)

echo [i] adb    = %ADBEXE%
echo [i] 设备   = %SERIAL%
echo [i] 动作   = %ACTION%
echo.

"%ADBEXE%" connect %SERIAL% >nul 2>&1
"%ADBEXE%" -s %SERIAL% wait-for-device >nul 2>&1
if errorlevel 1 (
    echo [FATAL] 设备连不上：检查盒子是否开机、无线 adb 是否已开启
    pause
    exit /b 1
)

if /i "%ACTION%"=="check" goto VERIFY
if /i "%ACTION%"=="off" goto OFF
if /i "%ACTION%"=="rollback" goto ROLLBACK
if /i "%ACTION%"=="launcher" goto LAUNCHER

:INSTALL
for %%f in ("%L%" "%V%" "%R%" "%H%") do if not exist %%f goto MISSING
echo [1/7] 安装 vrservice（ctx0 + 定义 VR 权限）...
call :INSTALLAPK com.huawei.vrservice "%V%" || goto FAIL
echo [2/7] 安装 hvrsdkserverapp（组件归位 + 64 位库 + vr_system_state，161MB 稍慢）...
call :INSTALLAPK com.huawei.hvrsdkserverapp "%R%" || goto FAIL
echo [3/7] 安装 launcherx（compat + 去桩 + runUpdate + HvrSdkBridge）...
call :INSTALLAPK com.huawei.vrlauncherx "%L%" || goto FAIL
echo [4/7] 安装 vrhandle（32 位姿态库 + HvrPoseLibPath）...
call :INSTALLAPK com.huawei.vrhandle "%H%" || goto FAIL
echo [5/7] 打开模拟辅助显示（让在位判定通过）...
"%ADBEXE%" -s %SERIAL% shell "settings put global overlay_display_devices 1920x1080/320"
echo [6/7] 启动 VR 桌面入口（.MainActivity，系统自动带起 VRService / Runtime）...
"%ADBEXE%" -s %SERIAL% shell "am start -W -n com.huawei.vrlauncherx/.MainActivity"
echo [7/7] 验收 ...
goto VERIFY

:OFF
echo [i] 关闭模拟辅助显示 ...
"%ADBEXE%" -s %SERIAL% shell "settings delete global overlay_display_devices"
goto VERIFY

:ROLLBACK
echo [1/5] 回退 vrservice ...
call :INSTALLAPK com.huawei.vrservice "%VB%" || goto FAIL
echo [2/5] 回退 hvrsdkserverapp ...
call :INSTALLAPK com.huawei.hvrsdkserverapp "%RB%" || goto FAIL
echo [3/5] 回退 launcherx ...
call :INSTALLAPK com.huawei.vrlauncherx "%LB%" || goto FAIL
echo [4/5] 回退 vrhandle（华为原签）...
call :INSTALLAPK com.huawei.vrhandle "%HB%" || goto FAIL
echo [5/5] 关闭模拟辅助显示 ...
"%ADBEXE%" -s %SERIAL% shell "settings delete global overlay_display_devices"
goto VERIFY

:LAUNCHER
"%ADBEXE%" -s %SERIAL% shell "am start -n com.huawei.vrlauncherx/.MainActivity"
goto VERIFY

:VERIFY
echo.
echo ===== 验收 =====
echo -- 各包 hvrcompat provider --
"%ADBEXE%" -s %SERIAL% shell "dumpsys package com.huawei.vrlauncherx | grep hvrcompat"
"%ADBEXE%" -s %SERIAL% shell "dumpsys package com.huawei.vrservice | grep hvrcompat"
echo -- runtime 64 位库数量（应为 30）--
for /f "delims=" %%i in ('"%ADBEXE%" -s %SERIAL% shell "pm path com.huawei.hvrsdkserverapp"') do set "RPATH=%%i"
set "RPATH=%RPATH:package:=%"
set "RPATH=%RPATH:/base.apk=%"
"%ADBEXE%" -s %SERIAL% shell "ls %RPATH%/lib/arm64/*.so 2>/dev/null | wc -l"
echo -- vrhandle 32 位姿态库（应为 5 个）--
for /f "delims=" %%i in ('"%ADBEXE%" -s %SERIAL% shell "pm path com.huawei.vrhandle"') do set "HPATH=%%i"
set "HPATH=%HPATH:package:=%"
set "HPATH=%HPATH:/base.apk=%"
"%ADBEXE%" -s %SERIAL% shell "ls -l %HPATH%/lib/arm/*.so 2>/dev/null"
echo -- VR 权限 --
"%ADBEXE%" -s %SERIAL% shell "dumpsys package permissions | grep -m1 'com.huawei.android.permission.VR]'"
echo -- 模拟辅助显示（null=未开）--
"%ADBEXE%" -s %SERIAL% shell "settings get global overlay_display_devices"
echo -- 最近日志中的错误指标（无输出 = 没有这些错误，正常）--
"%ADBEXE%" -s %SERIAL% logcat -d -v threadtime 2>nul | findstr /C:"UnsatisfiedLinkError" /C:"ApplicationQuit" /C:"App activity is null" /C:"FATAL EXCEPTION"
echo -- 最近日志中的姿态/渲染指标（冷启动后可能已滚出缓冲区）--
"%ADBEXE%" -s %SERIAL% logcat -d -v threadtime 2>nul | findstr /C:"load libvrpose success" /C:"helmetPoseStart" /C:"getHelmetPose"
echo -- VR 进程 --
"%ADBEXE%" -s %SERIAL% shell "ps -A | grep -E 'vrservice|vrlauncherx|hvrsdk|vrhandle'"
echo -- 栈顶 --
"%ADBEXE%" -s %SERIAL% shell "dumpsys activity activities | grep mResumedActivity"
echo.
echo [i] 期望：vrhandle lib/arm 有 5 个 32 位库、helmetPoseStart 成功、
echo     无 UnsatisfiedLinkError / ApplicationQuit、栈顶是 launcherx MainActivity。
echo [i] 剩余阻塞：ArvrRuntimeService ANR 级联崩溃、No valid frame to display，
echo     见手册第 8 章。
echo.
pause
exit /b 0

rem ---- 子过程：只有明确报签名冲突才卸载重装（无线 adb 掉线不能误判）----
:INSTALLAPK
"%ADBEXE%" connect %SERIAL% >nul 2>&1
"%ADBEXE%" -s %SERIAL% install -r "%~2" > "%TEMP%\hvr_install.log" 2>&1
if not errorlevel 1 (
    echo       覆盖安装成功
    exit /b 0
)
findstr /I /C:"INSTALL_FAILED_UPDATE_INCOMPATIBLE" /C:"signature" "%TEMP%\hvr_install.log" >nul
if errorlevel 1 (
    echo [FATAL] %~1 安装失败且不是签名冲突，不卸载以免留下缺包：
    type "%TEMP%\hvr_install.log"
    exit /b 1
)
echo       签名不一致，卸载后重装 ...
"%ADBEXE%" connect %SERIAL% >nul 2>&1
"%ADBEXE%" -s %SERIAL% uninstall %~1 >nul 2>&1
"%ADBEXE%" -s %SERIAL% install -r "%~2" > "%TEMP%\hvr_install2.log" 2>&1
if errorlevel 1 (
    echo [FATAL] %~1 卸载后重装失败：
    type "%TEMP%\hvr_install2.log"
    exit /b 1
)
echo       卸载重装成功
exit /b 0

:MISSING
echo [FATAL] 缺少补丁 APK：%PATCH%
pause
exit /b 1

:FAIL
echo [FATAL] 安装失败，可用 rollback 装回原版基线
pause
exit /b 1
