@echo off
setlocal

pushd "%~dp0" || exit /b 1

if not defined AZD_COMMAND set "AZD_COMMAND=azd"
set "ENVIRONMENT_NAME="
set /p "ENVIRONMENT_NAME=Environment name: "
if not defined ENVIRONMENT_NAME (
	echo Environment name is required.
	popd
	exit /b 1
)

if exist "%~dp0.azure\%ENVIRONMENT_NAME%\.env" (
	%AZD_COMMAND% env select "%ENVIRONMENT_NAME%" --no-prompt
) else (
	%AZD_COMMAND% env new "%ENVIRONMENT_NAME%"
)
if errorlevel 1 goto :failed

%AZD_COMMAND% up -e "%ENVIRONMENT_NAME%"
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%

:failed
set "EXIT_CODE=%ERRORLEVEL%"
popd
exit /b %EXIT_CODE%