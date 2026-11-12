#!/bin/sh
# Replaces vendor/scintilla and vendor/lexilla with official releases from scintilla.org.
# Usage: tools/update-vendor.sh <scintilla version> <lexilla version>
#        tools/update-vendor.sh 569 555        (5.6.9 and 5.5.5: version numbers without dots)
set -eu

if [ $# -ne 2 ]; then
	echo "usage: $0 <scintilla version> <lexilla version>   (for example: 569 555)" >&2
	exit 2
fi

cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir "$work/scintilla" "$work/lexilla"
curl -fsSL "https://www.scintilla.org/scintilla$1.tgz" -o "$work/scintilla.tgz"
curl -fsSL "https://www.scintilla.org/lexilla$2.tgz" -o "$work/lexilla.tgz"
tar -xzf "$work/scintilla.tgz" -C "$work/scintilla"
tar -xzf "$work/lexilla.tgz" -C "$work/lexilla"
sci="$work/scintilla/scintilla"
lex="$work/lexilla/lexilla"

rm -rf vendor/scintilla vendor/lexilla
mkdir -p vendor/scintilla/cocoa/res vendor/lexilla/src

# Scintilla: headers, core and the Cocoa back end
cp -R "$sci/include" "$sci/src" vendor/scintilla/
cp "$sci"/cocoa/*.h "$sci"/cocoa/*.mm vendor/scintilla/cocoa/
cp "$sci"/cocoa/res/*.png vendor/scintilla/cocoa/res/
cp "$sci/License.txt" "$sci/version.txt" "$sci/README" vendor/scintilla/

# Lexilla
cp -R "$lex/include" "$lex/lexlib" "$lex/lexers" vendor/lexilla/
cp "$lex/src/Lexilla.cxx" vendor/lexilla/src/
cp "$lex/License.txt" "$lex/version.txt" "$lex/README" vendor/lexilla/

find vendor -name .DS_Store -delete
echo "vendor/ updated: Scintilla $(cat vendor/scintilla/version.txt), Lexilla $(cat vendor/lexilla/version.txt)"
