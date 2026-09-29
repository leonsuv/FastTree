#!/bin/sh
set -eu
cd "$(dirname "$0")"
clang -target arm64-apple-macos13.0 -O3 -std=c11 -Wall -Wextra -pthread fasttree-scan.c -o fasttree-scan.bin
