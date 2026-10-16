@echo off
rem tk-description: TODO: describe what this script does.
rem tk-param: Path | String | Required | Folder to look in
rem tk-dryrun: /dryrun
rem tk-platforms: Windows
rem
rem Admin Toolkit module (cmd). Inputs arrive ONLY as environment variables: TK_PARAM_PATH, and
rem TK_DRYRUN (1 on a dry run, when the toolkit also passes /dryrun as %1).
rem Read them with delayed expansion - !TK_PARAM_PATH! - so characters such as & | ^ in a value stay
rem text instead of becoming commands. Never use %TK_PARAM_...% unquoted.
rem Output: a line "##tk:row {json}" becomes a result row; other lines go to the log; stderr (1>&2) is
rem a warning; a non-zero exit code (exit /b 1) fails the run. There is no console: never pause or set /p.
rem The toolkit can't guard what this script does - honour /dryrun yourself.
setlocal EnableDelayedExpansion

if not defined TK_PARAM_PATH (echo Path is required 1>&2 & exit /b 2)
if not exist "!TK_PARAM_PATH!\" (echo Folder not found: !TK_PARAM_PATH! 1>&2 & exit /b 1)

echo Listing files in !TK_PARAM_PATH! (dry run: %TK_DRYRUN%)
for %%F in ("!TK_PARAM_PATH!\*") do (
    set "name=%%~nxF"
    rem JSON-escape the name: backslashes and double quotes.
    set "name=!name:\=\\!"
    echo ##tk:row {"Name":"!name!","Bytes":%%~zF}
)
exit /b 0
