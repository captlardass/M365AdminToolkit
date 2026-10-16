#!/usr/bin/env python3
# tk-description: TODO: describe what this script does.
# tk-param: Path | String | Required | Folder to look in
# tk-param: Top | Int | | How many entries to list (default 10)
# tk-dryrun: --dry-run
# tk-platforms: Windows, Linux, macOS
#
# Admin Toolkit module (Python 3). The toolkit passes inputs two ways - use whichever you like:
#   arguments:   --Path C:\Logs --Top 5 [--dry-run]       (a List repeats --Name, a Bool is a bare --Name)
#   environment: TK_PARAM_PATH, TK_PARAM_TOP, TK_DRYRUN ("1" on a dry run)
# Output: print("##tk:row " + json.dumps({...})) becomes a result row; other output goes to the log;
# stderr is a warning; a non-zero exit code fails the run. There is no console: never call input().
# The toolkit can't guard what this script does - honour --dry-run yourself.
import argparse
import json
import os
import sys

parser = argparse.ArgumentParser()
parser.add_argument("--Path", required=True)
parser.add_argument("--Top", type=int, default=10)
parser.add_argument("--dry-run", action="store_true")
args = parser.parse_args()

print(f"Listing the {args.Top} largest files in {args.Path} (dry run: {args.dry_run})")
sizes = []
for name in os.listdir(args.Path):
    full = os.path.join(args.Path, name)
    if os.path.isfile(full):
        sizes.append((os.path.getsize(full), name))
for size, name in sorted(sizes, reverse=True)[: args.Top]:
    print("##tk:row " + json.dumps({"Name": name, "SizeKB": size // 1024}))

if not sizes:
    print("No files found.", file=sys.stderr)
