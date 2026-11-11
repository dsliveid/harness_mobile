@echo off
rem ===========================================================================
rem build.cmd - Windows entry point for build.sh
rem
rem run/build logic lives in build.sh (single source of truth). This file only
rem locates a bash interpreter and forwards all arguments.
rem
rem WHY ASCII-ONLY
rem   cmd / PowerShell 5.1 decode BOM-less UTF-8 as ANSI; CJK bytes here would
rem   break parsing. Chinese messages live inside build.sh.
rem
rem USAGE
rem   build.cmd                     -> flutter build apk --release --target-platform android-arm64
rem   build.cmd --target emulator   -> x86_64 APK for AVD (emulator only)
rem   build.cmd --target device     -> arm64-v8a APK for real phone (default)
rem   build.cmd --target all        -> all ABIs (slowest, downloads 3 engine jars)
rem   build.cmd --windows          -> Windows desktop build (whole directory!)
rem   build.cmd --help             -> full help (Chinese, from build.sh)
rem
rem NOTE ON --target
rem   "emulator" and "device" builds are NOT interchangeable: an x86_64 APK will
rem   fail to install on an arm64 phone with INSTALL_FAILED_NO_MATCHING_ABIS.
rem   Likewise conclusions drawn on the x86_64 AVD must not be extrapolated to
rem   real arm64 hardware (native lib behaviour can differ).
rem
rem NOTE ON PREFLIGHT
rem   build.sh self-checks nuget visibility, the MSVC v143 toolset, and Gradle
rem   proxy consistency before building, and fails fast with fix instructions.
rem   Pass --skip-preflight to bypass (not recommended).
rem ===========================================================================

setlocal
set "SCRIPT_DIR=%~dp0"

set "BASH_EXE="
for %%B in (bash.exe) do if not defined BASH_EXE if exist "%%~$PATH:B" set "BASH_EXE=%%~$PATH:B"

if not defined BASH_EXE if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE if exist "D:\Program Files\Git\bin\bash.exe" set "BASH_EXE=D:\Program Files\Git\bin\bash.exe"
if not defined BASH_EXE if exist "D:\Program Files\Git\usr\bin\bash.exe" set "BASH_EXE=D:\Program Files\Git\usr\bin\bash.exe"

if not defined BASH_EXE (
  echo [ERROR] bash not found.
  echo         Install Git for Windows ^(it ships bash^), or run build.sh
  echo         manually from Git Bash.
  exit /b 1
)

"%BASH_EXE%" "%SCRIPT_DIR%build.sh" %*
exit /b %ERRORLEVEL%
