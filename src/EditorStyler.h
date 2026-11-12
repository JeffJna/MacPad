// Applies languages, themes and view options to a Scintilla view.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import "SciUtil.h"

#include <string>

struct Language;
class Theme;

// Margin, marker and indicator numbers.
enum
{
	kMarginLineNumbers = 0,
	kMarginBookmarks = 1,
	kMarginChangeHistory = 2,
	kMarginFold = 3,

	kMarkerBookmark = 20,
	kIndicatorSmartHighlight = 29,
	kIndicatorMarkAll = 31,
};

struct EditorViewSettings
{
	bool wordWrap = false;
	bool showWhitespace = false;
	bool showEndOfLine = false;
	bool showIndentGuides = true;
	bool showLineNumbers = true;
	bool showChangeHistory = true;
	bool highlightCurrentLine = true;
	int edgeColumn = 0; // 0: no vertical edge
	int zoom = 0;
	int tabWidth = 4;
	bool useSpaces = false;
};

// Font chosen in Preferences, replacing the fonts of the theme.
struct EditorFont
{
	std::string name; // empty: keep the font of the theme
	int size = 0;     // in points; 0: keep the size of the theme
};

// One-time setup of a freshly created view (margins, markers, selection behaviour).
void ConfigureEditor(ScintillaView *view);

// Lexer, keywords and colours for a language: each style of the lexer gets the theme style of its role.
void ApplyLanguage(ScintillaView *view, const Language &language, const Theme &theme, const EditorFont &font = EditorFont());

void ApplyViewSettings(ScintillaView *view, const EditorViewSettings &settings);

// Current-line highlight in the colour of the theme, or none.
void ApplyCaretLine(ScintillaView *view, const Theme &theme, bool visible);

// Resizes the line number margin to fit the current line count and zoom.
void UpdateLineNumberMargin(ScintillaView *view, bool visible);
