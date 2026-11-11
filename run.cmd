@echo off
rem ===========================================================================
rem run.cmd - Windows entry point for run.sh
rem
rem WHY THIS EXISTS
rem   run.sh is the single source of truth (bash, runs in Git Bash / MSYS).
rem   Windows users should not have to know that, so this file just locates a
rem   bash interpreter and forwards ALL arguments to run.sh.
rem
rem WHY THIS FILE IS ASCII-ONLY
rem   Windows PowerShell 5.1 / cmd read BOM-less UTF-8 as ANSI. Multibyte CJK
rem   bytes would corrupt this script's parser. The repo already learned this
rem   lesson in harness_desktop/scripts/dev.ps1. Keep this file ASCII forever.
rem   All Chinese help text lives inside run.sh instead.
rem
rem USAGE
rem   run.cmd                  -> flutter run -d windows
rem   run.cmd --android        -> first online Android device
rem   run.cmd --help           -> full help (Chinese, from run.sh)
rem ===========================================================================

setlocal
set "SCRIPT_DIR=%~dp0"

rem --- locate bash: PATH first, then common Git install locations ------------
set "BASH_EXE="
for %%B in (bash.exe) do if not defined BASH_EXE if exist "%%~$PATH:B" set "BASH_EXE=%%~$PATH:B"

if not defined BASH_EXE if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH_EXE=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH_EXE if exist "D:\Program Files\Git\bin\bash.exe" set "BASH_EXE=D:\Program Files\Git\bin\bash.exe"
if not defined BASH_EXE if exist "D:\Program Files\Git\usr\bin\bash.exe" set "BASH_EXE=D:\Program Files\Git\usr\bin\bash.exe"

if not defined BASH_EXE (
  echo [ERROR] bash not found.
  echo         Install Git for Windows ^(it ships bash^), or run run.sh
  echo         manually from Git Bash.
  exit /b 1
)

rem --- forward ---------------------------------------------------------------
rem Quote the script path (it may contain spaces), pass %* verbatim.
"%BASH_EXE%" "%SCRIPT_DIR%run.sh" %*
exit /b %ERRORLEVEL%
