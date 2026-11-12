// Application-wide preferences (stored in NSUserDefaults) and the active theme.
// This file is part of MacPad (GPL v3 or later).
#import "AppSettings.h"

#include <algorithm>

#include "SciUtil.h"
#include "Theme.h"

NSNotificationName const AppSettingsDidChangeNotification = @"AppSettingsDidChangeNotification";
NSNotificationName const AppThemeDidChangeNotification = @"AppThemeDidChangeNotification";

NSString *const kThemeAutomatic = @"Automatic";
NSString *const kThemeDefault = @"Light";

static NSString *const kDarkTheme = @"Dark";

// Defines the accessors of a BOOL / NSInteger property stored under a default of the same name.
#define BOOL_SETTING(name, Name) \
	- (BOOL) name { return [[NSUserDefaults standardUserDefaults] boolForKey: @#name]; } \
	- (void) set##Name: (BOOL) value { [self storeObject: @(value) forKey: @#name]; }

#define INTEGER_SETTING(name, Name, low, high) \
	- (NSInteger) name { return std::clamp<NSInteger>([[NSUserDefaults standardUserDefaults] integerForKey: @#name], low, high); } \
	- (void) set##Name: (NSInteger) value { [self storeObject: @(std::clamp<NSInteger>(value, low, high)) forKey: @#name]; }

@implementation AppSettings
{
	std::shared_ptr<Theme> _theme;
	NSString *_loadedThemePath;
}

+ (instancetype) shared {
	static AppSettings *settings;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		settings = [[AppSettings alloc] init];
	});
	return settings;
}

- (instancetype) init {
	self = [super init];
	if (self) {
		[[NSUserDefaults standardUserDefaults] registerDefaults: @{
			@"wordWrap": @NO,
			@"showWhitespace": @NO,
			@"showEndOfLine": @NO,
			@"showIndentGuides": @YES,
			@"showLineNumbers": @YES,
			@"showChangeHistory": @YES,
			@"highlightCurrentLine": @YES,
			@"edgeColumn": @0,
			@"zoom": @0,
			@"smartHighlighting": @YES,
			@"useSpaces": @NO,
			@"tabWidth": @4,
			@"autoIndent": @YES,
			@"autoCloseBrackets": @YES,
			@"autoCloseQuotes": @YES,
			@"autoComplete": @YES,
			@"autoCompleteMinChars": @3,
			@"trimTrailingOnSave": @NO,
			@"rememberSession": @YES,
			@"syncWithICloud": @YES,
			@"themeName": kThemeAutomatic,
			@"fontName": @"",
			@"fontSize": @0,
		}];
	}
	return self;
}

#pragma mark - Stored options

- (void) storeObject: (id) value forKey: (NSString *) key {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([[defaults objectForKey: key] isEqual: value])
		return;
	[defaults setObject: value forKey: key];
	[[NSNotificationCenter defaultCenter] postNotificationName: AppSettingsDidChangeNotification object: self];
}

BOOL_SETTING(wordWrap, WordWrap)
BOOL_SETTING(showWhitespace, ShowWhitespace)
BOOL_SETTING(showEndOfLine, ShowEndOfLine)
BOOL_SETTING(showIndentGuides, ShowIndentGuides)
BOOL_SETTING(showLineNumbers, ShowLineNumbers)
BOOL_SETTING(showChangeHistory, ShowChangeHistory)
BOOL_SETTING(highlightCurrentLine, HighlightCurrentLine)
BOOL_SETTING(smartHighlighting, SmartHighlighting)
BOOL_SETTING(useSpaces, UseSpaces)
BOOL_SETTING(autoIndent, AutoIndent)
BOOL_SETTING(autoCloseBrackets, AutoCloseBrackets)
BOOL_SETTING(autoCloseQuotes, AutoCloseQuotes)
BOOL_SETTING(autoComplete, AutoComplete)
BOOL_SETTING(trimTrailingOnSave, TrimTrailingOnSave)
BOOL_SETTING(rememberSession, RememberSession)
BOOL_SETTING(syncWithICloud, SyncWithICloud)

INTEGER_SETTING(edgeColumn, EdgeColumn, 0, 1000)
INTEGER_SETTING(zoom, Zoom, -10, 60)
INTEGER_SETTING(tabWidth, TabWidth, 1, 32)
INTEGER_SETTING(autoCompleteMinChars, AutoCompleteMinChars, 1, 9)

- (EditorViewSettings) viewSettings {
	EditorViewSettings settings;
	settings.wordWrap = self.wordWrap;
	settings.showWhitespace = self.showWhitespace;
	settings.showEndOfLine = self.showEndOfLine;
	settings.showIndentGuides = self.showIndentGuides;
	settings.showLineNumbers = self.showLineNumbers;
	settings.showChangeHistory = self.showChangeHistory;
	settings.highlightCurrentLine = self.highlightCurrentLine;
	settings.edgeColumn = static_cast<int>(self.edgeColumn);
	settings.zoom = static_cast<int>(self.zoom);
	settings.tabWidth = static_cast<int>(self.tabWidth);
	settings.useSpaces = self.useSpaces;
	return settings;
}

#pragma mark - Font

- (NSString *) fontName {
	return [[NSUserDefaults standardUserDefaults] stringForKey: @"fontName"] ?: @"";
}

- (void) setFontName: (NSString *) name {
	if ([self.fontName isEqualToString: name ?: @""])
		return;
	[[NSUserDefaults standardUserDefaults] setObject: name ?: @"" forKey: @"fontName"];
	[self fontDidChange];
}

- (NSInteger) fontSize {
	const NSInteger size = [[NSUserDefaults standardUserDefaults] integerForKey: @"fontSize"];
	return size <= 0 ? 0 : std::clamp<NSInteger>(size, 6, 96);
}

- (void) setFontSize: (NSInteger) size {
	if (self.fontSize == size)
		return;
	[[NSUserDefaults standardUserDefaults] setInteger: size forKey: @"fontSize"];
	[self fontDidChange];
}

// Fonts are part of the styles, so editors re-apply their language just as for a new theme.
- (void) fontDidChange {
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center postNotificationName: AppThemeDidChangeNotification object: self];
	[center postNotificationName: AppSettingsDidChangeNotification object: self];
}

- (EditorFont) editorFont {
	EditorFont font;
	// The name is a font family ("Menlo"); it is ignored when the font is not installed.
	NSString *name = self.fontName;
	if (name.length && ([NSFont fontWithName: name size: 12] ||
	                    [[NSFontManager sharedFontManager] fontWithFamily: name traits: 0 weight: 5 size: 12]))
		font.name = ToStdString(name);
	font.size = static_cast<int>(self.fontSize);
	return font;
}

#pragma mark - Themes

- (NSString *) themeName {
	return [[NSUserDefaults standardUserDefaults] stringForKey: @"themeName"] ?: kThemeAutomatic;
}

- (void) setThemeName: (NSString *) name {
	[[NSUserDefaults standardUserDefaults] setObject: name ?: kThemeAutomatic forKey: @"themeName"];
	[self reloadTheme];
	[[NSNotificationCenter defaultCenter] postNotificationName: AppSettingsDidChangeNotification object: self];
}

- (NSString *) themesDirectory {
	return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent: @"themes"];
}

- (NSArray<NSString *> *) availableThemes {
	NSArray<NSString *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: [self themesDirectory] error: nil];
	NSMutableArray<NSString *> *themes = [NSMutableArray array];
	for (NSString *file in files) {
		if ([file.pathExtension.lowercaseString isEqualToString: @"json"])
			[themes addObject: file.stringByDeletingPathExtension];
	}
	[themes sortUsingSelector: @selector(localizedCaseInsensitiveCompare:)];
	return themes;
}

- (BOOL) systemIsDark {
	NSAppearanceName match = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames: @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
	return [match isEqualToString: NSAppearanceNameDarkAqua];
}

// Theme files are named after the theme: "Light.json", "High Contrast Dark.json".
- (NSString *) pathForThemeName: (NSString *) name {
	NSString *path = nil;
	if (![name isEqualToString: kThemeAutomatic])
		path = [[self themesDirectory] stringByAppendingPathComponent: [name stringByAppendingPathExtension: @"json"]];
	if (!path || ![[NSFileManager defaultManager] fileExistsAtPath: path]) {
		// Automatic, or a theme that no longer exists: follow the system appearance.
		NSString *automatic = [self systemIsDark] ? kDarkTheme : kThemeDefault;
		path = [[self themesDirectory] stringByAppendingPathComponent: [automatic stringByAppendingPathExtension: @"json"]];
	}
	return path;
}

- (void) reloadTheme {
	NSString *path = [self pathForThemeName: self.themeName];
	if (_theme && [path isEqualToString: _loadedThemePath])
		return;
	std::shared_ptr<Theme> theme = Theme::LoadFromFile(ToStdString(path));
	if (!theme)
		theme = Theme::Fallback();
	_theme = theme;
	_loadedThemePath = path;
	[[NSNotificationCenter defaultCenter] postNotificationName: AppThemeDidChangeNotification object: self];
}

- (std::shared_ptr<Theme>) currentTheme {
	if (!_theme)
		[self reloadTheme];
	return _theme;
}

- (void) appearanceDidChange {
	if ([self.themeName isEqualToString: kThemeAutomatic])
		[self reloadTheme];
}

@end
