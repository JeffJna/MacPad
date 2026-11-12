# Third-party sources

MacPad builds these components from source, unchanged, so that nothing is downloaded at
build time. They come from the official releases at <https://www.scintilla.org/>.

| Directory | Contents | Version | License |
|---|---|---|---|
| `scintilla/` | Scintilla: `include/`, `src/` and the Cocoa back end `cocoa/` (Mac app only) | 5.6.9 | `scintilla/License.txt` |
| `lexilla/` | Lexilla: `include/`, `lexlib/`, `lexers/`, `src/Lexilla.cxx` (Mac and iOS) | 5.5.5 | `lexilla/License.txt` |

Their license notice is also shown in the apps (`resources/Acknowledgements.txt`).

Do not edit these files here: changes belong in MacPad's own code (`src/`, `shared/`,
`ios/`).

## Updating

```bash
tools/update-vendor.sh 569 555   # Scintilla and Lexilla version numbers, without dots
make clean
make test
make ios-test
```

After an update, regenerate the data if Lexilla's style numbers changed
(see `tools/gen-data.py`).
