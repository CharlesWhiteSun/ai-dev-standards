@echo off
pushd "%~dp0.vscode"
openspec %*
set _EC=%ERRORLEVEL%
popd
exit /b %_EC%