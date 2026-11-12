// Text search outside the editor, used by Find in Files. It runs on a background queue, so it
// cannot use Scintilla: patterns are matched with NSRegularExpression (ICU syntax).
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Foundation/Foundation.h>

#include <string>
#include <vector>

struct SearchQuery
{
	std::string pattern; // UTF-8; escapes of the Extended mode already expanded
	bool matchCase = false;
	bool wholeWord = false;
	bool regex = false;
};

// One match, in the shape the results panel shows it.
struct SearchHit
{
	long line = 0;      // 0-based
	long start = 0;     // byte offsets in the UTF-8 text, as Scintilla counts positions
	long end = 0;
	std::string lineText;  // the whole line, cut down when it is very long
	size_t markStart = 0;  // the match inside lineText, in bytes
	size_t markLength = 0;
};

// Builds the regular expression for a query. Returns nil and fills `error` for a bad pattern.
NSRegularExpression *CompileSearchQuery(const SearchQuery &query, NSString **error);

// Finds the matches in a UTF-8 text. Stops after `limit` hits.
void SearchText(const std::string &utf8, NSRegularExpression *expression, std::vector<SearchHit> &hits, size_t limit);

// File filters: "*.cpp *.h" selects, "!*.min.js" excludes; "*.*" means every file.
struct FileFilter
{
	std::vector<std::string> include;
	std::vector<std::string> exclude;

	static FileFilter Parse(const std::string &text);
	bool Matches(const std::string &fileName) const;
};

// Makes a hit line fit for display: at most `limit` bytes around the match, tabs as spaces.
void TrimHitLine(SearchHit &hit, size_t limit);
