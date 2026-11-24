@echo off
title video-tuner offline tests
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0arch.ps1"
if errorlevel 1 goto fail
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0smoke.ps1"
if errorlevel 1 goto fail
echo ALL TESTS PASS
exit /b 0
:fail
echo TESTS FAILED
exit /b 1
