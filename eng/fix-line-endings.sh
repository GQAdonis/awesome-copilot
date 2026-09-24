#!/bin/bash
# Script to fix line endings in all markdown files

echo "Normalizing line endings in markdown files..."

# Find all markdown files and convert CRLF to LF
# Use GNU sed in-place syntax on Linux, BSD sed syntax on macOS.
if sed --version >/dev/null 2>&1; then
  SED_IN_PLACE=(-i)
else
  SED_IN_PLACE=(-i '')
fi

find . -name "*.md" -type f -exec sed "${SED_IN_PLACE[@]}" 's/\r$//' {} \;

echo "Done! All markdown files now have LF line endings."
