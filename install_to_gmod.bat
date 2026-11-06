@echo off
setlocal

set "PROJECT_ROOT=%~dp0"

rem garrysmod folder, in order: first argument, GMOD_PATH environment variable,
rem install_config.local.bat next to this file (gitignored; one line: set "GMOD_PATH=..."),
rem then Steam's default library.
if not "%~1"=="" set "GMOD_PATH=%~1"
if not defined GMOD_PATH if exist "%PROJECT_ROOT%install_config.local.bat" call "%PROJECT_ROOT%install_config.local.bat"
if not defined GMOD_PATH set "GMOD_PATH=C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod"

echo ========================================================
echo  Installing ZZZ Shader System to Garry's Mod
echo  Target: %GMOD_PATH%
echo ========================================================

if not exist "%GMOD_PATH%" (
    echo [ERROR] Garry's Mod directory not found at:
    echo %GMOD_PATH%
    echo Please verify your Garry's Mod installation directory.
    pause
    exit /b 1
)

echo [1/3] Copying compiled .vcs shaders to garrysmod\shaders\fxc...
if not exist "%GMOD_PATH%\shaders\fxc" mkdir "%GMOD_PATH%\shaders\fxc"
copy /y "%PROJECT_ROOT%addon\shaders\fxc\*.vcs" "%GMOD_PATH%\shaders\fxc\"

echo [2/3] Installing Lua scripts to garrysmod\lua\autorun\client...
if not exist "%GMOD_PATH%\lua\autorun\client" mkdir "%GMOD_PATH%\lua\autorun\client"
copy /y "%PROJECT_ROOT%addon\lua\autorun\client\*.lua" "%GMOD_PATH%\lua\autorun\client\"

echo [3/3] Installing material templates and common VTFs to garrysmod\materials\models\zzz...
if not exist "%GMOD_PATH%\materials\models\zzz" mkdir "%GMOD_PATH%\materials\models\zzz"
xcopy /s /y /q "%PROJECT_ROOT%addon\materials\models\zzz\*" "%GMOD_PATH%\materials\models\zzz\"

echo.
echo ========================================================
echo  [SUCCESS] ZZZ Shader successfully installed to GMod!
echo ========================================================
pause
