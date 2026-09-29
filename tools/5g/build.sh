#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# Builds nrprobe. Needs the libgbinder headers: either the -dev packages
# (sudo apt install libgbinder-dev libglibutil-dev), or GBINDER_SRC pointing
# at checkouts of mer-hybris/libgbinder and sailfishos/libglibutil.
set -e
cd "$(dirname "$0")"
if pkg-config --exists libgbinder 2>/dev/null; then
    flags=$(pkg-config --cflags --libs libgbinder glib-2.0)
elif [ -n "$GBINDER_SRC" ]; then
    flags="-I$GBINDER_SRC/libgbinder/include -I$GBINDER_SRC/libglibutil/include \
$(pkg-config --cflags --libs glib-2.0) /usr/lib/$(gcc -dumpmachine)/libgbinder.so.1"
else
    echo "no libgbinder headers - install libgbinder-dev or set GBINDER_SRC" >&2
    exit 1
fi
gcc -O2 -Wall -o nrprobe nrprobe.c $flags
echo "built $(pwd)/nrprobe"
