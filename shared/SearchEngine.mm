// Text search outside the editor, used by Find in Files.
// This file is part of MacPad (GPL v3 or later).
#import "SearchEngine.h"

#include <algorithm>
#include <cctype>
#include <fnmatch.h>

NSRegularExpression *CompileSearchQuery(const SearchQuery &query, NSString **error)
{
	NSString *pattern = [[NSString alloc] initWithBytes: query.pattern.data() length: query.pattern.size()
	                                           encoding: NSUTF8StringEncoding];
	if (!pattern.length)
	{
		if (error)
			*error = @"The search text is empty.";
		return nil;
	}
	if (!query.regex)
	{
		pattern = [NSRegularExpression escapedPatternForString: pattern];
		// "Whole word" as in the editor: no word character right before or after the match.
		if (query.wholeWord)
			pattern = [NSString stringWithFormat: @"(?<![\\w])%@(?![\\w])", pattern];
	}
	NSRegularExpressionOptions options = NSRegularExpressionAnchorsMatchLines;
	if (!query.matchCase)
		options |= NSRegularExpressionCaseInsensitive;
	NSError *compileError = nil;
	NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern: pattern options: options error: &compileError];
	if (!expression && error)
		*error = compileError.localizedDescription ?: @"The regular expression is not valid.";
	return expression;
}

namespace
{

// Walks forward through a text, turning UTF-16 indexes into byte offsets and line numbers.
struct TextWalker
{
	const std::vector<unichar> &units;
	bool latin1; // one byte per unit: the text was not valid UTF-8
	NSUInteger unit = 0;
	long byte = 0;
	long line = 0;
	long lineStartByte = 0;

	void AdvanceTo(NSUInteger target)
	{
		const NSUInteger length = units.size();
		while (unit < target && unit < length)
		{
			const unichar c = units[unit];
			if (latin1 || c < 0x80)
				byte += 1;
			else if (c < 0x800)
				byte += 2;
			else if (c >= 0xD800 && c <= 0xDBFF && unit + 1 < length)
			{
				byte += 4; // surrogate pair
				++unit;
			}
			else
				byte += 3;
			++unit;
			if (c == '\n' || (c == '\r' && !(unit < length && units[unit] == '\n')))
			{
				++line;
				lineStartByte = byte;
			}
		}
	}
};

} // namespace

void SearchText(const std::string &utf8, NSRegularExpression *expression, std::vector<SearchHit> &hits, size_t limit)
{
	if (utf8.empty() || !expression || hits.size() >= limit)
		return;
	// Bytes that are not valid UTF-8 are read as Latin-1, where one byte is one UTF-16 unit.
	bool latin1 = false;
	NSString *text = [[NSString alloc] initWithBytesNoCopy: const_cast<char *>(utf8.data()) length: utf8.size()
	                                              encoding: NSUTF8StringEncoding freeWhenDone: NO];
	if (!text)
	{
		latin1 = true;
		text = [[NSString alloc] initWithBytesNoCopy: const_cast<char *>(utf8.data()) length: utf8.size()
		                                    encoding: NSISOLatin1StringEncoding freeWhenDone: NO];
	}
	if (!text)
		return;

	const NSUInteger length = text.length;
	std::vector<unichar> units(length);
	[text getCharacters: units.data() range: NSMakeRange(0, length)];

	TextWalker state{units, latin1};
	TextWalker *walker = &state;
	const std::string *source = &utf8;
	std::vector<SearchHit> *results = &hits;
	[expression enumerateMatchesInString: text options: 0 range: NSMakeRange(0, length)
	                          usingBlock: ^(NSTextCheckingResult *result, NSMatchingFlags flags, BOOL *stop) {
		const NSRange range = result.range;
		if (range.location == NSNotFound || range.length == 0 || range.location < walker->unit)
			return;
		walker->AdvanceTo(range.location);
		SearchHit hit;
		hit.line = walker->line;
		hit.start = walker->byte;
		const size_t lineStart = static_cast<size_t>(walker->lineStartByte);
		walker->AdvanceTo(NSMaxRange(range));
		hit.end = walker->byte;

		// The line holding the start of the match (a match may run over several lines).
		size_t lineEnd = source->find_first_of("\r\n", static_cast<size_t>(hit.start));
		if (lineEnd == std::string::npos)
			lineEnd = source->size();
		hit.lineText = source->substr(lineStart, lineEnd - lineStart);
		hit.markStart = static_cast<size_t>(hit.start) - lineStart;
		hit.markLength = std::min(static_cast<size_t>(hit.end), lineEnd) - static_cast<size_t>(hit.start);
		results->push_back(std::move(hit));
		if (results->size() >= limit)
			*stop = YES;
	}];
}

void TrimHitLine(SearchHit &hit, size_t limit)
{
	std::string &text = hit.lineText;
	hit.markStart = std::min(hit.markStart, text.size());
	hit.markLength = std::min(hit.markLength, text.size() - hit.markStart);
	auto isContinuation = [&](size_t index) { return index < text.size() && (static_cast<unsigned char>(text[index]) & 0xC0) == 0x80; };

	if (text.size() > limit)
	{
		// Keep the match in view, starting a little before it; cut on character boundaries.
		size_t from = hit.markStart > limit / 4 ? hit.markStart - limit / 4 : 0;
		while (isContinuation(from))
			--from;
		size_t to = std::min(text.size(), from + limit);
		while (isContinuation(to))
			--to;
		text = text.substr(from, to - from);
		hit.markStart -= from;
		hit.markLength = std::min(hit.markLength, text.size() - std::min(hit.markStart, text.size()));
	}
	for (char &c : text)
	{
		if (c == '\t' || c == '\0')
			c = ' ';
	}
	// Leading indentation only pushes the interesting part away.
	size_t indent = 0;
	while (indent < hit.markStart && text[indent] == ' ')
		++indent;
	text.erase(0, indent);
	hit.markStart -= indent;
}

FileFilter FileFilter::Parse(const std::string &text)
{
	FileFilter filter;
	std::string token;
	auto flush = [&]() {
		if (token.empty())
			return;
		if (token[0] == '!')
		{
			if (token.size() > 1)
				filter.exclude.push_back(token.substr(1));
		}
		else if (token != "*.*" && token != "*")
		{
			filter.include.push_back(token);
		}
		token.clear();
	};
	for (const char c : text)
	{
		if (std::isspace(static_cast<unsigned char>(c)) || c == ';' || c == ',')
			flush();
		else
			token += c;
	}
	flush();
	return filter;
}

bool FileFilter::Matches(const std::string &fileName) const
{
	for (const std::string &pattern : exclude)
	{
		if (fnmatch(pattern.c_str(), fileName.c_str(), FNM_CASEFOLD) == 0)
			return false;
	}
	if (include.empty())
		return true;
	for (const std::string &pattern : include)
	{
		if (fnmatch(pattern.c_str(), fileName.c_str(), FNM_CASEFOLD) == 0)
			return true;
	}
	return false;
}
