@echo off
rem One-time setup: makes a private Python environment in this folder and
rem installs what the training needs (NumPy, about 15 MB). Run it again any
rem time; it's safe.
cd /d "%~dp0"
set PY=
where py >nul 2>nul && set PY=py -3
if not defined PY (
  where python >nul 2>nul && set PY=python
)
if not defined PY (
  echo Python isn't installed. Install it from https://www.python.org/downloads/
  echo ^(tick "Add python.exe to PATH"^), then run this again.
  pause
  exit /b 1
)
if not exist .venv (
  echo Making the environment...
  %PY% -m venv .venv || goto failed
)
echo Installing NumPy...
.venv\Scripts\python -m pip install --disable-pip-version-check -q -r requirements.txt || goto failed
echo.
echo Done. Now double-click train.bat.
pause
exit /b 0
:failed
echo.
echo Setup didn't finish. Copy the message above and send it to Claude.
pause
exit /b 1
