@echo off
cd /d "%~dp0"
set "EXE="
for %%F in ("BeamNG*Earth*.exe") do set "EXE=%%F"
if not defined EXE (
  echo Could not find the BeamNG.Earth .exe in this folder:
  echo %~dp0
  dir /b *.exe
  pause
  exit /b 1
)
rem --no-game: only the companion (start the game with the BeamMP launcher)
rem --keep-mod: never copy the normal mod back into mods/unpacked (it would clash with the server's MP mod)
rem --update-check off: no "new version" prompt, players stay on the server's version
echo Starting "%EXE%" --no-game --keep-mod -- --update-check off
"%EXE%" --no-game --keep-mod -- --update-check off
pause
