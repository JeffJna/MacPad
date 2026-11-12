// Languages MacPad knows: names, how files are recognised, comment tokens, the Lexilla
// lexer and its keyword lists. Read from languages.json (see tools/gen-data.py).
// Shared by the macOS and iOS apps.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#include <string>
#include <utility>
#include <vector>

// Lexilla lexers take up to nine keyword lists.
constexpr int KW_COUNT = 9;

struct Language
{
	std::string name;        // id ("cpp", "python"), stored in sessions and settings
	std::string menuName;    // shown in the Language menu and the status bar ("C++")
	std::string description; // same as menuName
	std::string lexer;       // Lexilla lexer name ("cpp")
	bool hidden = false;
	std::vector<std::string> extensions;   // lower case, without the dot
	std::vector<std::string> filenames;    // exact file names ("Makefile")
	std::vector<std::string> interpreters; // for #! lines ("python3")
	std::vector<std::string> firstLine;    // lower case prefixes of the first line ("<?xml")
	std::string commentLine;
	std::string commentStart;
	std::string commentEnd;
	std::string keywords[KW_COUNT];
	std::vector<std::pair<std::string, std::string>> properties; // Lexilla lexer properties
};

class LanguageCatalog
{
public:
	static LanguageCatalog &Shared();

	// Reads languages.json. Returns false (and keeps only Normal Text) if it cannot.
	bool Load(const std::string &path);

	const std::vector<Language> &All() const { return _languages; }
	const Language *Find(const std::string &name) const;
	const Language &NormalText() const;

	// Picks a language from the file name, then from the beginning of the text (#! line,
	// <?xml ...). `start` may be the whole text; only its first few kilobytes are looked at.
	const Language &Detect(const std::string &fileName, const std::string &start) const;

private:
	LanguageCatalog();
	std::vector<Language> _languages;
};
