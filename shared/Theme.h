// Themes: editor colours, and one text style per role ("comment", "keyword", ...).
// The style map tells which role each style number of a Lexilla lexer has, so a theme
// colours every language without knowing about it. Shared by the macOS and iOS apps.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#include <map>
#include <memory>
#include <string>
#include <vector>

enum class StyleRole
{
	Default,
	Comment,
	CommentDoc,
	CommentDocKeyword,
	Keyword,
	Keyword2,
	Type,
	Function,
	String,
	StringSpecial,
	Regex,
	Number,
	Operator,
	Preprocessor,
	Tag,
	Attribute,
	Label,
	Variable,
	Heading,
	Emphasis,
	Link,
	Added,
	Deleted,
	Changed,
	Error,
	Count
};

StyleRole StyleRoleFromName(const std::string &name);

// Colours are 0xRRGGBB.
struct ThemeStyle
{
	unsigned color = 0;
	bool hasBackground = false;
	unsigned background = 0;
	bool bold = false;
	bool italic = false;
	bool underline = false;
};

class Theme
{
public:
	static std::shared_ptr<Theme> LoadFromFile(const std::string &path);
	// A plain light theme, for when no theme file can be read.
	static std::shared_ptr<Theme> Fallback();

	const std::string &Name() const { return _name; }
	const std::string &Path() const { return _path; }
	bool IsDark() const { return _dark; }

	// Editor colour by key ("background", "caretLine", "selection", ...), or `fallback`.
	unsigned Color(const char *key, unsigned fallback) const;
	unsigned Background() const { return Color("background", 0xFFFFFF); }
	unsigned Foreground() const { return Color("foreground", 0x000000); }

	// The style of a role. Roles a theme leaves out borrow from a related one
	// (doc comments look like comments, regular expressions like strings, ...).
	const ThemeStyle &Style(StyleRole role) const { return _styles[static_cast<size_t>(role)]; }

private:
	void Resolve(const std::map<StyleRole, ThemeStyle> &given);

	std::string _name;
	std::string _path;
	bool _dark = false;
	std::map<std::string, unsigned> _colors;
	ThemeStyle _styles[static_cast<size_t>(StyleRole::Count)];
};

class StyleMap
{
public:
	static StyleMap &Shared();
	bool Load(const std::string &path);
	// Role of every style number of a lexer (styles not listed are Default), or null.
	const std::vector<StyleRole> *RolesForLexer(const std::string &lexer) const;

private:
	std::map<std::string, std::vector<StyleRole>> _lexers;
};
