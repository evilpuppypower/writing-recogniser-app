@echo off
rem Trains your model from the app's training data file and shows a report.
cd /d "%~dp0"
if not exist .venv\Scripts\python.exe (
  echo Run setup.bat first.
  pause
  exit /b 1
)
.venv\Scripts\python -m wr_train %*
echo.
pause
