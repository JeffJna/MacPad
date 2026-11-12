#!/usr/bin/env python3
"""Generates MacPad's language and style data.

    tools/gen-data.py <path to SciTE's src directory>

Writes:
  data/languages.json  languages: names, file name patterns, comment tokens, Lexilla lexer,
                       keyword lists and lexer properties
  data/stylemap.json   for every Lexilla lexer, the role ("comment", "keyword", "string", ...)
                       of each of its styles; themes give colours to roles, not to styles

The language list below is MacPad's own. Keyword lists are taken from SciTE's
.properties files (https://www.scintilla.org/SciTE.html, same license as Scintilla and
Lexilla) where SciTE has them, and written here otherwise. The style roles are derived
from the state names in vendor/lexilla/include/SciLexer.h.
"""
import fnmatch
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LEXILLA = os.path.join(ROOT, "vendor", "lexilla")
OUT = os.path.join(ROOT, "data")

# --------------------------------------------------------------------------------------
# Languages
#
# id, menu name, Lexilla lexer, extensions, other file names, shebang interpreters,
# and optional settings:
#   sample     file name used to look up SciTE's keywords (default: x.<first extension>)
#   comment    (line, block start, block end)
#   words      {set: "words"} added to (or, with replace=True, replacing) SciTE's keywords
#   props      Lexilla lexer properties
#   first      prefixes of the first line that identify the language
# --------------------------------------------------------------------------------------

C_LIKE = ("//", "/*", "*/")
HASH = ("#", "", "")

JS_WORDS = ("abstract async await boolean break byte case catch char class const continue debugger "
            "default delete do double else enum export extends false final finally float for from "
            "function get goto if implements import in instanceof int interface let long native new "
            "null of package private protected public return set short static super switch "
            "synchronized this throw throws transient true try typeof undefined var void volatile "
            "while with yield")
TS_WORDS = JS_WORDS + (" any as asserts bigint declare infer is keyof module namespace never "
                       "number object readonly require satisfies string symbol type unique unknown")
KOTLIN_WORDS = ("abstract actual annotation as break by catch class companion const constructor "
                "continue crossinline data delegate do dynamic else enum expect external false field "
                "file final finally for fun get if import in infix init inline inner interface internal "
                "is lateinit noinline null object open operator out override package param private "
                "property protected public receiver reified return sealed set setparam super suspend "
                "tailrec this throw true try typealias typeof val value var vararg when where while")
KOTLIN_TYPES = ("Any Array Boolean Byte Char Double Float Int List Long Map MutableList MutableMap "
                "MutableSet Nothing Pair Set Short String Unit")
SCALA_WORDS = ("abstract case catch class def derives do else end enum export extends extension false "
               "final finally for forSome given if implicit import inline lazy macro match new null "
               "object opaque open override package private protected return sealed super then this "
               "throw trait transparent true try type using val var while with yield")
GROOVY_WORDS = ("abstract as assert boolean break byte case catch char class const continue def "
                "default do double else enum extends false final finally float for goto if implements "
                "import in instanceof int interface long native new null package private protected "
                "public return short static strictfp super switch synchronized this threadsafe throw "
                "throws trait transient true try var void volatile while")
DART_WORDS = ("abstract as assert async await base break case catch class const continue covariant "
              "default deferred do dynamic else enum export extends extension external factory false "
              "final finally for function get hide if implements import in interface is late library "
              "mixin new null of on operator part required rethrow return sealed set show static super "
              "switch sync this throw true try type typedef var void when while with yield")
DART_TYPES = ("bool double dynamic int num Object String List Map Set Future Stream Iterable Never "
              "Null Record Symbol Type Function Duration DateTime")
ZIG_WORDS = ("addrspace align allowzero and anyframe anytype asm async await break callconv catch "
             "comptime const continue defer else enum errdefer error export extern fn for if inline "
             "linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct "
             "suspend switch test threadlocal try union unreachable usingnamespace var volatile while "
             "true false null undefined")
ZIG_TYPES = ("anyerror anyopaque bool c_char c_int c_long c_longdouble c_longlong c_short c_uint "
             "c_ulong c_ulonglong c_ushort comptime_float comptime_int f16 f32 f64 f80 f128 i8 i16 "
             "i32 i64 i128 isize noreturn type u1 u8 u16 u32 u64 u128 usize void")
JULIA_WORDS = ("abstract baremodule begin break catch const continue do else elseif end export false "
               "finally for function global if import in isa let local macro module mutable "
               "nothing primitive quote return struct true try type using where while")
JULIA_TYPES = ("Any AbstractArray AbstractFloat AbstractString Array Bool Char Complex Dict Float16 "
               "Float32 Float64 Function Int Int8 Int16 Int32 Int64 Int128 Integer Missing Nothing "
               "Number Rational Real Set String Symbol Tuple UInt UInt8 UInt16 UInt32 UInt64 Vector")
GDSCRIPT_WORDS = ("and as assert await break breakpoint class class_name const continue elif else "
                  "enum extends false for func if in is match not null or pass preload return self "
                  "signal static super true var void when while yield PI TAU INF NAN")
GDSCRIPT_TYPES = ("bool int float String Vector2 Vector2i Vector3 Vector3i Vector4 Color Rect2 "
                  "Transform2D Transform3D Basis Quaternion Plane AABB NodePath RID Object Array "
                  "Dictionary Callable Signal PackedByteArray PackedInt32Array PackedFloat32Array "
                  "PackedStringArray PackedVector2Array PackedVector3Array PackedColorArray Node")
NIX_WORDS = ("assert else if import in inherit let or rec then throw with true false null")
NIX_BUILTINS = ("abort baseNameOf builtins derivation dirOf fetchGit fetchTarball fetchurl "
                "isNull map placeholder removeAttrs toString")
ST_WORDS = ("PROGRAM END_PROGRAM FUNCTION END_FUNCTION FUNCTION_BLOCK END_FUNCTION_BLOCK VAR "
            "VAR_INPUT VAR_OUTPUT VAR_IN_OUT VAR_GLOBAL VAR_EXTERNAL VAR_TEMP END_VAR CONSTANT "
            "RETAIN IF THEN ELSIF ELSE END_IF CASE OF END_CASE FOR TO BY DO END_FOR WHILE END_WHILE "
            "REPEAT UNTIL END_REPEAT EXIT RETURN TYPE END_TYPE STRUCT END_STRUCT ARRAY AT NOT AND "
            "OR XOR MOD TRUE FALSE METHOD END_METHOD INTERFACE END_INTERFACE")
ST_TYPES = ("BOOL BYTE WORD DWORD LWORD SINT INT DINT LINT USINT UINT UDINT ULINT REAL LREAL TIME "
            "DATE TIME_OF_DAY TOD DATE_AND_TIME DT STRING WSTRING")
TOML_WORDS = "true false"
COFFEE_WORDS = ("and break by case catch class continue debugger default delete do else export extends "
                "false finally for if import in instanceof is isnt loop new no not null of off on or "
                "return super switch then this throw true try typeof undefined unless until when while "
                "yes yield await")
REBOL_WORDS = ("all any break case catch compose context copy do either else exit find first foreach "
               "forall forever func function get has if in join last loop make next none not or parse "
               "print probe quit reduce repeat return rejoin reverse select set skip switch throw to "
               "true false try unless until use value? while with")
OBJC_WORDS = ("self super nil Nil YES NO id instancetype BOOL SEL IMP Class NSObject NSString "
              "NSArray NSDictionary NSInteger NSUInteger CGFloat")
SWIFT_EXTRA = ("actor any async await consume consuming copy discard each borrowing isolated "
               "macro nonisolated package some sending")

LANGUAGES = [
    # id, name, lexer, extensions, file names, shebang interpreters, options
    ("normal", "Normal Text", "null", ["txt", "text", "log"], [], [], {}),
    ("actionscript", "ActionScript", "cpp", ["as", "mx"], [], [], {"comment": C_LIKE}),
    ("ada", "Ada", "ada", ["ada", "ads", "adb"], [], [], {"comment": ("--", "", ""), "sample": "x.adb"}),
    ("asciidoc", "AsciiDoc", "asciidoc", ["adoc", "asciidoc"], [], [], {}),
    ("asn1", "ASN.1", "asn1", ["mib", "asn1", "asn"], [], [], {"comment": ("--", "", ""), "sample": "x.mib"}),
    ("asp", "ASP", "hypertext", ["asp", "aspx", "ascx", "asmx"], [], [], {"comment": ("", "<!--", "-->"), "sample": "x.asp", "props": {"asp.default.language": "2"}}),
    ("asm", "Assembly", "asm", ["asm", "s", "inc"], [], [], {"comment": (";", "", "")}),
    ("autoit", "AutoIt", "au3", ["au3"], [], [], {"comment": (";", "#cs", "#ce")}),
    ("avisynth", "AviSynth", "avs", ["avs", "avsi"], [], [], {"comment": ("#", "/*", "*/")}),
    ("baanc", "BaanC", "baan", ["bc", "cln"], [], [], {"comment": ("|", "", "")}),
    ("batch", "Batch", "batch", ["bat", "cmd", "nt"], [], [], {"comment": ("REM", "", "")}),
    ("blitzbasic", "BlitzBasic", "blitzbasic", ["bb"], [], [], {"comment": (";", "", "")}),
    ("c", "C", "cpp", ["c", "h"], [], [], {"comment": C_LIKE, "sample": "x.c"}),
    ("caml", "CAML", "caml", ["ml", "mli", "sml", "thy"], [], [], {"comment": ("", "(*", "*)")}),
    ("cmake", "CMake", "cmake", ["cmake"], ["CMakeLists.txt"], [], {"comment": HASH, "sample": "CMakeLists.txt"}),
    ("cobol", "COBOL", "COBOL", ["cob", "cbl", "cpy", "copy", "cobol"], [], [], {"comment": ("*>", "", "")}),
    ("coffeescript", "CoffeeScript", "coffeescript", ["coffee", "litcoffee"], ["Cakefile"], ["coffee"], {"comment": ("#", "###", "###"), "words": {0: COFFEE_WORDS}}),
    ("cpp", "C++", "cpp", ["cpp", "cxx", "cc", "c++", "hpp", "hxx", "hh", "h++", "ipp", "tcc", "inl", "ino", "cu", "cuh"], [], [], {"comment": C_LIKE, "sample": "x.cpp"}),
    ("cs", "C#", "cpp", ["cs", "csx"], [], [], {"comment": C_LIKE, "props": {"lexer.cpp.verbatim.strings.allow.escapes": "0"}}),
    ("csound", "Csound", "csound", ["orc", "sco", "csd"], [], [], {"comment": (";", "/*", "*/")}),
    ("css", "CSS", "css", ["css", "scss", "less"], [], [], {"comment": ("", "/*", "*/")}),
    ("d", "D", "d", ["d", "di"], [], [], {"comment": ("//", "/*", "*/")}),
    ("dart", "Dart", "dart", ["dart"], [], ["dart"], {"comment": C_LIKE, "words": {0: DART_WORDS, 1: DART_TYPES}}),
    ("diff", "Diff", "diff", ["diff", "patch"], [], [], {}),
    ("erlang", "Erlang", "erlang", ["erl", "hrl"], ["rebar.config"], ["escript"], {"comment": ("%", "", "")}),
    ("escript", "ESCRIPT", "escript", ["em", "src"], [], [], {"comment": ("//", "/*", "*/"), "sample": "x.em"}),
    ("forth", "Forth", "forth", ["forth", "fth", "4th"], [], [], {"comment": ("\\", "(", ")"), "sample": "x.forth"}),
    ("fortran", "Fortran (free form)", "fortran", ["f90", "f95", "f03", "f08", "f2k"], [], [], {"comment": ("!", "", ""), "sample": "x.f90"}),
    ("fortran77", "Fortran (fixed form)", "f77", ["f", "for", "f77", "fpp"], [], [], {"comment": ("C", "", ""), "sample": "x.f"}),
    ("freebasic", "FreeBASIC", "freebasic", ["bas", "bi"], [], [], {"comment": ("'", "/'", "'/")}),
    ("fsharp", "F#", "fsharp", ["fs", "fsi", "fsx", "fsscript"], [], [], {"comment": ("//", "(*", "*)")}),
    ("gdscript", "GDScript", "gdscript", ["gd"], [], [], {"comment": HASH, "words": {0: GDSCRIPT_WORDS, 1: GDSCRIPT_TYPES}}),
    ("go", "Go", "cpp", ["go"], [], [], {"comment": C_LIKE, "props": {"lexer.cpp.backquoted.strings": "1"}}),
    ("groovy", "Groovy", "cpp", ["groovy", "gvy", "gradle"], ["Jenkinsfile"], ["groovy"], {"comment": C_LIKE, "words": {0: GROOVY_WORDS}, "replace": True}),
    ("haskell", "Haskell", "haskell", ["hs", "lhs", "las"], [], ["runhaskell"], {"comment": ("--", "{-", "-}")}),
    ("hollywood", "Hollywood", "hollywood", ["hws"], [], [], {"comment": (";", "/*", "*/")}),
    ("html", "HTML", "hypertext", ["html", "htm", "shtml", "shtm", "xhtml", "xht", "hta", "tpl", "vue", "svelte"], [], [], {"comment": ("", "<!--", "-->"), "sample": "x.html", "first": ["<!doctype html", "<html"]}),
    ("ini", "INI", "props", ["ini", "inf", "url", "wer", "cfg", "conf", "editorconfig"], [".editorconfig", ".gitconfig"], [], {"comment": (";", "", "")}),
    ("inno", "Inno Setup", "inno", ["iss", "isl"], [], [], {"comment": (";", "{", "}")}),
    ("ihex", "Intel HEX", "ihex", ["hex"], [], [], {}),
    ("java", "Java", "cpp", ["java", "jav", "jad", "pde"], [], [], {"comment": C_LIKE}),
    ("javascript", "JavaScript", "cpp", ["js", "mjs", "cjs", "jsm", "jsx", "es"], [], ["node", "nodejs", "deno", "bun"], {"comment": C_LIKE, "sample": "x.js", "props": {"lexer.cpp.backquoted.strings": "2"}}),
    ("json", "JSON", "json", ["json", "jsonc", "json5", "jsonld", "geojson", "ipynb", "webmanifest"], [".babelrc", ".eslintrc", ".prettierrc", "composer.lock"], [], {"comment": ("//", "/*", "*/"), "props": {"lexer.json.escape.sequence": "1", "lexer.json.allow.comments": "1"}}),
    ("jsp", "JSP", "hypertext", ["jsp", "jspf", "jspx"], [], [], {"comment": ("", "<%--", "--%>"), "sample": "x.jsp"}),
    ("julia", "Julia", "julia", ["jl"], [], ["julia"], {"comment": ("#", "#=", "=#"), "words": {0: JULIA_WORDS, 1: JULIA_TYPES}}),
    ("kix", "KiXtart", "kix", ["kix"], [], [], {"comment": (";", "", "")}),
    ("kotlin", "Kotlin", "cpp", ["kt", "kts", "ktm"], [], [], {"comment": C_LIKE, "words": {0: KOTLIN_WORDS, 1: KOTLIN_TYPES}, "replace": True, "props": {"lexer.cpp.triplequoted.strings": "1"}}),
    ("latex", "LaTeX", "latex", ["tex", "sty", "cls", "ltx", "dtx", "ins", "bib"], [], [], {"comment": ("%", "", ""), "sample": "x.sty"}),
    ("lisp", "Lisp", "lisp", ["lsp", "lisp", "cl", "el", "asd"], [".emacs"], ["sbcl", "clisp"], {"comment": (";", "#|", "|#")}),
    ("lua", "Lua", "lua", ["lua", "luau", "rockspec"], [], ["lua", "luajit"], {"comment": ("--", "--[[", "]]")}),
    ("makefile", "Makefile", "makefile", ["mak", "mk", "make"], ["Makefile", "makefile", "GNUmakefile", "Kbuild"], [], {"comment": HASH, "sample": "Makefile"}),
    ("markdown", "Markdown", "markdown", ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"], [], [], {"comment": ("", "<!--", "-->"), "props": {"lexer.markdown.header.eolfill": "1"}}),
    ("matlab", "MATLAB", "matlab", ["m"], [], [], {"comment": ("%", "%{", "%}"), "sample": "x.m.matlab"}),
    ("mmixal", "MMIXAL", "mmixal", ["mms"], [], [], {"comment": ("%", "", "")}),
    ("mssql", "Transact-SQL", "mssql", ["tsql"], [], [], {"comment": ("--", "/*", "*/"), "sample": "x.sql"}),
    ("nfo", "NFO (ASCII Art)", "null", ["nfo", "diz"], [], [], {}),
    ("nim", "Nim", "nim", ["nim", "nims", "nimble"], [], ["nim"], {"comment": ("#", "#[", "]#")}),
    ("nix", "Nix", "nix", ["nix"], [], [], {"comment": ("#", "/*", "*/"), "words": {0: NIX_WORDS, 1: NIX_BUILTINS}}),
    ("nncrontab", "nnCron", "nncrontab", ["tab", "spf"], [], [], {"comment": ("\\", "", ""), "sample": "x.tab"}),
    ("nsis", "NSIS", "nsis", ["nsi", "nsh"], [], [], {"comment": (";", "/*", "*/")}),
    ("objc", "Objective-C", "cpp", ["m", "mm"], [], [], {"comment": C_LIKE, "sample": "x.cpp", "words": {1: OBJC_WORDS}, "props": {"lexer.cpp.allow.dollars": "0"}}),
    ("oscript", "OScript", "oscript", ["osx"], [], [], {"comment": ("//", "/*", "*/")}),
    ("pascal", "Pascal", "pascal", ["pas", "pp", "p", "dpr", "dpk", "lpr", "inc"], [], [], {"comment": ("//", "{", "}")}),
    ("perl", "Perl", "perl", ["pl", "pm", "plx", "pod", "t", "cgi"], [], ["perl"], {"comment": ("#", "", "")}),
    ("php", "PHP", "hypertext", ["php", "php3", "php4", "php5", "php7", "php8", "phps", "phpt", "phtml"], [], ["php"], {"comment": ("//", "/*", "*/"), "sample": "x.php", "first": ["<?php"]}),
    ("postscript", "PostScript", "ps", ["ps", "eps"], [], [], {"comment": ("%", "", "")}),
    ("powershell", "PowerShell", "powershell", ["ps1", "psm1", "psd1"], [], ["pwsh", "powershell"], {"comment": ("#", "<#", "#>")}),
    ("properties", "Properties", "props", ["properties", "props", "session", "env"], [".env"], [], {"comment": HASH}),
    ("purebasic", "PureBasic", "purebasic", ["pb", "pbi"], [], [], {"comment": (";", "", "")}),
    ("python", "Python", "python", ["py", "pyw", "pyi", "pyx", "pxd", "pxi", "wsgi", "gyp", "gypi", "bzl"], ["SConstruct", "SConscript", "BUILD", "WORKSPACE"], ["python", "python2", "python3", "pypy"], {"comment": HASH, "props": {"lexer.python.strings.f": "1", "lexer.python.decorator.attributes": "1"}}),
    ("r", "R", "r", ["r", "rsource", "rprofile"], [".Rprofile"], ["Rscript"], {"comment": HASH, "sample": "x.r"}),
    ("raku", "Raku", "raku", ["raku", "rakumod", "rakudoc", "rakutest", "p6", "pm6", "pod6", "t6"], [], ["raku", "perl6"], {"comment": ("#", "#`(", ")")}),
    ("rc", "Resource Script", "cpp", ["rc", "rc2", "dlg"], [], [], {"comment": C_LIKE}),
    ("rebol", "REBOL", "rebol", ["r2", "r3", "reb", "red", "reds"], [], [], {"comment": (";", "", ""), "words": {0: REBOL_WORDS}, "replace": True}),
    ("registry", "Windows Registry", "registry", ["reg"], [], [], {"comment": (";", "", "")}),
    ("ruby", "Ruby", "ruby", ["rb", "rbw", "rake", "rjs", "gemspec", "podspec", "ru", "erb"], ["Rakefile", "Gemfile", "Podfile", "Fastfile", "Brewfile", "Vagrantfile"], ["ruby"], {"comment": ("#", "=begin", "=end")}),
    ("rust", "Rust", "rust", ["rs"], [], [], {"comment": ("//", "/*", "*/")}),
    ("sas", "SAS", "sas", ["sas"], [], [], {"comment": ("", "/*", "*/")}),
    ("scala", "Scala", "cpp", ["scala", "sc", "sbt"], [], ["scala"], {"comment": C_LIKE, "words": {0: SCALA_WORDS}, "replace": True, "props": {"lexer.cpp.triplequoted.strings": "1"}}),
    ("scheme", "Scheme", "lisp", ["scm", "ss", "sld", "sls", "sps", "rkt"], [], ["guile", "racket"], {"comment": (";", "#|", "|#"), "sample": "x.scm"}),
    ("shell", "Shell", "bash", ["sh", "bash", "zsh", "ksh", "csh", "tcsh", "bsh", "command", "fish", "ebuild", "eclass"], [".bashrc", ".bash_profile", ".bash_login", ".bash_logout", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".profile", ".kshrc", "configure", "PKGBUILD", "APKBUILD"], ["sh", "bash", "zsh", "ksh", "dash", "ash", "fish"], {"comment": HASH, "sample": "x.sh"}),
    ("smalltalk", "Smalltalk", "smalltalk", ["st"], [], [], {"comment": ("", "\"", "\"")}),
    ("spice", "SPICE", "spice", ["scp", "cir", "sp", "spice"], [], [], {"comment": ("*", "", ""), "sample": "x.scp"}),
    ("sql", "SQL", "sql", ["sql", "ddl", "dml", "pks", "pkb", "pls", "plsql"], [], [], {"comment": ("--", "/*", "*/")}),
    ("srec", "S-Record", "srec", ["mot", "srec", "s19", "s28", "s37"], [], [], {}),
    ("structuredtext", "Structured Text", "fcST", ["st", "iecst"], [], [], {"comment": ("//", "(*", "*)"), "words": {0: ST_WORDS, 1: ST_TYPES}, "sample": "x.iecst"}),
    ("swift", "Swift", "cpp", ["swift"], [], ["swift"], {"comment": C_LIKE, "words": {0: SWIFT_EXTRA}, "props": {"lexer.cpp.triplequoted.strings": "1"}}),
    ("tcl", "Tcl", "tcl", ["tcl", "tk", "itcl", "exp", "tm"], [], ["tclsh", "wish", "expect"], {"comment": HASH}),
    ("tehex", "Tektronix HEX", "tehex", ["tek"], [], [], {}),
    ("tex", "TeX", "tex", ["tex"], [], [], {"comment": ("%", "", ""), "sample": "x.tex", "sets": [0, 2]}),
    ("toml", "TOML", "toml", ["toml"], ["Cargo.lock", "Pipfile", "poetry.lock"], [], {"comment": HASH, "words": {0: TOML_WORDS}}),
    ("txt2tags", "txt2tags", "txt2tags", ["t2t"], [], [], {"comment": ("%", "", "")}),
    ("typescript", "TypeScript", "cpp", ["ts", "tsx", "mts", "cts"], [], ["ts-node"], {"comment": C_LIKE, "words": {0: TS_WORDS}, "replace": True, "props": {"lexer.cpp.backquoted.strings": "2"}}),
    ("vb", "Visual Basic", "vb", ["vb", "vbs", "bas", "frm", "cls", "ctl", "pag", "dsr", "dob", "wsf", "vba"], [], [], {"comment": ("'", "", ""), "sample": "x.vb"}),
    ("verilog", "Verilog", "verilog", ["v", "vh", "sv", "svh"], [], [], {"comment": C_LIKE}),
    ("vhdl", "VHDL", "vhdl", ["vhd", "vhdl", "vho"], [], [], {"comment": ("--", "/*", "*/")}),
    ("visualprolog", "Visual Prolog", "visualprolog", ["pro", "cl", "i", "pack", "ph"], [], [], {"comment": ("%", "/*", "*/"), "sample": "x.pro"}),
    ("xml", "XML", "xml", ["xml", "xsl", "xslt", "xsd", "xaml", "xul", "rss", "atom", "svg", "plist", "storyboard", "xib", "resx", "csproj", "vcxproj", "props", "targets", "nuspec", "wsdl", "kml", "gpx", "dtd", "entitlements"], [], [], {"comment": ("", "<!--", "-->"), "sample": "x.xml", "first": ["<?xml"]}),
    ("yaml", "YAML", "yaml", ["yaml", "yml", "clang-format", "clang-tidy"], [".clang-format", ".clang-tidy"], [], {"comment": HASH}),
    ("zig", "Zig", "zig", ["zig", "zon"], [], [], {"comment": ("//", "", ""), "words": {0: ZIG_WORDS, 1: ZIG_TYPES}}),
]

# Lexers that colour files without keyword lists, or whose keywords come from elsewhere.
KEYWORDLESS = {"null", "diff", "props", "makefile", "markdown", "asciidoc", "srec", "ihex", "tehex", "latex"}


# --------------------------------------------------------------------------------------
# SciTE .properties reader (just enough for keyword lists)
# --------------------------------------------------------------------------------------

def read_properties(directory):
    props = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".properties"):
            continue
        with open(os.path.join(directory, name), encoding="latin-1") as f:
            lines = f.read().split("\n")
        i = 0
        in_block = False
        while i < len(lines):
            line = lines[i].rstrip("\r")
            while line.endswith("\\") and i + 1 < len(lines):
                i += 1
                line = line[:-1] + "\n" + lines[i].rstrip("\r").lstrip()
            i += 1
            if not line.strip():
                in_block = False
                continue
            if line[0] in " \t":
                if in_block:
                    continue  # body of an "if" or "match" block: platform specific
                line = line.strip()
            else:
                in_block = False
            if line.startswith("#"):
                continue
            if line.startswith(("if ", "match ")):
                in_block = True
                continue
            if line.startswith("import ") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            props[key.strip()] = value
    return props


def expand(props, text, depth=0):
    if depth > 30:
        return text

    def substitute(match):
        return expand(props, props.get(match.group(1), ""), depth + 1)
    return re.sub(r"\$\(([^()]+)\)", substitute, text)


def lookup(props, prefix, filename, cache={}):
    """Value of `prefix.<file pattern>` for a file name, as SciTE resolves it."""
    if prefix not in cache:
        entries = []
        for key, value in props.items():
            if key.startswith(prefix + ".") and "$(" in key or key.startswith(prefix + ".*"):
                patterns = expand(props, key[len(prefix) + 1:])
                entries.append(([p.strip() for p in patterns.split(";") if p.strip()], value))
        cache[prefix] = entries
    for patterns, value in cache[prefix]:
        if any(fnmatch.fnmatchcase(filename, p) for p in patterns):
            return expand(props, value)
    return None


def words_of(text):
    return " ".join(sorted(set(text.split())))


# --------------------------------------------------------------------------------------
# Style roles from SciLexer.h
# --------------------------------------------------------------------------------------

# Checked in order: the first rule whose pattern matches the state name gives its role.
ROLE_RULES = [
    (r"DEFAULT$|^IDENTIFIER$|WHITESPACE|^SPACE$|^NORMAL$|^TEXT$|^ASCII$", "default"),
    (r"ERROR|BADCHAR|INVALID|ILLEGAL|STRINGEOL|UNTERMINATED|UNCLOSED", "error"),
    (r"TASKMARKER|TODO", "commentDoc"),
    (r"COMMENTDOCKEYWORD|DOCKEYWORD|COMMENTTAG", "commentDocKeyword"),
    (r"COMMENTDOC|DOCCOMMENT|DOC_COMMENT|COMMENTLINEDOC|COMMENTBLOCKDOC|^DOC$|^DOCLINE$|^DOCBLOCK$|POD", "commentDoc"),
    (r"COMMENT|REMARK|^REM$|BLOCKQUOTE", "comment"),
    (r"REGEX|REGEXP|PATTERN", "regex"),
    (r"ESCAPE|INTERPOLAT|FORMAT|ENTITY|CDATA|TEMPLATE|SUBST", "stringSpecial"),
    (r"STRING|CHARACTER|^CHAR|CHAR$|QUOTE|VERBATIM|HEREDOC|^HERE_|BACKTICK|TRIPLE|LITERAL|RAW|BYTES|CODEBK|CODE2|^CODE$|LINECODE", "string"),
    (r"NUMBER|NUMERIC|DIGIT|^FLOAT$|^INTEGER$|^HEXNUMBER|^BINNUMBER|^OCTNUMBER|^DATE$|^TIME$|DATETIME|CONSTANT", "number"),
    (r"PREPROC|DIRECTIVE|PRAGMA|^MACRO|MACRO$|DEFINE|INCLUDE|DECORATOR|ANNOTATION|ATTRIBUTE_?MARKER|^METADATA$", "preprocessor"),
    (r"^H_TAG$|^TAG|TAGEND|TAGUNKNOWN|^ELEMENT|XMLSTART|XMLEND|SGML_COMMAND|SCRIPT$|ASP$|ASPAT|QUESTION|^SECTION$", "tag"),
    (r"ATTRIBUTE|ATTR|PROPERTY|^KEY$|KEYNAME|PARAM|ARGUMENT|^OPTION", "attribute"),
    (r"HEADER|HEADING|^H[1-6]$|TITLE|CHAPTER|SUBSECTION|^TABLE$", "heading"),
    (r"EMPH|STRONG|BOLD|ITALIC|UNDERLINE|STRIKEOUT", "emphasis"),
    (r"LINK|URL|URI|HYPERLINK|^HREF", "link"),
    (r"ADDED|INSERTED|^PLUS$", "added"),
    (r"DELETED|REMOVED|^MINUS$", "deleted"),
    (r"CHANGED|MODIFIED|PATCH_?ADD|POSITION", "changed"),
    (r"LABEL|TARGET|ANCHOR", "label"),
    (r"GLOBALCLASS|CLASSNAME|CLASS$|^TYPE|TYPE$|TYPES|(^|_)STRUCT|(^|_)ENUM|INTERFACE|^CAPITAL$|^RECORD$", "type"),
    (r"FUNCTION|FUNC|DEFNAME|METHOD|PROCEDURE|BUILTIN|SYSFUNC|STDFUNC|INTRINSIC|CALL|COMMAND|CMDLET|^BIFS$|^ALIAS$", "function"),
    (r"VARIABLE|^VAR|VAR$|SCALAR|ARRAY|HASH|SYMBOL|SPECIALVAR|ENVIRONMENT|PARAMETER|REGISTER|^GLOBAL$", "variable"),
    (r"OPERATOR|^OPER|PUNCT|DELIMITER|BRACE|BRACKET|PAREN|SEPARATOR|ASSIGN|^EQUAL|^COLON|^ARROW", "operator"),
    (r"WORD[2-9]|KEYWORD[2-9]|WORDS?_?[2-9]|SECONDARY|USERWORD|STANDARD|EXTRA|^KW[2-9]", "keyword2"),
    (r"WORD|KEYWORD|INSTRUCTION|^CPU|STATEMENT|RESERVED|^KW|^OPCODE|PRIMITIVE|^IF|DATATYPE|^IMPORT$", "keyword"),
]


# States whose name misleads the rules above (full SciLexer.h names).
ROLE_OVERRIDES = {
    "SCE_HJ_WORD": "default", "SCE_HJA_WORD": "default",          # JavaScript identifiers
    "SCE_HJ_SYMBOLS": "operator", "SCE_HJA_SYMBOLS": "operator",
    "SCE_HPHP_HSTRING_VARIABLE": "stringSpecial", "SCE_HPHP_COMPLEX_VARIABLE": "stringSpecial",
    "SCE_H_VALUE": "string",
    "SCE_MARKDOWN_EM1": "emphasis", "SCE_MARKDOWN_EM2": "emphasis",
    "SCE_MARKDOWN_PRECHAR": "default", "SCE_MARKDOWN_ULIST_ITEM": "keyword",
    "SCE_MARKDOWN_OLIST_ITEM": "keyword", "SCE_MARKDOWN_HRULE": "operator",
    "SCE_MARKDOWN_FRONT_KEY": "attribute", "SCE_MARKDOWN_FRONT_MARK": "operator",
    "SCE_YAML_IDENTIFIER": "attribute", "SCE_YAML_REFERENCE": "variable",
    "SCE_YAML_DOCUMENT": "keyword", "SCE_YAML_TEXT": "string",
    "SCE_CSS_IDENTIFIER": "attribute", "SCE_CSS_IDENTIFIER2": "attribute",
    "SCE_CSS_IDENTIFIER3": "attribute", "SCE_CSS_EXTENDED_IDENTIFIER": "attribute",
    "SCE_CSS_UNKNOWN_IDENTIFIER": "attribute", "SCE_CSS_VALUE": "number",
    "SCE_CSS_ID": "type", "SCE_CSS_PSEUDOELEMENT": "type", "SCE_CSS_EXTENDED_PSEUDOELEMENT": "type",
    "SCE_CSS_IMPORTANT": "keyword", "SCE_CSS_GROUP_RULE": "preprocessor",
    "SCE_SH_HERE_DELIM": "string", "SCE_SH_HERE_Q": "string", "SCE_SH_PARAM": "variable",
    "SCE_PROPS_SECTION": "heading",
}


def style_roles():
    with open(os.path.join(LEXILLA, "include", "SciLexer.h"), encoding="utf-8") as f:
        states = re.findall(r"^#define (SCE_[A-Z0-9_]+) (\d+)", f.read(), re.M)
    with open(os.path.join(LEXILLA, "include", "LexicalStyles.iface"), encoding="utf-8") as f:
        prefixes = {}
        for sclex, rest in re.findall(r"^lex \w+=(SCLEX_\w+) (.*)$", f.read(), re.M):
            prefixes.setdefault(sclex, []).extend(rest.split())
    names = {}
    for name in os.listdir(os.path.join(LEXILLA, "lexers")):
        with open(os.path.join(LEXILLA, "lexers", name), encoding="latin-1") as f:
            for sclex, lexer in re.findall(r'LexerModule \w+\(\s*(SCLEX_\w+),[^,]*,\s*"([^"]+)"', f.read()):
                names[lexer] = sclex

    def role(state):
        for pattern, value in ROLE_RULES:
            if re.search(pattern, state):
                return value
        return "default"

    result = {}
    for lexer, sclex in sorted(names.items()):
        styles = {}
        for prefix in prefixes.get(sclex, []):
            for name, number in states:
                if name.startswith(prefix):
                    suffix = name[len(prefix):]
                    # SCE_H_ and SCE_HJ_ overlap in prefix only: SCE_HJ_X starts with SCE_H.
                    if any(name.startswith(p) and len(p) > len(prefix) for p in prefixes[sclex]):
                        continue
                    styles.setdefault(int(number), ROLE_OVERRIDES.get(name) or role(suffix))
        if styles:
            result[lexer] = {str(k): v for k, v in sorted(styles.items())}
    return result


# --------------------------------------------------------------------------------------

def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    props = read_properties(sys.argv[1])
    roles = style_roles()
    languages = []
    report = []
    for entry in LANGUAGES:
        lid, name, lexer, extensions, filenames, interpreters, options = entry
        if lexer not in roles and lexer != "null":
            sys.exit(f"{lid}: Lexilla has no lexer named {lexer!r}")
        sample = options.get("sample") or (f"x.{extensions[0]}" if extensions else filenames[0])
        keywords = {}
        if lexer not in KEYWORDLESS and not options.get("replace"):
            for index in options.get("sets", range(9)):
                key = "keywords" if index == 0 else f"keywords{index + 1}"
                value = lookup(props, key, sample)
                if value and value.split():
                    keywords[index] = words_of(value)
        for index, words in options.get("words", {}).items():
            merged = (keywords.get(index, "") + " " + words) if not options.get("replace") else words
            keywords[index] = words_of(merged)
        line, start, end = options.get("comment", ("", "", ""))
        language = {"id": lid, "name": name, "lexer": lexer, "extensions": extensions}
        if filenames:
            language["filenames"] = filenames
        if interpreters:
            language["interpreters"] = interpreters
        if options.get("first"):
            language["firstLine"] = options["first"]
        comments = {k: v for k, v in (("line", line), ("start", start), ("end", end)) if v}
        if comments:
            language["comment"] = comments
        if keywords:
            language["keywords"] = {str(k): v for k, v in sorted(keywords.items())}
        if options.get("props"):
            language["properties"] = options["props"]
        languages.append(language)
        report.append(f"{lid:15} {lexer:13} " + " ".join(f"{k}:{len(v.split())}" for k, v in sorted(keywords.items())))

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "languages.json"), "w", encoding="utf-8") as f:
        json.dump({"version": 1, "languages": languages}, f, indent=1, ensure_ascii=False)
        f.write("\n")
    used = {language["lexer"] for language in languages}
    with open(os.path.join(OUT, "stylemap.json"), "w", encoding="utf-8") as f:
        json.dump({"version": 1, "lexers": {k: v for k, v in roles.items() if k in used}}, f, indent=1, sort_keys=True)
        f.write("\n")
    print("\n".join(report))
    print(f"{len(languages)} languages, {len(used)} lexers")


if __name__ == "__main__":
    main()
