@echo off
setlocal
cd /d "%~dp0"

set "LOG=%~dp0build_apk.log"
echo =================================================== > "%LOG%"
echo  VideoChat APK build  (started %date% %time%) >> "%LOG%"
echo =================================================== >> "%LOG%"
echo. >> "%LOG%"

REM ---- locate flutter ----
set "FLUTTER_CMD="
where flutter >nul 2>&1
if not errorlevel 1 (
  set "FLUTTER_CMD=flutter"
  goto :found
)
if exist "E:\dev\flutter\bin\flutter.bat" (
  set "FLUTTER_CMD=E:\dev\flutter\bin\flutter.bat"
  goto :found
)
if defined FLUTTER_HOME (
  if exist "%FLUTTER_HOME%\bin\flutter.bat" (
    set "FLUTTER_CMD=%FLUTTER_HOME%\bin\flutter.bat"
    goto :found
  )
)
echo [ERROR] Flutter not found. >> "%LOG%"
echo   Searched: PATH, E:\dev\flutter\bin, %%FLUTTER_HOME%%. >> "%LOG%"
echo   Fix: install Flutter, or set FLUTTER_HOME, then retry. >> "%LOG%"
goto :report

:found
echo Using Flutter: %FLUTTER_CMD% >> "%LOG%"
echo. >> "%LOG%"

echo [1/3] flutter pub get >> "%LOG%"
call "%FLUTTER_CMD%" pub get >> "%LOG%" 2>&1
if errorlevel 1 (
  echo [FAIL] 'flutter pub get' failed. See log above. >> "%LOG%"
  echo   Tip: run 'flutter doctor' to check your environment. >> "%LOG%"
  goto :report
)

echo [2/3] flutter build apk --release >> "%LOG%"
echo       (first run downloads Gradle; can take several minutes) >> "%LOG%"
call "%FLUTTER_CMD%" build apk --release >> "%LOG%" 2>&1
if errorlevel 1 (
  echo [FAIL] 'flutter build apk' failed. See log above. >> "%LOG%"
  echo   Most common cause: Android SDK / JDK not installed. >> "%LOG%"
  echo   Fix: install Android Studio (includes SDK + JDK), then 'flutter doctor'. >> "%LOG%"
  goto :report
)

echo [3/3] BUILD OK >> "%LOG%"
echo APK: build\app\outputs\flutter-apk\app-release.apk >> "%LOG%"
echo Install on phone (enable USB debugging first): >> "%LOG%"
echo   adb install build\app\outputs\flutter-apk\app-release.apk >> "%LOG%"

:report
echo. >> "%LOG%"
echo =================================================== >> "%LOG%"
echo  Done. Full output saved to: >> "%LOG%"
echo  %LOG% >> "%LOG%"
echo =================================================== >> "%LOG%"

echo.
echo ===================================================
echo  VideoChat build finished.
echo  Log: %LOG%
echo ===================================================
echo.
echo ----- LOG -----
type "%LOG%"
echo.
echo Press any key to close this window ...
pause >nul
