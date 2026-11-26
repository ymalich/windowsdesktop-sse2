@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Build the user-facing Windows Desktop Runtime replacement bundle.
rem Pass a dedicated runtime release checkout whose stable runtime artifacts were
rem produced by build-release-runtime-sse2.cmd as the first argument.
rem Usage: build-release-windowsdesktop-sse2.cmd <runtime-release-repository-path> [x64|x86]
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
    echo Usage: %~nx0 ^<runtime-release-repository-path^> [x64^|x86]
    echo Example: %~nx0 T:\Git\runtime-11-sse2-release x64
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
rem Derive the product version from eng\Versions.props so the script follows the
rem checkout instead of carrying a hand-maintained copy of the version number.
set "VERSIONS_PROPS=%WINDOWSDESKTOP_ROOT%eng\Versions.props"
call :ReadProductVersion || exit /b 1
set "PACKAGE_VERSION=%PRODUCT_VERSION%"
set "MSBUILDDISABLENODEREUSE=1"
set "LOCAL_FEED=%RUNTIME_ROOT%artifacts\packages\%CONFIGURATION%\Shipping"
set "DESKTOP_INTERMEDIATE=%WINDOWSDESKTOP_ROOT%artifacts\obj"
set "DESKTOP_SHIPPING=%WINDOWSDESKTOP_ROOT%artifacts\packages\%CONFIGURATION%\Shipping"
set "DESKTOP_RUNTIME=%WINDOWSDESKTOP_ROOT%src\windowsdesktop\src\sfx\Microsoft.WindowsDesktop.App.Runtime.sfxproj"
set "DESKTOP_BUNDLE=%WINDOWSDESKTOP_ROOT%src\windowsdesktop\src\bundle\bundle.wixproj"
set "DISTRIBUTION_DIR=%RUNTIME_ROOT%artifacts\sse2-distribution\%PACKAGE_VERSION%"
set "DESKTOP_INSTALLER=%DESKTOP_SHIPPING%\windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.exe"
set "PUBLIC_DESKTOP_INSTALLER=%DISTRIBUTION_DIR%\windowsdesktop-runtime-%PACKAGE_VERSION%-sse2-win-%ARCHITECTURE%.exe"

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

echo WARNING: This bundle installs framework version %PACKAGE_VERSION% and replaces
echo the official .NET 11 runtime identity on the target computer.
echo.
echo Windows Desktop root : %WINDOWSDESKTOP_ROOT%
echo Custom runtime feed  : %LOCAL_FEED%
echo Package version      : %PACKAGE_VERSION%
echo Architecture         : %ARCHITECTURE%
echo.

rem Development and stable-identity builds cannot share NuGet restore and
rem packaging intermediates. Otherwise project.assets.json can keep requesting
rem the -sse2 runtime packs while this build produces the stable version.
if exist "%WINDOWSDESKTOP_ROOT%.dotnet\dotnet.exe" (
    "%WINDOWSDESKTOP_ROOT%.dotnet\dotnet.exe" build-server shutdown || exit /b 1
)
if exist "%DESKTOP_INTERMEDIATE%" (
    echo Removing version-sensitive Windows Desktop intermediate outputs...
    rmdir /s /q "%DESKTOP_INTERMEDIATE%" || exit /b 1
)

rem bundle.wixproj invokes Build (but not Restore) on the runtime SFX project.
rem Restore it explicitly after cleaning so its runtime-pack downloads use the
rem stable identity and the local SSE2 package feed.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDOWSDESKTOP_ROOT%eng\common\Build.ps1" ^
    -configuration %CONFIGURATION% ^
    -platform %ARCHITECTURE% ^
    -restore ^
    -projects "%DESKTOP_RUNTIME%" ^
    /p:VersionSuffix= ^
    /p:DotNetFinalVersionKind=release ^
    /p:PreReleaseVersionLabel= ^
    /p:PreReleaseVersionIteration= ^
    /p:MicrosoftNETCoreAppRefPackageVersion=%PACKAGE_VERSION% ^
    /p:MicrosoftNETCoreAppRefVersion=%PACKAGE_VERSION% ^
    /p:RestoreAdditionalProjectSources=%LOCAL_FEED%
if errorlevel 1 exit /b %ERRORLEVEL%

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%WINDOWSDESKTOP_ROOT%eng\common\Build.ps1" ^
    -configuration %CONFIGURATION% ^
    -platform %ARCHITECTURE% ^
    -restore -build -pack ^
    -projects "%DESKTOP_BUNDLE%" ^
    /p:VersionSuffix= ^
    /p:DotNetFinalVersionKind=release ^
    /p:PreReleaseVersionLabel= ^
    /p:PreReleaseVersionIteration= ^
    /p:MicrosoftNETCoreAppRefPackageVersion=%PACKAGE_VERSION% ^
    /p:MicrosoftNETCoreAppRefVersion=%PACKAGE_VERSION% ^
    /p:RestoreAdditionalProjectSources=%LOCAL_FEED% ^
    /p:UseLocalRuntimePrereqs=true ^
    /p:RuntimePrereqDownloadDirectory=%LOCAL_FEED%\
if errorlevel 1 exit /b %ERRORLEVEL%

call :RequireDesktopArtifact "windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.msi" || exit /b 1
call :RequireDesktopArtifact "windowsdesktop-runtime-%PACKAGE_VERSION%-win-%ARCHITECTURE%.exe" || exit /b 1

if not exist "%DISTRIBUTION_DIR%" mkdir "%DISTRIBUTION_DIR%" || exit /b 1
copy /y "%DESKTOP_INSTALLER%" "%PUBLIC_DESKTOP_INSTALLER%" >nul || exit /b 1
call :WriteSha256 "%PUBLIC_DESKTOP_INSTALLER%" || exit /b 1

echo.
echo Stable SSE2 Windows Desktop Runtime build completed successfully.
echo Internal bundle: %DESKTOP_INSTALLER%
echo Distribution  : %PUBLIC_DESKTOP_INSTALLER%
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
echo ERROR: Required stable runtime artifact was not found:
echo        %LOCAL_FEED%\Microsoft.NETCore.App.Crossgen2.win-%ARCHITECTURE%.%PACKAGE_VERSION%.nupkg
echo        %LOCAL_FEED%\Microsoft.NETCore.App.Crossgen2.win-x64.%PACKAGE_VERSION%.nupkg
echo Run build-release-runtime-sse2.cmd first.
exit /b 1

:RequireRuntimeArtifact
if not exist "%LOCAL_FEED%\%~1" (
    echo ERROR: Required stable runtime artifact was not found: %LOCAL_FEED%\%~1
    echo Run build-release-runtime-sse2.cmd first.
    exit /b 1
)
exit /b 0

:RequireDesktopArtifact
if not exist "%DESKTOP_SHIPPING%\%~1" (
    echo ERROR: Expected Windows Desktop artifact was not produced: %DESKTOP_SHIPPING%\%~1
    exit /b 1
)
exit /b 0

:WriteSha256
powershell.exe -NoProfile -NonInteractive -Command ^
    "$ErrorActionPreference='Stop'; $p=[IO.Path]::GetFullPath('%~1'); $s=[IO.File]::OpenRead($p); try { $a=[Security.Cryptography.SHA256]::Create(); try { $h=([BitConverter]::ToString($a.ComputeHash($s))).Replace('-','') } finally { $a.Dispose() } } finally { $s.Dispose() }; [IO.File]::WriteAllText($p + '.sha256', $h + '  ' + [IO.Path]::GetFileName($p) + [Environment]::NewLine)"
exit /b %ERRORLEVEL%
