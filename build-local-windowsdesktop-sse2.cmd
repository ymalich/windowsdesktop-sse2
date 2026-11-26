@echo off
setlocal EnableExtensions DisableDelayedExpansion
set "MSBUILDDISABLENODEREUSE=1"

rem Build a custom Windows Desktop Runtime bundle that carries the SSE2 CoreCLR.
rem Run this script from the windowsdesktop checkout and pass the custom runtime
rem repository path as the first argument.
rem Usage: build-local-windowsdesktop-sse2.cmd <runtime-repository-path> [x64|x86]
rem        (architecture defaults to x64)

set "WINDOWSDESKTOP_ROOT=%~dp0"
set "RUNTIME_ROOT=%~1"
rem Also accept the architecture as the only argument, so a mistyped call still
rem reports the missing runtime path instead of a bogus directory.
if /i "%~1"=="x64" (
    set "RUNTIME_ROOT="
    set "ARCHITECTURE=%~1"
)
if /i "%~1"=="x86" (
    set "RUNTIME_ROOT="
    set "ARCHITECTURE=%~1"
)
if not defined RUNTIME_ROOT (
    echo Usage: %~nx0 ^<runtime-repository-path^> [x64^|x86]
    echo Example: %~nx0 T:\Git\runtime-11-sse2-v11.0.0 x86
    exit /b 2
)
if not "%RUNTIME_ROOT:~-1%"=="\" set "RUNTIME_ROOT=%RUNTIME_ROOT%\"
rem Second argument wins, otherwise honor an ARCHITECTURE env var, otherwise default to x64.
if not "%~2"=="" set "ARCHITECTURE=%~2"
if not defined ARCHITECTURE set "ARCHITECTURE=x64"
if /i not "%ARCHITECTURE%"=="x64" if /i not "%ARCHITECTURE%"=="x86" (
    echo ERROR: Unsupported architecture "%ARCHITECTURE%". Supported values: x64, x86.
    exit /b 2
)
set "CONFIGURATION=Release"
set "VERSION_SUFFIX=sse2"
rem Derive the product version from eng\Versions.props so the script follows the
rem checkout instead of carrying a hand-maintained copy of the version number.
set "VERSIONS_PROPS=%WINDOWSDESKTOP_ROOT%eng\Versions.props"
call :ReadProductVersion || exit /b 1
set "PACKAGE_VERSION=%PRODUCT_VERSION%-%VERSION_SUFFIX%"
set "LOCAL_FEED=%RUNTIME_ROOT%artifacts\packages\%CONFIGURATION%\Shipping"
set "DESKTOP_SHIPPING=%WINDOWSDESKTOP_ROOT%artifacts\packages\%CONFIGURATION%\Shipping"
set "DESKTOP_RUNTIME=%WINDOWSDESKTOP_ROOT%src\windowsdesktop\src\sfx\Microsoft.WindowsDesktop.App.Runtime.sfxproj"
set "DESKTOP_BUNDLE=%WINDOWSDESKTOP_ROOT%src\windowsdesktop\src\bundle\bundle.wixproj"

if not exist "%WINDOWSDESKTOP_ROOT%build.cmd" (
    echo ERROR: windowsdesktop checkout was not found: %WINDOWSDESKTOP_ROOT%
    exit /b 1
)
if not exist "%RUNTIME_ROOT%build.cmd" (
    echo ERROR: runtime checkout was not found: %RUNTIME_ROOT%
    exit /b 1
)
findstr /c:"UseLocalRuntimePrereqs" "%WINDOWSDESKTOP_ROOT%src\windowsdesktop\src\bundle\Wix.targets" >nul
if errorlevel 1 (
    echo ERROR: The windowsdesktop checkout does not support local runtime prerequisites.
    echo Apply the SSE2 local-runtime changes to src\windowsdesktop\src\bundle\Wix.targets first.
    exit /b 1
)

call :RequireRuntimeArtifact "Microsoft.NETCore.App.Ref.%PACKAGE_VERSION%.nupkg" || exit /b 1
call :RequireCrossgen2 || exit /b 1
call :RequireRuntimeArtifact "dotnet-host-%PACKAGE_VERSION%-win-%ARCHITECTURE%.msi" || exit /b 1
call :RequireRuntimeArtifact "dotnet-hostfxr-%PACKAGE_VERSION%-win-%ARCHITECTURE%.msi" || exit /b 1
call :RequireRuntimeArtifact "dotnet-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.msi" || exit /b 1

echo Windows Desktop root : %WINDOWSDESKTOP_ROOT%
echo Custom runtime feed  : %LOCAL_FEED%
echo Package version      : %PACKAGE_VERSION%
echo Architecture         : %ARCHITECTURE%
echo.

rem Stop build servers left by an earlier invocation so they do not keep build
rem outputs or restored task assemblies locked. A fresh checkout may not have
rem bootstrapped its repository-local SDK yet, in which case Build.ps1 will do it.
if exist "%WINDOWSDESKTOP_ROOT%.dotnet\dotnet.exe" (
    "%WINDOWSDESKTOP_ROOT%.dotnet\dotnet.exe" build-server shutdown >nul 2>&1
)

rem bundle.wixproj invokes Build (but not Restore) on the runtime SFX project.
rem Restore it explicitly so a clean checkout has the required runtime-pack
rem assets and resolves them from the custom SSE2 package feed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDOWSDESKTOP_ROOT%eng\common\Build.ps1" ^
    -configuration %CONFIGURATION% ^
    -platform %ARCHITECTURE% ^
    -restore ^
    -projects "%DESKTOP_RUNTIME%" ^
    /p:VersionSuffix=%VERSION_SUFFIX% ^
    /p:MicrosoftNETCoreAppRefPackageVersion=%PACKAGE_VERSION% ^
    /p:MicrosoftNETCoreAppRefVersion=%PACKAGE_VERSION% ^
    /p:RestoreAdditionalProjectSources=%LOCAL_FEED%
if errorlevel 1 exit /b %ERRORLEVEL%

rem The bundle project builds the WindowsForms/WPF shared framework MSI through
rem its project references. The custom ref and Crossgen2 packs keep generated R2R
rem code compatible with the SSE2 baseline. The local prerequisite directory makes
rem the bundle embed our host, hostfxr and runtime MSI instead of downloading them.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDOWSDESKTOP_ROOT%eng\common\Build.ps1" ^
    -configuration %CONFIGURATION% ^
    -platform %ARCHITECTURE% ^
    -restore -build -pack ^
    -projects "%DESKTOP_BUNDLE%" ^
    /p:VersionSuffix=%VERSION_SUFFIX% ^
    /p:MicrosoftNETCoreAppRefPackageVersion=%PACKAGE_VERSION% ^
    /p:MicrosoftNETCoreAppRefVersion=%PACKAGE_VERSION% ^
    /p:RestoreAdditionalProjectSources=%LOCAL_FEED% ^
    /p:UseLocalRuntimePrereqs=true ^
    /p:RuntimePrereqDownloadDirectory=%LOCAL_FEED%\
if errorlevel 1 exit /b %ERRORLEVEL%

call :RequireDesktopArtifact "windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.msi" || exit /b 1
call :RequireDesktopArtifact "windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.exe" || exit /b 1

echo.
echo Custom Windows Desktop Runtime build completed successfully.
echo MSI    : %DESKTOP_SHIPPING%\windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.msi
echo Bundle : %DESKTOP_SHIPPING%\windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.exe
exit /b 0

:ReadProductVersion
rem Read MajorVersion/MinorVersion/PatchVersion from the eng\Versions.props of the
rem checkout named by VERSIONS_PROPS and expose the result as PRODUCT_VERSION.
if not exist "%VERSIONS_PROPS%" (
    echo ERROR: Version file was not found: %VERSIONS_PROPS%
    exit /b 1
)
set "PRODUCT_VERSION="
for /f "usebackq delims=" %%v in (`powershell.exe -NoProfile -NonInteractive -Command "$g=([xml](Get-Content -Raw -LiteralPath '%VERSIONS_PROPS%')).Project.PropertyGroup; '{0}.{1}.{2}' -f @($g.MajorVersion)[0],@($g.MinorVersion)[0],@($g.PatchVersion)[0]"`) do set "PRODUCT_VERSION=%%v"
echo %PRODUCT_VERSION%| findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul
if errorlevel 1 (
    echo ERROR: Could not read MajorVersion, MinorVersion and PatchVersion from:
    echo        %VERSIONS_PROPS%
    echo        Read value: "%PRODUCT_VERSION%"
    exit /b 1
)
exit /b 0

:RequireCrossgen2
rem Crossgen2 is a build-time compiler. Depending on the runtime build layout it
rem is published for the target RID or for the x64 build host, so accept either.
if exist "%LOCAL_FEED%\Microsoft.NETCore.App.Crossgen2.win-%ARCHITECTURE%.%PACKAGE_VERSION%.nupkg" exit /b 0
if exist "%LOCAL_FEED%\Microsoft.NETCore.App.Crossgen2.win-x64.%PACKAGE_VERSION%.nupkg" exit /b 0
echo ERROR: Required custom runtime artifact was not found:
echo        %LOCAL_FEED%\Microsoft.NETCore.App.Crossgen2.win-%ARCHITECTURE%.%PACKAGE_VERSION%.nupkg
echo        %LOCAL_FEED%\Microsoft.NETCore.App.Crossgen2.win-x64.%PACKAGE_VERSION%.nupkg
echo Run build-local-runtime-sse2.cmd first.
exit /b 1

:RequireRuntimeArtifact
if not exist "%LOCAL_FEED%\%~1" (
    echo ERROR: Required custom runtime artifact was not found: %LOCAL_FEED%\%~1
    echo Run build-local-runtime-sse2.cmd first.
    exit /b 1
)
exit /b 0

:RequireDesktopArtifact
if not exist "%DESKTOP_SHIPPING%\%~1" (
    echo ERROR: Expected Windows Desktop artifact was not produced: %DESKTOP_SHIPPING%\%~1
    exit /b 1
)
exit /b 0
