// Text utilities behind the Tools menu and the extra case conversions.
// This file is part of MacPad (GPL v3 or later).
#import "TextTools.h"

#include <CommonCrypto/CommonDigest.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <functional>
#include <strings.h>
#include <unordered_set>

namespace
{

std::string ToHex(const unsigned char *bytes, size_t length)
{
	static const char digits[] = "0123456789abcdef";
	std::string hex;
	hex.reserve(length * 2);
	for (size_t i = 0; i < length; ++i)
	{
		hex += digits[bytes[i] >> 4];
		hex += digits[bytes[i] & 0x0F];
	}
	return hex;
}

NSString *ToNSString(const std::string &text)
{
	return [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSUTF8StringEncoding];
}

std::string ToStdString(NSString *text)
{
	NSData *data = [text dataUsingEncoding: NSUTF8StringEncoding];
	return std::string(static_cast<const char *>(data.bytes), data.length);
}

} // namespace

std::string HashHex(const std::string &bytes, HashAlgorithm algorithm)
{
	unsigned char digest[CC_SHA512_DIGEST_LENGTH];
	const CC_LONG length = static_cast<CC_LONG>(bytes.size());
	switch (algorithm)
	{
		case HashAlgorithm::MD5:
// MD5 and SHA-1 are offered as checksums, not for security.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			CC_MD5(bytes.data(), length, digest);
#pragma clang diagnostic pop
			return ToHex(digest, CC_MD5_DIGEST_LENGTH);
		case HashAlgorithm::SHA1:
			CC_SHA1(bytes.data(), length, digest);
			return ToHex(digest, CC_SHA1_DIGEST_LENGTH);
		case HashAlgorithm::SHA256:
			CC_SHA256(bytes.data(), length, digest);
			return ToHex(digest, CC_SHA256_DIGEST_LENGTH);
		case HashAlgorithm::SHA512:
			CC_SHA512(bytes.data(), length, digest);
			return ToHex(digest, CC_SHA512_DIGEST_LENGTH);
	}
	return std::string();
}

std::string Base64Encode(const std::string &bytes)
{
	NSData *data = [NSData dataWithBytes: bytes.data() length: bytes.size()];
	return ToStdString([data base64EncodedStringWithOptions: 0]);
}

bool Base64Decode(const std::string &text, std::string &bytes)
{
	// Line breaks and spaces are fine (wrapped Base64); anything else must be valid.
	std::string compact;
	for (const char c : text)
	{
		if (!std::isspace(static_cast<unsigned char>(c)))
			compact += c == '-' ? '+' : (c == '_' ? '/' : c); // accept the URL-safe alphabet too
	}
	if (compact.empty())
		return false;
	while (compact.size() % 4)
		compact += '=';
	NSString *string = ToNSString(compact);
	NSData *data = string ? [[NSData alloc] initWithBase64EncodedString: string options: 0] : nil;
	if (!data)
		return false;
	bytes.assign(static_cast<const char *>(data.bytes), data.length);
	return true;
}

std::string URLEncode(const std::string &text)
{
	static const char digits[] = "0123456789ABCDEF";
	std::string encoded;
	for (const unsigned char c : text)
	{
		if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~')
		{
			encoded += static_cast<char>(c);
		}
		else
		{
			encoded += '%';
			encoded += digits[c >> 4];
			encoded += digits[c & 0x0F];
		}
	}
	return encoded;
}

bool URLDecode(const std::string &text, std::string &decoded)
{
	auto hexValue = [](char c) -> int {
		if (c >= '0' && c <= '9')
			return c - '0';
		if (c >= 'a' && c <= 'f')
			return c - 'a' + 10;
		if (c >= 'A' && c <= 'F')
			return c - 'A' + 10;
		return -1;
	};
	decoded.clear();
	for (size_t i = 0; i < text.size(); ++i)
	{
		if (text[i] == '%')
		{
			if (i + 2 >= text.size())
				return false;
			const int high = hexValue(text[i + 1]);
			const int low = hexValue(text[i + 2]);
			if (high < 0 || low < 0)
				return false;
			decoded += static_cast<char>(high * 16 + low);
			i += 2;
		}
		else
		{
			decoded += text[i] == '+' ? ' ' : text[i];
		}
	}
	return true;
}

bool FormatJSON(const std::string &text, bool minify, const std::string &indent, const std::string &eol,
                std::string &formatted, std::string &error)
{
	// Validate first, so that the reformatting below can assume well-formed input.
	NSData *data = [NSData dataWithBytes: text.data() length: text.size()];
	NSError *parseError = nil;
	if (![NSJSONSerialization JSONObjectWithData: data options: NSJSONReadingFragmentsAllowed error: &parseError])
	{
		NSString *detail = parseError.userInfo[NSDebugDescriptionErrorKey] ?: parseError.localizedDescription;
		error = ToStdString(detail ?: @"The text is not valid JSON.");
		return false;
	}

	std::string out;
	out.reserve(text.size() + text.size() / 4);
	int depth = 0;
	auto newLine = [&]() {
		if (minify)
			return;
		out += eol;
		for (int i = 0; i < depth; ++i)
			out += indent;
	};

	const size_t length = text.size();
	size_t i = 0;
	// Skip a byte order mark copied along with the text.
	if (length >= 3 && text.compare(0, 3, "\xEF\xBB\xBF") == 0)
		i = 3;
	while (i < length)
	{
		const char c = text[i];
		if (std::isspace(static_cast<unsigned char>(c)))
		{
			++i;
		}
		else if (c == '"')
		{
			const size_t start = i++;
			while (i < length && text[i] != '"')
				i += text[i] == '\\' ? 2 : 1;
			i = std::min(i + 1, length);
			out.append(text, start, i - start);
		}
		else if (c == '{' || c == '[')
		{
			// Empty containers stay on one line: {} and [].
			size_t next = i + 1;
			while (next < length && std::isspace(static_cast<unsigned char>(text[next])))
				++next;
			out += c;
			if (next < length && text[next] == (c == '{' ? '}' : ']'))
			{
				out += text[next];
				i = next + 1;
			}
			else
			{
				++depth;
				newLine();
				++i;
			}
		}
		else if (c == '}' || c == ']')
		{
			depth = std::max(depth - 1, 0);
			newLine();
			out += c;
			++i;
		}
		else if (c == ',')
		{
			out += c;
			newLine();
			++i;
		}
		else if (c == ':')
		{
			out += minify ? ":" : ": ";
			++i;
		}
		else
		{
			// Numbers, true, false, null: copied exactly as written.
			const size_t start = i;
			while (i < length && !std::isspace(static_cast<unsigned char>(text[i])) && text[i] != ',' && text[i] != '}' &&
			       text[i] != ']' && text[i] != ':')
				++i;
			out.append(text, start, i - start);
		}
	}
	formatted.swap(out);
	return true;
}

std::string ConvertCase(const std::string &utf8, CaseStyle style)
{
	NSString *text = ToNSString(utf8);
	if (!text)
		return utf8; // not valid UTF-8: leave it alone
	NSMutableString *result = [NSMutableString stringWithCapacity: text.length];
	NSCharacterSet *letters = [NSCharacterSet letterCharacterSet];
	NSCharacterSet *upper = [NSCharacterSet uppercaseLetterCharacterSet];
	__block BOOL startOfWord = YES;
	__block BOOL startOfSentence = YES;
	[text enumerateSubstringsInRange: NSMakeRange(0, text.length)
	                         options: NSStringEnumerationByComposedCharacterSequences
	                      usingBlock: ^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
		const unichar first = [character characterAtIndex: 0];
		const BOOL isLetter = [letters characterIsMember: first] || character.length > 1;
		NSString *converted = character;
		switch (style) {
			case CaseStyle::Proper:
				converted = startOfWord ? character.localizedUppercaseString : character.localizedLowercaseString;
				// Apostrophes stay inside a word: "don't" becomes "Don't", not "Don'T".
				startOfWord = !(isLetter || [[NSCharacterSet decimalDigitCharacterSet] characterIsMember: first] ||
				                first == '\'' || first == 0x2019);
				break;
			case CaseStyle::Sentence:
				if (isLetter) {
					converted = startOfSentence ? character.localizedUppercaseString : character.localizedLowercaseString;
					startOfSentence = NO;
				} else if (first == '.' || first == '!' || first == '?' || first == '\n' || first == '\r') {
					startOfSentence = YES;
				}
				break;
			case CaseStyle::Invert:
				converted = [upper characterIsMember: first] ? character.localizedLowercaseString : character.localizedUppercaseString;
				break;
		}
		[result appendString: converted];
	}];
	return ToStdString(result);
}

std::vector<std::string> SplitLines(const std::string &text)
{
	std::vector<std::string> lines;
	std::string current;
	for (size_t i = 0; i < text.size(); ++i)
	{
		const char c = text[i];
		if (c == '\r' || c == '\n')
		{
			lines.push_back(current);
			current.clear();
			if (c == '\r' && i + 1 < text.size() && text[i + 1] == '\n')
				++i;
		}
		else
		{
			current.push_back(c);
		}
	}
	lines.push_back(current);
	return lines;
}

std::string JoinLines(const std::vector<std::string> &lines, const std::string &eol)
{
	std::string result;
	for (size_t i = 0; i < lines.size(); ++i)
	{
		if (i)
			result += eol;
		result += lines[i];
	}
	return result;
}

namespace
{

std::string Trim(const std::string &text)
{
	const size_t first = text.find_first_not_of(" \t");
	if (first == std::string::npos)
		return std::string();
	const size_t last = text.find_last_not_of(" \t");
	return text.substr(first, last - first + 1);
}

std::string ExpandTabs(const std::string &line, int tabWidth)
{
	std::string out;
	int column = 0;
	for (char c : line)
	{
		if (c == '\t')
		{
			const int spaces = tabWidth - (column % tabWidth);
			out.append(static_cast<size_t>(spaces), ' ');
			column += spaces;
		}
		else
		{
			out.push_back(c);
			if ((static_cast<unsigned char>(c) & 0xC0) != 0x80)
				++column;
		}
	}
	return out;
}

std::string LeadingSpacesToTabs(const std::string &line, int tabWidth)
{
	size_t i = 0;
	int column = 0;
	for (; i < line.size() && (line[i] == ' ' || line[i] == '\t'); ++i)
		column = line[i] == '\t' ? (column / tabWidth + 1) * tabWidth : column + 1;
	std::string out(static_cast<size_t>(column / tabWidth), '\t');
	out.append(static_cast<size_t>(column % tabWidth), ' ');
	return out + line.substr(i);
}

} // namespace

void ApplyLineOperation(std::vector<std::string> &lines, LineOperation operation, int tabWidth)
{
	if (tabWidth <= 0)
		tabWidth = 4;
	switch (operation)
	{
		case LineOperation::SortAscending:
			std::stable_sort(lines.begin(), lines.end());
			break;
		case LineOperation::SortDescending:
			std::stable_sort(lines.begin(), lines.end(), std::greater<std::string>());
			break;
		case LineOperation::SortIgnoringCase:
			std::stable_sort(lines.begin(), lines.end(), [](const std::string &a, const std::string &b) {
				return strcasecmp(a.c_str(), b.c_str()) < 0;
			});
			break;
		case LineOperation::SortNumerically:
		{
			auto key = [](const std::string &line, double &value) {
				const char *text = line.c_str();
				char *end = nullptr;
				value = std::strtod(text, &end);
				return end != text;
			};
			std::stable_sort(lines.begin(), lines.end(), [&](const std::string &a, const std::string &b) {
				double x = 0, y = 0;
				const bool hasX = key(a, x);
				const bool hasY = key(b, y);
				if (hasX != hasY)
					return hasX;
				return hasX && x < y;
			});
			break;
		}
		case LineOperation::Reverse:
			std::reverse(lines.begin(), lines.end());
			break;
		case LineOperation::RemoveDuplicates:
		{
			std::unordered_set<std::string> seen;
			std::vector<std::string> unique;
			for (const std::string &line : lines)
			{
				if (seen.insert(line).second)
					unique.push_back(line);
			}
			lines.swap(unique);
			break;
		}
		case LineOperation::RemoveEmpty:
			lines.erase(std::remove_if(lines.begin(), lines.end(), [](const std::string &line) { return Trim(line).empty(); }),
			            lines.end());
			break;
		case LineOperation::TrimTrailing:
			for (std::string &line : lines)
			{
				const size_t last = line.find_last_not_of(" \t");
				line.erase(last == std::string::npos ? 0 : last + 1);
			}
			break;
		case LineOperation::TrimLeading:
			for (std::string &line : lines)
			{
				const size_t first = line.find_first_not_of(" \t");
				line.erase(0, first == std::string::npos ? line.size() : first);
			}
			break;
		case LineOperation::TrimBoth:
			for (std::string &line : lines)
				line = Trim(line);
			break;
		case LineOperation::TabsToSpaces:
			for (std::string &line : lines)
				line = ExpandTabs(line, tabWidth);
			break;
		case LineOperation::LeadingSpacesToTabs:
			for (std::string &line : lines)
				line = LeadingSpacesToTabs(line, tabWidth);
			break;
	}
}
