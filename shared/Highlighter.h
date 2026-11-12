// Syntax highlighting without Scintilla: runs a Lexilla lexer over UTF-8 text and returns the
// style of every byte. The iOS editor colours its text with it; style numbers map to theme
// roles through StyleMap, exactly as on the Mac.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#include <string>
#include <vector>

struct Language;

// One style number per byte of `utf8`. All zero when the language has no lexer.
std::vector<unsigned char> StyleText(const std::string &utf8, const Language &language);
