@echo off
setlocal
cd /d "%~dp0"
title iPhone Mirror

set "PY="
set "VENV_PY=%~dp0.venv\Scripts\python.exe"
if exist "%VENV_PY%" goto :have_venv

rem ---- cari Python 3.12 atau lebih baru ----
py -3.12 -c "import sys" >nul 2>nul && set "PY=py -3.12"
if defined PY goto :make_venv
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)" >nul 2>nul && set "PY=python"
if defined PY goto :make_venv
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" set PY="%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
if defined PY goto :make_venv

echo Python 3.12 belum ada. Menginstall lewat winget, tunggu sebentar...
winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements
if exist "%LOCALAPPDATA%\Programs\Python\Python312\python.exe" (
    set PY="%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
    goto :make_venv
)
echo.
echo Gagal install Python otomatis.
echo Install manual Python 3.12 dari https://www.python.org/downloads/ (centang "Add python.exe to PATH"),
echo lalu jalankan run.bat lagi.
pause
exit /b 1

:make_venv
echo Menyiapkan environment (cuma sekali di awal)...
%PY% -m venv .venv
if not exist "%VENV_PY%" (
    echo Gagal membuat environment Python.
    pause
    exit /b 1
)

:have_venv
if exist ".venv\installed-1.0.0.flag" goto :run
echo Menginstall library (cuma sekali, butuh internet)...
"%VENV_PY%" -m pip install --disable-pip-version-check -q --upgrade pip
"%VENV_PY%" -m pip install --disable-pip-version-check -q -r requirements.txt
if errorlevel 1 (
    echo Gagal install library. Cek koneksi internet lalu jalankan run.bat lagi.
    pause
    exit /b 1
)
echo ok> ".venv\installed-1.0.0.flag"

:run
"%VENV_PY%" mirror.py %*
if errorlevel 1 pause
endlocal
