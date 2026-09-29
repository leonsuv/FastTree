#!/bin/sh
set -eu
cd "$(dirname "$0")"
clang -O3 -std=c11 -Wall -Wextra -pthread fasttree-scan.c -o fasttree-scan.bin
