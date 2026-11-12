// Word lists for auto-completion: language keywords and the words of the document.
// This file is part of MacPad (GPL v3 or later).
#include "Completion.h"

#include <algorithm>
#include <cctype>
#include <map>
#include <strings.h>

#include "LanguageCatalog.h"

namespace
{

bool HasPrefixIgnoringCase(const char *word, size_t length, const std::string &prefix)
{
	return length >= prefix.size() && strncasecmp(word, prefix.data(), prefix.size()) == 0;
}

void AddKeywords(const std::string &list, std::vector<std::string> &words)
{
	std::string current;
	for (const char c : list)
	{
		if (std::isspace(static_cast<unsigned char>(c)))
		{
			if (current.size() > 1)
				words.push_back(current);
			current.clear();
		}
		else
		{
			current.push_back(c);
		}
	}
	if (current.size() > 1)
		words.push_back(current);
}

} // namespace

bool IsCompletionWordByte(unsigned char c)
{
	return std::isalnum(c) || c == '_' || c >= 0x80;
}

const std::vector<std::string> &LanguageCompletionWords(const Language &language)
{
	static std::map<std::string, std::vector<std::string>> cache;
	auto found = cache.find(language.name);
	if (found != cache.end())
		return found->second;

	std::vector<std::string> words;
	for (const std::string &keywords : language.keywords)
		AddKeywords(keywords, words);
	// Only words that can be typed as one word: no "@interface" or "#define".
	words.erase(std::remove_if(words.begin(), words.end(), [](const std::string &word) {
		return !IsCompletionWordByte(static_cast<unsigned char>(word[0])) || std::isdigit(static_cast<unsigned char>(word[0]));
	}), words.end());
	std::sort(words.begin(), words.end());
	words.erase(std::unique(words.begin(), words.end()), words.end());
	return cache.emplace(language.name, std::move(words)).first->second;
}

void CollectWordsWithPrefix(const char *text, size_t length, const std::string &prefix, std::vector<std::string> &words)
{
	if (!text || prefix.empty())
		return;
	size_t i = 0;
	while (i < length)
	{
		if (!IsCompletionWordByte(static_cast<unsigned char>(text[i])))
		{
			++i;
			continue;
		}
		const size_t start = i;
		while (i < length && IsCompletionWordByte(static_cast<unsigned char>(text[i])))
			++i;
		const size_t wordLength = i - start;
		if (wordLength > prefix.size() && wordLength <= 128 && !std::isdigit(static_cast<unsigned char>(text[start])) &&
		    HasPrefixIgnoringCase(text + start, wordLength, prefix))
			words.emplace_back(text + start, wordLength);
	}
}

void FilterWordsWithPrefix(const std::vector<std::string> &candidates, const std::string &prefix, std::vector<std::string> &words)
{
	for (const std::string &candidate : candidates)
	{
		if (HasPrefixIgnoringCase(candidate.data(), candidate.size(), prefix))
			words.push_back(candidate);
	}
}

std::string JoinCompletionWords(std::vector<std::string> &words, size_t limit)
{
	std::sort(words.begin(), words.end());
	words.erase(std::unique(words.begin(), words.end()), words.end());
	std::string joined;
	size_t count = 0;
	for (const std::string &word : words)
	{
		if (count++ >= limit)
			break;
		if (!joined.empty())
			joined += '\n';
		joined += word;
	}
	return joined;
}
