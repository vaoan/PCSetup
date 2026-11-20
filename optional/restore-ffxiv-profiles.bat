@echo off
:: Restores the FFXIV profiles (Profiles, XIVLauncher, XIVProfiles, FFXIVConfig, MINION) from the
:: private GitHub backups, using GH_TOKEN from secrets.txt. See sources\restore-ffxiv-profiles.ps1.
:: Unattended, never deletes: an existing clone is fast-forwarded, a foreign non-empty folder is left alone.
setlocal
set "PSModulePath="
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\sources\restore-ffxiv-profiles.ps1" %*
endlocal & exit /b %errorlevel%
