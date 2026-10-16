#!/usr/bin/env bash
# tk-description: TODO: describe what this script does.
# tk-param: Path | String | Required | Folder to look in
# tk-param: Top | Int | | How many entries to list (default 10)
# tk-dryrun: --dry-run
# tk-platforms: Linux, macOS
#
# Admin Toolkit module (bash). The toolkit passes inputs two ways - use whichever you like:
#   arguments:   --Path /var/log --Top 5 [--dry-run]     (a List repeats --Name, a Bool is a bare --Name)
#   environment: TK_PARAM_PATH, TK_PARAM_TOP, TK_DRYRUN (1 on a dry run)
# Output: a line "##tk:row {json}" becomes a result row; any other line goes to the log; stderr is a
# warning; a non-zero exit code fails the run. There is no console: never prompt (read, sudo).
# The toolkit can't guard what this script does - honour --dry-run yourself.
# No pipefail: du reports unreadable entries and head closes the pipe early; neither is a failure here.
set -eu

path="" top=10 dry_run=0
while [ $# -gt 0 ]; do
    case "$1" in
        --Path) path="$2"; shift 2 ;;
        --Top) top="$2"; shift 2 ;;
        --dry-run) dry_run=1; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$path" ] || { echo "--Path is required" >&2; exit 2; }

echo "Listing the $top largest entries in $path (dry run: $dry_run)"
{ du -sk "$path"/* 2>/dev/null || true; } | sort -rn | head -n "$top" | while read -r size name; do
    # JSON-escape the name: backslashes and double quotes.
    name=${name//\\/\\\\}; name=${name//\"/\\\"}
    printf '##tk:row {"Name":"%s","SizeKB":%s}\n' "$name" "$size"
done
