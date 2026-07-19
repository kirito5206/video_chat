@echo off
setlocal
cd /d "%~dp0"

REM ---- locate python ----
set "PY="
if exist "C:\Users\li\.workbuddy\binaries\python\envs\video_chat\Scripts\python.exe" (
  set "PY=C:\Users\li\.workbuddy\binaries\python\envs\video_chat\Scripts\python.exe"
) else (
  where python >nul 2>&1 && set "PY=python"
)
if not defined PY (
  echo ERROR: Python not found. Install Python or use the managed venv.
  pause
  exit /b 1
)

REM ---- start signaling server (port 8765) in its own window ----
start "VideoChat-Signaling" cmd /k "%PY% server\signaling_server.py --port 8765"

REM ---- start static http server for web_client.html in its own window ----
start "VideoChat-WebServer" cmd /k "%PY% -m http.server 8000"

REM ---- give servers a moment, then open the browser ----
timeout /t 2 >nul
start "" "http://localhost:8000/web_client.html"

echo.
echo ============================================================
echo  Web video-call test environment is starting.
echo  - Signaling server : ws://localhost:8765
echo  - Web client URL   : http://localhost:8000/web_client.html
echo.
echo  HOW TO TEST DUAL-END CALLING:
echo  1. Open TWO browser tabs on the URL above.
echo  2. In each tab: set a different UserID (e.g. webA / webB),
echo     keep the SAME RoomID, then click "Join".
echo  3. The second tab auto-calls the first. Two-way video appears.
echo.
echo  (Close the two server windows when finished.)
echo ============================================================
pause
