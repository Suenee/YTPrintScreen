@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul 2>&1
cls

set "UPDATER_REVISION=1.03"
set "TARGET_BRANCH=devel"
set "REPO_URL=https://github.com/Suenee/YTPrintScreen.git"

if /I "%~1"=="--temp-launcher" goto :TEMP_LAUNCHER

for %%I in ("%~dp0.") do set "REPO_DIR=%%~fI"
if not defined REPO_DIR (
    echo ERROR: Nelze určit adresář repozitáře.
    exit /b 2
)

set "TEMP_LAUNCHER=%TEMP%\YTPrintScreen-upgrade-launcher-%RANDOM%-%RANDOM%.cmd"
copy /y "%~f0" "%TEMP_LAUNCHER%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Nelze vytvořit dočasný upgrade launcher.
    exit /b 3
)

rem Jednosměrné předání řízení: tato kopie už po návratu dítěte nečte další řádky souboru.
cmd.exe /d /s /c ""%TEMP_LAUNCHER%" --temp-launcher "%REPO_DIR%"" & exit /b

:TEMP_LAUNCHER
set "REPO_DIR=%~2"
if not defined REPO_DIR (
    echo ERROR: Do dočasného launcheru nebyla předána cesta repozitáře.
    exit /b 4
)

for %%I in ("%REPO_DIR%") do set "REPO_DIR=%%~fI"
if not exist "%REPO_DIR%\." (
    echo ERROR: Adresář repozitáře neexistuje: %REPO_DIR%
    exit /b 5
)

set "POWERSHELL_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%POWERSHELL_EXE%" (
    echo ERROR: Windows PowerShell nebyl nalezen: %POWERSHELL_EXE%
    exit /b 6
)

set "GIT_EXE="
for /f "delims=" %%G in ('where git.exe 2^>nul') do if not defined GIT_EXE set "GIT_EXE=%%G"
if not defined GIT_EXE if exist "%ProgramFiles%\Git\cmd\git.exe" set "GIT_EXE=%ProgramFiles%\Git\cmd\git.exe"
if not defined GIT_EXE if exist "%ProgramFiles%\Git\bin\git.exe" set "GIT_EXE=%ProgramFiles%\Git\bin\git.exe"
if not defined GIT_EXE (
    echo ERROR: Git for Windows nebyl nalezen. Nainstalujte Git a spusťte upgrade.cmd znovu.
    exit /b 7
)

pushd "%REPO_DIR%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: Nelze vstoupit do repozitáře: %REPO_DIR%
    exit /b 8
)

set "ACTIVE_REPO=%CD%"
set "GIT_CONFIG_COUNT=1"
set "GIT_CONFIG_KEY_0=safe.directory"
set "GIT_CONFIG_VALUE_0=%ACTIVE_REPO%"
set "TEMP_RUNNER=%TEMP%\YTPrintScreen-upgrade-runner-%RANDOM%-%RANDOM%.ps1"
set "TEMP_CLONE=%TEMP%\YTPrintScreen-upgrade-clone-%RANDOM%-%RANDOM%"

if exist ".git\" goto :FETCH_RUNNER_EXISTING

rem První zavedení do dosud negitového adresáře: runner se získá z čistého dočasného klonu.
"%GIT_EXE%" clone --quiet --depth 1 --branch "%TARGET_BRANCH%" "%REPO_URL%" "%TEMP_CLONE%"
if errorlevel 1 goto :FAIL_BOOTSTRAP_FETCH
if not exist "%TEMP_CLONE%\upgrade.ps1" goto :FAIL_RUNNER_MISSING
copy /y "%TEMP_CLONE%\upgrade.ps1" "%TEMP_RUNNER%" >nul 2>&1
if errorlevel 1 goto :FAIL_RUNNER_COPY
rmdir /s /q "%TEMP_CLONE%" >nul 2>&1
goto :RUNNER

:FETCH_RUNNER_EXISTING
rem Pro self-update se runner bere přímo z autoritativní vzdálené větve, nikoli z pracovního stromu.
"%GIT_EXE%" -C "%ACTIVE_REPO%" fetch --quiet "%REPO_URL%" "%TARGET_BRANCH%"
if errorlevel 1 goto :FAIL_FETCH
"%GIT_EXE%" -C "%ACTIVE_REPO%" show FETCH_HEAD:upgrade.ps1 > "%TEMP_RUNNER%"
if errorlevel 1 goto :FAIL_RUNNER_COPY

:RUNNER
if not exist "%TEMP_RUNNER%" goto :FAIL_RUNNER_MISSING
rem Windows PowerShell 5.1 interpretuje UTF-8 bez BOM jako ANSI; dočasný runner proto dostane BOM explicitně.
"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:TEMP_RUNNER; $t=[System.IO.File]::ReadAllText($p,[System.Text.Encoding]::UTF8); $e=New-Object System.Text.UTF8Encoding($true); [System.IO.File]::WriteAllText($p,$t,$e)"
if errorlevel 1 goto :FAIL_RUNNER_ENCODING

"%POWERSHELL_EXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%TEMP_RUNNER%" -RepositoryPath "%ACTIVE_REPO%" -SourcePath "%REPO_DIR%" -TargetBranch "%TARGET_BRANCH%" -RepositoryUrl "%REPO_URL%" -UpdaterRevision "%UPDATER_REVISION%"
set "RC=%ERRORLEVEL%"
del /q "%TEMP_RUNNER%" >nul 2>&1
if exist "%TEMP_CLONE%\" rmdir /s /q "%TEMP_CLONE%" >nul 2>&1
popd >nul 2>&1
exit /b %RC%

:FAIL_BOOTSTRAP_FETCH
echo ERROR: Nelze získat autoritativní updater z %REPO_URL% větve %TARGET_BRANCH%.
set "RC=20"
goto :FAIL_COMMON

:FAIL_FETCH
echo ERROR: Git fetch autoritativní větve %TARGET_BRANCH% selhal.
set "RC=21"
goto :FAIL_COMMON

:FAIL_RUNNER_COPY
echo ERROR: Nelze vytvořit dočasnou kopii upgrade.ps1.
set "RC=22"
goto :FAIL_COMMON

:FAIL_RUNNER_MISSING
echo ERROR: Autoritativní upgrade.ps1 nebyl nalezen.
set "RC=23"
goto :FAIL_COMMON

:FAIL_RUNNER_ENCODING
echo ERROR: Nelze připravit UTF-8 dočasnou kopii upgrade.ps1.
set "RC=24"
goto :FAIL_COMMON

:FAIL_COMMON
if exist "%TEMP_RUNNER%" del /q "%TEMP_RUNNER%" >nul 2>&1
if exist "%TEMP_CLONE%\" rmdir /s /q "%TEMP_CLONE%" >nul 2>&1
popd >nul 2>&1
exit /b %RC%
