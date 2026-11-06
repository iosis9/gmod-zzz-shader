@echo off
setlocal enabledelayedexpansion

echo ========================================================
echo  Compiling ZZZ Shaders (Shader Model 3.0)
echo ========================================================

set "SHADER_PATH=%~dp0"
cd /d "%SHADER_PATH%"

if not exist "%SHADER_PATH%ShaderCompile.exe" (
    echo [ERROR] shaders\ShaderCompile.exe not found. It is not shipped with this repo.
    echo Build the standalone ShaderCompile from https://github.com/SCell555/ShaderCompile
    echo and put ShaderCompile.exe in this folder. See README, "Build and install".
    exit /b 1
)

for %%H in (common_fxc.h common_hlsl_cpp_consts.h common_pragmas.h common_ps_fxc.h common_vs_fxc.h) do (
    if not exist "%SHADER_PATH%%%H" (
        echo [ERROR] shaders\%%H not found. Valve's SDK headers are not shipped with this repo.
        echo Copy common_*.h from src/materialsystem/stdshaders in
        echo https://github.com/ValveSoftware/source-sdk-2013 into this folder.
        exit /b 1
    )
)

set FAILED=0
for %%F in (zzz_*_vs30.hlsl zzz_*_ps30.hlsl) do (
    echo Compiling %%F ...
    "%SHADER_PATH%ShaderCompile.exe" /O 3 -ver 30 -shaderpath "%SHADER_PATH%." %%F
    if !ERRORLEVEL! neq 0 (
        echo [ERROR] %%F failed to compile
        set FAILED=1
    )
)

if %FAILED% neq 0 (
    echo [ERROR] One or more shaders failed.
    exit /b 1
)

if not exist "..\addon\shaders\fxc" mkdir "..\addon\shaders\fxc"
copy /y "shaders\fxc\*.vcs" "..\addon\shaders\fxc\" >nul
if exist "shaders" rmdir /s /q "shaders"

echo.
echo [SUCCESS] Shaders compiled into addon\shaders\fxc\
exit /b 0
