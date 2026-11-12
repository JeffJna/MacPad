// Themes and the style map.
// This file is part of MacPad (GPL v3 or later).
#import <Foundation/Foundation.h>

#include "Theme.h"

#include <cstdlib>

namespace
{

const char *const kRoleNames[] = {
	"default", "comment", "commentDoc", "commentDocKeyword", "keyword", "keyword2", "type", "function",
	"string", "stringSpecial", "regex", "number", "operator", "preprocessor", "tag", "attribute", "label",
	"variable", "heading", "emphasis", "link", "added", "deleted", "changed", "error",
};
static_assert(sizeof(kRoleNames) / sizeof(kRoleNames[0]) == static_cast<size_t>(StyleRole::Count), "one name per role");

// Where a role the theme does not define takes its style from.
StyleRole FallbackRole(StyleRole role)
{
	switch (role)
	{
		case StyleRole::CommentDoc: return StyleRole::Comment;
		case StyleRole::CommentDocKeyword: return StyleRole::CommentDoc;
		case StyleRole::Keyword2: return StyleRole::Type;
		case StyleRole::Type: return StyleRole::Keyword;
		case StyleRole::Regex: return StyleRole::StringSpecial;
		case StyleRole::StringSpecial: return StyleRole::String;
		case StyleRole::Preprocessor: return StyleRole::Keyword;
		case StyleRole::Tag: return StyleRole::Keyword;
		case StyleRole::Attribute: return StyleRole::Keyword2;
		case StyleRole::Label: return StyleRole::Keyword;
		case StyleRole::Heading: return StyleRole::Keyword;
		case StyleRole::Link: return StyleRole::StringSpecial;
		case StyleRole::Added: return StyleRole::String;
		case StyleRole::Deleted: return StyleRole::Error;
		case StyleRole::Changed: return StyleRole::Number;
		default: return StyleRole::Default;
	}
}

bool ParseColor(id value, unsigned &color)
{
	if (![value isKindOfClass: [NSString class]])
		return false;
	const char *text = [(NSString *)value UTF8String];
	if (!text || *text != '#')
		return false;
	char *end = nullptr;
	const unsigned long rgb = std::strtoul(text + 1, &end, 16);
	if (end == text + 1 || *end != '\0' || end - text != 7)
		return false;
	color = static_cast<unsigned>(rgb);
	return true;
}

NSDictionary *ReadJSONObject(const std::string &path)
{
	NSData *data = [NSData dataWithContentsOfFile: [NSString stringWithUTF8String: path.c_str()]];
	id root = data ? [NSJSONSerialization JSONObjectWithData: data options: 0 error: nil] : nil;
	return [root isKindOfClass: [NSDictionary class]] ? root : nil;
}

} // namespace

StyleRole StyleRoleFromName(const std::string &name)
{
	for (size_t i = 0; i < static_cast<size_t>(StyleRole::Count); ++i)
	{
		if (name == kRoleNames[i])
			return static_cast<StyleRole>(i);
	}
	return StyleRole::Default;
}

std::shared_ptr<Theme> Theme::LoadFromFile(const std::string &path)
{
	NSDictionary *root = ReadJSONObject(path);
	if (!root)
		return nullptr;
	auto theme = std::make_shared<Theme>();
	theme->_path = path;
	if ([root[@"name"] isKindOfClass: [NSString class]])
		theme->_name = [root[@"name"] UTF8String];
	theme->_dark = [root[@"dark"] boolValue];

	NSDictionary *editor = root[@"editor"];
	if ([editor isKindOfClass: [NSDictionary class]])
	{
		for (NSString *key in editor)
		{
			unsigned color = 0;
			if (ParseColor(editor[key], color))
				theme->_colors[key.UTF8String] = color;
		}
	}

	std::map<StyleRole, ThemeStyle> given;
	NSDictionary *styles = root[@"styles"];
	if ([styles isKindOfClass: [NSDictionary class]])
	{
		for (NSString *key in styles)
		{
			NSDictionary *entry = styles[key];
			if (![entry isKindOfClass: [NSDictionary class]])
				continue;
			const StyleRole role = StyleRoleFromName(key.UTF8String);
			if (role == StyleRole::Default && ![key isEqualToString: @"default"])
				continue;
			ThemeStyle style;
			style.color = theme->Foreground();
			ParseColor(entry[@"color"], style.color);
			style.hasBackground = ParseColor(entry[@"background"], style.background);
			style.bold = [entry[@"bold"] boolValue];
			style.italic = [entry[@"italic"] boolValue];
			style.underline = [entry[@"underline"] boolValue];
			given[role] = style;
		}
	}
	theme->Resolve(given);
	return theme;
}

std::shared_ptr<Theme> Theme::Fallback()
{
	auto theme = std::make_shared<Theme>();
	theme->_name = "Fallback";
	theme->Resolve({});
	return theme;
}

void Theme::Resolve(const std::map<StyleRole, ThemeStyle> &given)
{
	ThemeStyle base;
	base.color = Foreground();
	for (size_t i = 0; i < static_cast<size_t>(StyleRole::Count); ++i)
	{
		StyleRole role = static_cast<StyleRole>(i);
		// Follow the fallbacks until a role the theme defines, or the default style.
		for (int steps = 0; steps < 8; ++steps)
		{
			auto found = given.find(role);
			if (found != given.end())
			{
				_styles[i] = found->second;
				break;
			}
			if (role == StyleRole::Default)
			{
				_styles[i] = base;
				break;
			}
			role = FallbackRole(role);
		}
	}
}

unsigned Theme::Color(const char *key, unsigned fallback) const
{
	auto found = _colors.find(key);
	return found == _colors.end() ? fallback : found->second;
}

StyleMap &StyleMap::Shared()
{
	static StyleMap map;
	return map;
}

bool StyleMap::Load(const std::string &path)
{
	NSDictionary *root = ReadJSONObject(path);
	NSDictionary *lexers = root[@"lexers"];
	if (![lexers isKindOfClass: [NSDictionary class]])
		return false;
	_lexers.clear();
	for (NSString *lexer in lexers)
	{
		NSDictionary *styles = lexers[lexer];
		if (![styles isKindOfClass: [NSDictionary class]])
			continue;
		std::vector<StyleRole> roles;
		for (NSString *number in styles)
		{
			const int style = number.intValue;
			if (style < 0 || style > 255 || ![styles[number] isKindOfClass: [NSString class]])
				continue;
			if (roles.size() <= static_cast<size_t>(style))
				roles.resize(static_cast<size_t>(style) + 1, StyleRole::Default);
			roles[static_cast<size_t>(style)] = StyleRoleFromName([styles[number] UTF8String]);
		}
		_lexers[lexer.UTF8String] = std::move(roles);
	}
	return true;
}

const std::vector<StyleRole> *StyleMap::RolesForLexer(const std::string &lexer) const
{
	auto found = _lexers.find(lexer);
	return found == _lexers.end() ? nullptr : &found->second;
}
