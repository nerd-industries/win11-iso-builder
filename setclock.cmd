@echo off
rem setclock.cmd - run in windowsPE. If the RTC date is earlier than the ISO build date, set it forward.
set BUILDDATE=20261006
set BMM=10&set BDD=06&set BYY=2026
for /f "tokens=2" %%a in ("%date%") do set D=%%a
if "%D%"=="" set D=%date%
for /f "tokens=1-3 delims=/-." %%m in ("%D%") do set CMM=%%m&set CDD=%%n&set CYY=%%o
set NOW=%CYY%%CMM%%CDD%
if "%NOW%" LSS "%BUILDDATE%" (
  date %BMM%-%BDD%-%BYY%
  time 12:00:00
)
exit /b 0
