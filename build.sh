#!/usr/bin/env bash

set -ex

# a function to report an error and return with error

die() { echo "$*" 1>&2 ; exit 1; }

if [[ $# -eq 1 ]]; then
    FROM=""
    TO=$1
elif [[ $# -eq 2 ]]; then
    FROM=$1
    TO=$2
else
    die "Usage: $0 [FROM] TO"
fi

# unpack sources

tar xaf /cachi2/output/deps/generic/rustc-$TO-src.tar.xz

# collect copy license files

find . -type f \( -iname 'license' -o -iname 'license.*' -o -iname 'copying' -o -iname 'copying.*' \) -exec cp --parents {} /licenses/ \;

PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patches/$TO"

# enter source directory

pushd rustc-$TO-src

# apply patches matching the target version

if [[ -d "$PATCH_DIR" ]]; then
    for patch in $(find "$PATCH_DIR" -maxdepth 1 -name '*.patch' -print | sort); do
        echo "Applying patch: $patch"
        git apply "$patch"
    done
fi

# configure arguments

ARGS=()
if [[ -n "$FROM" ]]; then
    ARGS+=(--local-rust-root="/install/$FROM")
fi

# run build config

./configure --enable-local-rust --prefix=/install/$TO --enable-vendor --disable-compiler-docs --disable-docs --disable-dist-src --release-channel=stable "${ARGS[@]}"

# enable more detailed error reporting

export RUST_BACKTRACE=1

# run build and dist packaging

python3 ./x.py dist

# install

python3 ./x.py install

# clean up build

rm -Rf build

# go back

popd
