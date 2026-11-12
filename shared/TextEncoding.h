// File encodings: detection on load, conversion on save.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Foundation/Foundation.h>

#include <string>

struct FileEncoding
{
	enum Kind
	{
		UTF8,
		UTF8_BOM,
		UTF16LE_BOM,
		UTF16BE_BOM,
		Legacy, // single/multi byte code page described by cfEncoding
	};

	Kind kind = UTF8;
	CFStringEncoding cfEncoding = kCFStringEncodingUTF8;

	static FileEncoding Make(Kind kind) { FileEncoding e; e.kind = kind; return e; }
	static FileEncoding MakeLegacy(CFStringEncoding encoding)
	{
		FileEncoding e;
		e.kind = Legacy;
		e.cfEncoding = encoding;
		return e;
	}

	bool operator==(const FileEncoding &other) const
	{
		return kind == other.kind && (kind != Legacy || cfEncoding == other.cfEncoding);
	}
	bool operator!=(const FileEncoding &other) const { return !(*this == other); }

	// Name shown in the status bar ("UTF-8-BOM", "UTF-16 LE BOM").
	NSString *DisplayName() const;
};

enum class LineEnding
{
	CRLF, // Windows
	LF,   // Unix and macOS
	CR,   // classic Mac OS
};

NSString *LineEndingDisplayName(LineEnding eol);

// Decodes file bytes into UTF-8. When `forced` is given the bytes are read with that encoding
// (Encoding > Reopen with...), otherwise the encoding is detected.
bool DecodeText(NSData *data, std::string &utf8, FileEncoding &encoding, const FileEncoding *forced = nullptr);

// Encodes UTF-8 text for saving. Returns nil and fills `error` if a character cannot be represented.
NSData *EncodeText(const std::string &utf8, const FileEncoding &encoding, NSError **error);

// First line ending found in the text, or `fallback` when there is none.
LineEnding DetectLineEnding(const std::string &text, LineEnding fallback);
