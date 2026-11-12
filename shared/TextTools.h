// Text utilities: the Tools menu, case conversions and line operations.
// Shared by the macOS and iOS apps.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

enum class HashAlgorithm
{
	MD5,
	SHA1,
	SHA256,
	SHA512,
};

// Lower-case hexadecimal digest of the bytes.
std::string HashHex(const std::string &bytes, HashAlgorithm algorithm);

std::string Base64Encode(const std::string &bytes);
// Returns false when the text is not valid Base64.
bool Base64Decode(const std::string &text, std::string &bytes);

std::string URLEncode(const std::string &text);
bool URLDecode(const std::string &text, std::string &decoded);

// Re-indents (or, with `minify`, compacts) JSON without reordering keys or touching values.
// `indent` is one level of indentation ("\t" or spaces), `eol` the line ending to use.
// Returns false and fills `error` when the text is not valid JSON.
bool FormatJSON(const std::string &text, bool minify, const std::string &indent, const std::string &eol,
                std::string &formatted, std::string &error);

enum class CaseStyle
{
	Proper,   // Every Word Capitalised
	Sentence, // First word of each sentence
	Invert,   // sWAP cASE
};

std::string ConvertCase(const std::string &utf8, CaseStyle style);

// Lines of a text, split at CR LF, LF or CR. A final line ending gives a last, empty line.
std::vector<std::string> SplitLines(const std::string &text);
std::string JoinLines(const std::vector<std::string> &lines, const std::string &eol);

enum class LineOperation
{
	SortAscending,
	SortDescending,
	SortIgnoringCase,
	SortNumerically, // lines that do not start with a number keep their order after the others
	Reverse,
	RemoveDuplicates,
	RemoveEmpty,     // blank lines too
	TrimTrailing,
	TrimLeading,
	TrimBoth,
	TabsToSpaces,
	LeadingSpacesToTabs,
};

void ApplyLineOperation(std::vector<std::string> &lines, LineOperation operation, int tabWidth);
