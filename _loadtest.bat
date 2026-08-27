@echo off
pwsh -NoProfile -File "%~dp0load_tests\scripts\run_load_test.ps1" %*
exit /b %ERRORLEVEL%