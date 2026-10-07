@echo off
:next
if "%~1"=="" exit /b 1
if "%~1"=="--body" goto body
shift
goto next
:body
shift
set "body=%~1"
type "%body:~1%"
exit /b %errorlevel%
