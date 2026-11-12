// Small helpers shared by the macOS front end.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>
#import "ScintillaView.h"

#include <string>

#include "Scintilla.h"
#include "SciLexer.h"

#include "TextEncoding.h"

// Send a message to a Scintilla view (the Cocoa equivalent of SendMessage on Windows).
static inline sptr_t SciCall(ScintillaView *view, unsigned int message, uptr_t wParam = 0, sptr_t lParam = 0)
{
	return [view message: message wParam: wParam lParam: lParam];
}

static inline sptr_t SciCallString(ScintillaView *view, unsigned int message, uptr_t wParam, const std::string &text)
{
	return [view message: message wParam: wParam lParam: reinterpret_cast<sptr_t>(text.c_str())];
}

static inline NSString *ToNSString(const std::string &text)
{
	NSString *result = [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSUTF8StringEncoding];
	return result ?: @"";
}

static inline std::string ToStdString(NSString *text)
{
	const char *utf8 = text.UTF8String;
	return utf8 ? std::string(utf8) : std::string();
}

// Style sheets store colours as RRGGBB; Scintilla wants 0xBBGGRR.
static inline int SciColourFromRGB(unsigned int rgb)
{
	return static_cast<int>(((rgb & 0x0000FF) << 16) | (rgb & 0x00FF00) | ((rgb & 0xFF0000) >> 16));
}

// Colour with opaque alpha, for SCI_SETELEMENTCOLOUR.
static inline sptr_t SciOpaque(int colour)
{
	return static_cast<sptr_t>(static_cast<unsigned int>(colour) | 0xFF000000u);
}

// Text from the Scintilla document between two byte positions.
static inline std::string SciTextRange(ScintillaView *view, sptr_t start, sptr_t end)
{
	if (end <= start)
		return std::string();
	std::string text(static_cast<size_t>(end - start), '\0');
	Sci_TextRangeFull range;
	range.chrg.cpMin = start;
	range.chrg.cpMax = end;
	range.lpstrText = text.data();
	SciCall(view, SCI_GETTEXTRANGEFULL, 0, reinterpret_cast<sptr_t>(&range));
	return text;
}

// Pointer to the whole document (valid until the next modification).
static inline std::string SciDocumentText(ScintillaView *view)
{
	const sptr_t length = SciCall(view, SCI_GETLENGTH);
	const char *data = reinterpret_cast<const char *>(SciCall(view, SCI_GETCHARACTERPOINTER));
	return data ? std::string(data, static_cast<size_t>(length)) : std::string();
}

static inline int LineEndingToSciMode(LineEnding eol)
{
	switch (eol)
	{
		case LineEnding::CRLF:
			return SC_EOL_CRLF;
		case LineEnding::CR:
			return SC_EOL_CR;
		case LineEnding::LF:
			return SC_EOL_LF;
	}
	return SC_EOL_LF;
}
