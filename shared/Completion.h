// Word lists for auto-completion: the keywords of a language and the words of the document.
// Shared by the macOS and iOS apps.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#include <string>
#include <vector>

struct Language;

// True for the bytes that make up a word: letters, digits, '_' and anything non-ASCII.
bool IsCompletionWordByte(unsigned char c);

// Keywords of a language, sorted and without duplicates. Built once per language.
const std::vector<std::string> &LanguageCompletionWords(const Language &language);

// Appends the words of `text` that start with `prefix` (compared without regard to ASCII case)
// and are longer than it. Words that start with a digit are skipped.
void CollectWordsWithPrefix(const char *text, size_t length, const std::string &prefix, std::vector<std::string> &words);

// Words of `candidates` starting with `prefix`, without regard to ASCII case.
void FilterWordsWithPrefix(const std::vector<std::string> &candidates, const std::string &prefix, std::vector<std::string> &words);

// Sorts, removes duplicates and joins with '\n' for SCI_AUTOCSHOW. At most `limit` words.
std::string JoinCompletionWords(std::vector<std::string> &words, size_t limit);
