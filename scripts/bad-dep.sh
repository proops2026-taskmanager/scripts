#!/usr/bin/env bash
# INTENTIONAL FAILURE — AC-06 failure drill.
# SC2044 (warning): for loop over find output flagged by shellcheck --severity=warning.
# This file will be deleted in the next commit to restore green CI.

for f in $(find . -name "*.log"); do
  echo "$f"
done
