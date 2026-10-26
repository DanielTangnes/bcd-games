#!/bin/bash
# Builds 7-Zip (7zFM.exe and 7z.exe) from the pinned source; see tools/build-7zip.py.
exec python3 "$(dirname "${BASH_SOURCE[0]}")/build-7zip.py" "$@"
