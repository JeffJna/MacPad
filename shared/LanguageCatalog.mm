// Languages MacPad knows, read from languages.json.
// This file is part of MacPad (GPL v3 or later).
#import <Foundation/Foundation.h>

#include "LanguageCatalog.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <strings.h>

namespace
{

std::string ToLower(std::string text)
{
	std::transform(text.begin(), text.end(), text.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
	return text;
}

std::string String(id value)
{
	if (![value isKindOfClass: [NSString class]])
		return std::string();
	const char *utf8 = [(NSString *)value UTF8String];
	return utf8 ? std::string(utf8) : std::string();
}

std::vector<std::string> Strings(id value, bool lower)
{
	std::vector<std::string> result;
	if (![value isKindOfClass: [NSArray class]])
		return result;
	for (id item : (NSArray *)value)
	{
		std::string text = String(item);
		if (!text.empty())
			result.push_back(lower ? ToLower(text) : text);
	}
	return result;
}

bool Contains(const std::vector<std::string> &list, const std::string &value)
{
	return std::find(list.begin(), list.end(), value) != list.end();
}

// The interpreter named by a #! line: "/usr/bin/env -S python3 -u" gives "python3".
std::string Interpreter(const std::string &line)
{
	std::vector<std::string> words;
	std::string current;
	for (size_t i = 2; i <= line.size(); ++i)
	{
		const char c = i < line.size() ? line[i] : ' ';
		if (std::isspace(static_cast<unsigned char>(c)))
		{
			if (!current.empty())
				words.push_back(current);
			current.clear();
		}
		else
		{
			current += c;
		}
	}
	for (size_t i = 0; i < words.size(); ++i)
	{
		std::string word = words[i];
		const size_t slash = word.rfind('/');
		if (slash != std::string::npos)
			word = word.substr(slash + 1);
		if (word == "env" || (!word.empty() && word[0] == '-'))
			continue;
		return word;
	}
	return std::string();
}

} // namespace

LanguageCatalog &LanguageCatalog::Shared()
{
	static LanguageCatalog catalog;
	return catalog;
}

LanguageCatalog::LanguageCatalog()
{
	Language normal;
	normal.name = "normal";
	normal.menuName = normal.description = "Normal Text";
	normal.lexer = "null";
	_languages.push_back(normal);
}

bool LanguageCatalog::Load(const std::string &path)
{
	NSData *data = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: path.c_str()]];
	NSDictionary *root = data ? [NSJSONSerialization JSONObjectWithData: data options: 0 error: nil] : nil;
	NSArray *entries = [root isKindOfClass: [NSDictionary class]] ? root[@"languages"] : nil;
	if (![entries isKindOfClass: [NSArray class]])
		return false;

	std::vector<Language> languages;
	for (NSDictionary *entry in entries)
	{
		if (![entry isKindOfClass: [NSDictionary class]])
			continue;
		Language language;
		language.name = String(entry[@"id"]);
		language.menuName = language.description = String(entry[@"name"]);
		language.lexer = String(entry[@"lexer"]);
		if (language.name.empty() || language.lexer.empty())
			continue;
		if (language.menuName.empty())
			language.menuName = language.description = language.name;
		language.hidden = [entry[@"hidden"] boolValue];
		language.extensions = Strings(entry[@"extensions"], true);
		language.filenames = Strings(entry[@"filenames"], false);
		language.interpreters = Strings(entry[@"interpreters"], false);
		language.firstLine = Strings(entry[@"firstLine"], true);

		NSDictionary *comment = entry[@"comment"];
		if ([comment isKindOfClass: [NSDictionary class]])
		{
			language.commentLine = String(comment[@"line"]);
			language.commentStart = String(comment[@"start"]);
			language.commentEnd = String(comment[@"end"]);
		}
		NSDictionary *keywords = entry[@"keywords"];
		if ([keywords isKindOfClass: [NSDictionary class]])
		{
			for (NSString *key in keywords)
			{
				const int index = key.intValue;
				if (index >= 0 && index < KW_COUNT)
					language.keywords[index] = String(keywords[key]);
			}
		}
		NSDictionary *properties = entry[@"properties"];
		if ([properties isKindOfClass: [NSDictionary class]])
		{
			for (NSString *key in [properties.allKeys sortedArrayUsingSelector: @selector(compare:)])
				language.properties.emplace_back(String(key), String(properties[key]));
		}
		languages.push_back(std::move(language));
	}

	// Normal Text always comes first.
	auto normal = std::find_if(languages.begin(), languages.end(), [](const Language &l) { return l.name == "normal"; });
	if (normal == languages.end())
		languages.insert(languages.begin(), _languages.front());
	else
		std::rotate(languages.begin(), normal, normal + 1);
	_languages.swap(languages);
	return true;
}

const Language *LanguageCatalog::Find(const std::string &name) const
{
	for (const Language &language : _languages)
	{
		if (language.name == name)
			return &language;
	}
	return nullptr;
}

const Language &LanguageCatalog::NormalText() const
{
	return _languages.front();
}

const Language &LanguageCatalog::Detect(const std::string &fileName, const std::string &start) const
{
	// Exact file names first: "Makefile", "CMakeLists.txt", ".bashrc".
	for (const Language &language : _languages)
	{
		for (const std::string &name : language.filenames)
		{
			if (strcasecmp(name.c_str(), fileName.c_str()) == 0)
				return language;
		}
	}

	const std::string lowerName = ToLower(fileName);
	const size_t dot = lowerName.rfind('.');
	if (dot != std::string::npos && dot + 1 < lowerName.size())
	{
		const std::string ext = lowerName.substr(dot + 1);
		// ".m" is Objective-C on a Mac far more often than MATLAB: look at the text.
		if (ext == "m")
		{
			const std::string head = start.substr(0, 4096);
			for (const char *marker : {"#import", "#include", "@interface", "@implementation", "@property", "@protocol"})
			{
				if (head.find(marker) != std::string::npos)
				{
					if (const Language *objc = Find("objc"))
						return *objc;
				}
			}
		}
		for (const Language &language : _languages)
		{
			if (Contains(language.extensions, ext))
				return language;
		}
	}

	// The first line: #! interpreters and well-known headers.
	const size_t lineEnd = start.find_first_of("\r\n");
	std::string line = start.substr(0, std::min<size_t>(lineEnd == std::string::npos ? start.size() : lineEnd, 512));
	if (line.compare(0, 3, "\xEF\xBB\xBF") == 0)
		line.erase(0, 3);
	if (line.compare(0, 2, "#!") == 0)
	{
		std::string interpreter = Interpreter(line);
		while (!interpreter.empty())
		{
			for (const Language &language : _languages)
			{
				if (Contains(language.interpreters, interpreter))
					return language;
			}
			// python3.12 -> python3 -> python
			const size_t keep = interpreter.find_last_not_of("0123456789.");
			if (keep == std::string::npos || keep + 1 == interpreter.size())
				break;
			interpreter.erase(keep + 1);
		}
	}
	const std::string lowerLine = ToLower(line);
	for (const Language &language : _languages)
	{
		for (const std::string &prefix : language.firstLine)
		{
			if (lowerLine.compare(0, prefix.size(), prefix) == 0)
				return language;
		}
	}
	return NormalText();
}
