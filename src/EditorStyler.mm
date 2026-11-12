// Applies languages, themes and view options to a Scintilla view.
// This file is part of MacPad (GPL v3 or later).
#import "EditorStyler.h"

#include <vector>

#include "ILexer.h"
#include "Lexilla.h"

#include "LanguageCatalog.h"
#include "Theme.h"

namespace
{

NSString *const kDefaultFont = @"Menlo";
const int kDefaultFontSize = 13;

// Theme colours are 0xRRGGBB; Scintilla wants 0xBBGGRR.
int Sci(unsigned rgb)
{
	return SciColourFromRGB(rgb);
}

void SetProperty(ScintillaView *view, const char *key, const char *value)
{
	SciCall(view, SCI_SETPROPERTY, reinterpret_cast<uptr_t>(key), reinterpret_cast<sptr_t>(value));
}

void SetRoleStyle(ScintillaView *view, int style, const ThemeStyle &spec)
{
	SciCall(view, SCI_STYLESETFORE, style, Sci(spec.color));
	if (spec.hasBackground)
		SciCall(view, SCI_STYLESETBACK, style, Sci(spec.background));
	SciCall(view, SCI_STYLESETBOLD, style, spec.bold);
	SciCall(view, SCI_STYLESETITALIC, style, spec.italic);
	SciCall(view, SCI_STYLESETUNDERLINE, style, spec.underline);
}

void ApplyKeywordsAndProperties(ScintillaView *view, const Language &language)
{
	for (int set = 0; set < KW_COUNT; ++set)
		SciCallString(view, SCI_SETKEYWORDS, set, language.keywords[set]);

	SetProperty(view, "fold", "1");
	SetProperty(view, "fold.compact", "0");
	SetProperty(view, "fold.comment", "1");
	SetProperty(view, "fold.preprocessor", "1");
	SetProperty(view, "fold.html", "1");
	SetProperty(view, "fold.hypertext.comment", "1");
	// Symbols are usually defined outside the file, so inactive code detection misleads.
	SetProperty(view, "lexer.cpp.track.preprocessor", "0");
	for (const auto &[key, value] : language.properties)
		SetProperty(view, key.c_str(), value.c_str());
}

void ApplyGlobalColours(ScintillaView *view, const Theme &theme)
{
	const unsigned background = theme.Background();
	const unsigned foreground = theme.Foreground();
	const unsigned gutter = theme.Color("gutter", background);

	SciCall(view, SCI_STYLESETFORE, STYLE_LINENUMBER, Sci(theme.Color("lineNumber", foreground)));
	SciCall(view, SCI_STYLESETBACK, STYLE_LINENUMBER, Sci(gutter));
	SciCall(view, SCI_STYLESETFORE, STYLE_BRACELIGHT, Sci(theme.Color("braceMatch", foreground)));
	SciCall(view, SCI_STYLESETBACK, STYLE_BRACELIGHT, Sci(theme.Color("braceMatchBackground", background)));
	SciCall(view, SCI_STYLESETBOLD, STYLE_BRACELIGHT, 1);
	SciCall(view, SCI_STYLESETFORE, STYLE_BRACEBAD, Sci(theme.Color("braceBad", 0xD11F1F)));
	SciCall(view, SCI_STYLESETBOLD, STYLE_BRACEBAD, 1);
	SciCall(view, SCI_STYLESETFORE, STYLE_INDENTGUIDE, Sci(theme.Color("indentGuide", 0xC0C0C0)));
	SciCall(view, SCI_STYLESETBACK, STYLE_INDENTGUIDE, Sci(background));
	SciCall(view, SCI_SETEDGECOLOUR, Sci(theme.Color("edge", 0xC0C0C0)));

	const unsigned selection = theme.Color("selection", 0xC0C0C0);
	const unsigned multiSelection = theme.Color("multiSelection", selection);
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_BACK, SciOpaque(Sci(selection)));
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_INACTIVE_BACK, SciOpaque(Sci(selection)));
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_ADDITIONAL_BACK, SciOpaque(Sci(multiSelection)));
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_SELECTION_SECONDARY_BACK, SciOpaque(Sci(multiSelection)));
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET, SciOpaque(Sci(theme.Color("caret", foreground))));
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET_ADDITIONAL, SciOpaque(Sci(theme.Color("multiCaret", foreground))));
	SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_WHITE_SPACE, SciOpaque(Sci(theme.Color("whitespace", 0xA0A0A0))));

	// Fold margin and the box tree markers: lines in foldMarker, boxes filled with the gutter colour.
	SciCall(view, SCI_SETFOLDMARGINCOLOUR, 1, Sci(gutter));
	SciCall(view, SCI_SETFOLDMARGINHICOLOUR, 1, Sci(gutter));
	for (int marker = SC_MARKNUM_FOLDEREND; marker <= SC_MARKNUM_FOLDEROPEN; ++marker)
	{
		SciCall(view, SCI_MARKERSETFORE, marker, Sci(gutter));
		SciCall(view, SCI_MARKERSETBACK, marker, Sci(theme.Color("foldMarker", 0x808080)));
		SciCall(view, SCI_MARKERSETBACKSELECTED, marker, Sci(theme.Color("foldActive", 0x3D7BF7)));
	}

	SciCall(view, SCI_SETMARGINBACKN, kMarginBookmarks, Sci(gutter));
	SciCall(view, SCI_SETMARGINBACKN, kMarginChangeHistory, Sci(gutter));
	const unsigned bookmark = theme.Color("bookmark", 0x3D7BF7);
	SciCall(view, SCI_MARKERSETFORE, kMarkerBookmark, Sci(bookmark));
	SciCall(view, SCI_MARKERSETBACK, kMarkerBookmark, Sci(bookmark));

	const struct
	{
		const char *key;
		int marker;
		unsigned fallback;
	} history[] = {
		{"changeModified", SC_MARKNUM_HISTORY_MODIFIED, 0xF0A33A},
		{"changeRevertedModified", SC_MARKNUM_HISTORY_REVERTED_TO_MODIFIED, 0x7FC7A8},
		{"changeRevertedOrigin", SC_MARKNUM_HISTORY_REVERTED_TO_ORIGIN, 0x8FA8D8},
		{"changeSaved", SC_MARKNUM_HISTORY_SAVED, 0x3DAA5C},
	};
	for (const auto &entry : history)
	{
		const int colour = Sci(theme.Color(entry.key, entry.fallback));
		SciCall(view, SCI_MARKERSETFORE, entry.marker, colour);
		SciCall(view, SCI_MARKERSETBACK, entry.marker, colour);
	}

	SciCall(view, SCI_INDICSETFORE, kIndicatorSmartHighlight, Sci(theme.Color("smartHighlight", 0xFFD84D)));
	SciCall(view, SCI_INDICSETFORE, kIndicatorMarkAll, Sci(theme.Color("markAll", 0x59A8FF)));

	// Call tips and the auto-completion list follow the theme too.
	SciCall(view, SCI_CALLTIPSETBACK, Sci(background));
	SciCall(view, SCI_CALLTIPSETFORE, Sci(foreground));
}

} // namespace

void ConfigureEditor(ScintillaView *view)
{
	SciCall(view, SCI_SETCODEPAGE, SC_CP_UTF8);
	SciCall(view, SCI_SETMODEVENTMASK, SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT);

	SciCall(view, SCI_SETMARGINS, 4);
	SciCall(view, SCI_SETMARGINTYPEN, kMarginLineNumbers, SC_MARGIN_NUMBER);
	SciCall(view, SCI_SETMARGINMASKN, kMarginLineNumbers, 0);

	SciCall(view, SCI_SETMARGINTYPEN, kMarginBookmarks, SC_MARGIN_COLOUR);
	SciCall(view, SCI_SETMARGINMASKN, kMarginBookmarks, 1 << kMarkerBookmark);
	SciCall(view, SCI_SETMARGINWIDTHN, kMarginBookmarks, 14);
	SciCall(view, SCI_SETMARGINSENSITIVEN, kMarginBookmarks, 1);

	SciCall(view, SCI_SETMARGINTYPEN, kMarginChangeHistory, SC_MARGIN_COLOUR);
	SciCall(view, SCI_SETMARGINMASKN, kMarginChangeHistory, SC_MASK_HISTORY);

	SciCall(view, SCI_SETMARGINTYPEN, kMarginFold, SC_MARGIN_SYMBOL);
	SciCall(view, SCI_SETMARGINMASKN, kMarginFold, SC_MASK_FOLDERS);
	SciCall(view, SCI_SETMARGINWIDTHN, kMarginFold, 14);
	SciCall(view, SCI_SETMARGINSENSITIVEN, kMarginFold, 1);

	// "Box tree" folder style.
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPEN, SC_MARK_BOXMINUS);
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDER, SC_MARK_BOXPLUS);
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDERSUB, SC_MARK_VLINE);
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDERTAIL, SC_MARK_LCORNER);
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEREND, SC_MARK_BOXPLUSCONNECTED);
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDEROPENMID, SC_MARK_BOXMINUSCONNECTED);
	SciCall(view, SCI_MARKERDEFINE, SC_MARKNUM_FOLDERMIDTAIL, SC_MARK_TCORNER);
	SciCall(view, SCI_MARKERENABLEHIGHLIGHT, 1);
	SciCall(view, SCI_SETAUTOMATICFOLD, SC_AUTOMATICFOLD_SHOW | SC_AUTOMATICFOLD_CLICK | SC_AUTOMATICFOLD_CHANGE);
	SciCall(view, SCI_SETFOLDFLAGS, SC_FOLDFLAG_LINEAFTER_CONTRACTED);

	SciCall(view, SCI_MARKERDEFINE, kMarkerBookmark, SC_MARK_BOOKMARK);

	for (int indicator : {static_cast<int>(kIndicatorSmartHighlight), static_cast<int>(kIndicatorMarkAll)})
	{
		SciCall(view, SCI_INDICSETSTYLE, indicator, INDIC_ROUNDBOX);
		SciCall(view, SCI_INDICSETALPHA, indicator, 100);
		SciCall(view, SCI_INDICSETOUTLINEALPHA, indicator, 160);
		SciCall(view, SCI_INDICSETUNDER, indicator, 1);
	}

	SciCall(view, SCI_SETMULTIPLESELECTION, 1);
	SciCall(view, SCI_SETADDITIONALSELECTIONTYPING, 1);
	SciCall(view, SCI_SETMULTIPASTE, SC_MULTIPASTE_EACH);
	SciCall(view, SCI_SETVIRTUALSPACEOPTIONS, SCVS_RECTANGULARSELECTION);
	SciCall(view, SCI_SETCARETLINEVISIBLEALWAYS, 1);
	SciCall(view, SCI_SETSCROLLWIDTH, 1);
	SciCall(view, SCI_SETSCROLLWIDTHTRACKING, 1);
	SciCall(view, SCI_SETTABINDENTS, 1);
	SciCall(view, SCI_SETBACKSPACEUNINDENTS, 1);
	SciCall(view, SCI_SETINDENT, 0); // follow the tab width

	// Auto-completion list: one word per line, sorted by Scintilla, matched without regard to case.
	SciCall(view, SCI_AUTOCSETSEPARATOR, '\n');
	SciCall(view, SCI_AUTOCSETTYPESEPARATOR, 0x1E); // words such as Ruby's "empty?" are not image types
	SciCall(view, SCI_AUTOCSETORDER, SC_ORDER_PERFORMSORT);
	SciCall(view, SCI_AUTOCSETIGNORECASE, 1);
	SciCall(view, SCI_AUTOCSETMAXHEIGHT, 10);
	SciCall(view, SCI_AUTOCSETDROPRESTOFWORD, 0);
	SciCall(view, SCI_AUTOCSETCHOOSESINGLE, 0);
}

void ApplyLanguage(ScintillaView *view, const Language &language, const Theme &theme, const EditorFont &font)
{
	// Default style first, then copy it to every style.
	SciCallString(view, SCI_STYLESETFONT, STYLE_DEFAULT, font.name.empty() ? ToStdString(kDefaultFont) : font.name);
	SciCall(view, SCI_STYLESETSIZE, STYLE_DEFAULT, font.size > 0 ? font.size : kDefaultFontSize);
	SciCall(view, SCI_STYLESETFORE, STYLE_DEFAULT, Sci(theme.Foreground()));
	SciCall(view, SCI_STYLESETBACK, STYLE_DEFAULT, Sci(theme.Background()));
	SciCall(view, SCI_STYLESETBOLD, STYLE_DEFAULT, 0);
	SciCall(view, SCI_STYLESETITALIC, STYLE_DEFAULT, 0);
	SciCall(view, SCI_STYLESETUNDERLINE, STYLE_DEFAULT, 0);
	SciCall(view, SCI_STYLECLEARALL);

	Scintilla::ILexer5 *lexer = CreateLexer(language.lexer.c_str());
	if (!lexer)
		lexer = CreateLexer("null");
	SciCall(view, SCI_SETILEXER, 0, reinterpret_cast<sptr_t>(lexer));

	// Each style of the lexer takes the style of its role in the theme.
	if (const std::vector<StyleRole> *roles = StyleMap::Shared().RolesForLexer(language.lexer))
	{
		for (size_t style = 0; style < roles->size(); ++style)
		{
			const bool predefined = style >= STYLE_DEFAULT && style <= STYLE_LASTPREDEFINED;
			if ((*roles)[style] != StyleRole::Default && !predefined)
				SetRoleStyle(view, static_cast<int>(style), theme.Style((*roles)[style]));
		}
	}

	ApplyKeywordsAndProperties(view, language);
	ApplyGlobalColours(view, theme);

	SciCall(view, SCI_COLOURISE, 0, -1);
}

void ApplyCaretLine(ScintillaView *view, const Theme &theme, bool visible)
{
	if (visible)
		SciCall(view, SCI_SETELEMENTCOLOUR, SC_ELEMENT_CARET_LINE_BACK, SciOpaque(Sci(theme.Color("caretLine", 0xF3F6FB))));
	else
		SciCall(view, SCI_RESETELEMENTCOLOUR, SC_ELEMENT_CARET_LINE_BACK);
}

void ApplyViewSettings(ScintillaView *view, const EditorViewSettings &settings)
{
	SciCall(view, SCI_SETWRAPMODE, settings.wordWrap ? SC_WRAP_WORD : SC_WRAP_NONE);
	SciCall(view, SCI_SETVIEWWS, settings.showWhitespace ? SCWS_VISIBLEALWAYS : SCWS_INVISIBLE);
	SciCall(view, SCI_SETVIEWEOL, settings.showEndOfLine);
	SciCall(view, SCI_SETINDENTATIONGUIDES, settings.showIndentGuides ? SC_IV_LOOKBOTH : SC_IV_NONE);
	SciCall(view, SCI_SETTABWIDTH, settings.tabWidth > 0 ? settings.tabWidth : 4);
	SciCall(view, SCI_SETUSETABS, !settings.useSpaces);
	SciCall(view, SCI_SETMARGINWIDTHN, kMarginChangeHistory, settings.showChangeHistory ? 5 : 0);
	SciCall(view, SCI_SETEDGECOLUMN, settings.edgeColumn);
	SciCall(view, SCI_SETEDGEMODE, settings.edgeColumn > 0 ? EDGE_LINE : EDGE_NONE);
	if (SciCall(view, SCI_GETZOOM) != settings.zoom)
		SciCall(view, SCI_SETZOOM, settings.zoom);
	UpdateLineNumberMargin(view, settings.showLineNumbers);
}

void UpdateLineNumberMargin(ScintillaView *view, bool visible)
{
	if (!visible)
	{
		SciCall(view, SCI_SETMARGINWIDTHN, kMarginLineNumbers, 0);
		return;
	}
	sptr_t lines = SciCall(view, SCI_GETLINECOUNT);
	int digits = 1;
	while (lines >= 10)
	{
		lines /= 10;
		++digits;
	}
	if (digits < 3)
		digits = 3;
	const sptr_t digitWidth = SciCall(view, SCI_TEXTWIDTH, STYLE_LINENUMBER, reinterpret_cast<sptr_t>("8"));
	const sptr_t width = digitWidth * digits + 10;
	if (SciCall(view, SCI_GETMARGINWIDTHN, kMarginLineNumbers) != width)
		SciCall(view, SCI_SETMARGINWIDTHN, kMarginLineNumbers, width);
}
