// Settings of the iOS app.
// This file is part of MacPad (GPL v3 or later).
#import "EditorSettings.h"

#include <algorithm>
#include <map>

#import "Common.h"

#include "Theme.h"

NSNotificationName const EditorSettingsDidChangeNotification = @"EditorSettingsDidChangeNotification";
NSString *const kAutomaticTheme = @"Automatic";

@implementation EditorSettings
{
	std::map<std::string, std::shared_ptr<Theme>> _themes;
}

+ (instancetype) shared {
	static EditorSettings *settings;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		settings = [[EditorSettings alloc] init];
	});
	return settings;
}

- (instancetype) init {
	self = [super init];
	if (self) {
		[[NSUserDefaults standardUserDefaults] registerDefaults: @{
			@"themeName": kAutomaticTheme,
			@"fontSize": @13,
			@"tabWidth": @4,
			@"useSpaces": @YES,
			@"autoIndent": @YES,
			@"autoClose": @YES,
			@"showLineNumbers": @YES,
			@"wrapLines": @YES,
		}];
	}
	return self;
}

- (void) store: (id) value key: (NSString *) key {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	if ([[defaults objectForKey: key] isEqual: value])
		return;
	[defaults setObject: value forKey: key];
	[[NSNotificationCenter defaultCenter] postNotificationName: EditorSettingsDidChangeNotification object: self];
}

- (NSString *) themeName { return [[NSUserDefaults standardUserDefaults] stringForKey: @"themeName"] ?: kAutomaticTheme; }
- (void) setThemeName: (NSString *) name { [self store: name ?: kAutomaticTheme key: @"themeName"]; }
- (CGFloat) fontSize { return std::clamp<CGFloat>([[NSUserDefaults standardUserDefaults] doubleForKey: @"fontSize"], 8, 40); }
- (void) setFontSize: (CGFloat) size { [self store: @(std::clamp<CGFloat>(size, 8, 40)) key: @"fontSize"]; }
- (NSInteger) tabWidth { return std::clamp<NSInteger>([[NSUserDefaults standardUserDefaults] integerForKey: @"tabWidth"], 1, 16); }
- (void) setTabWidth: (NSInteger) width { [self store: @(std::clamp<NSInteger>(width, 1, 16)) key: @"tabWidth"]; }
- (BOOL) useSpaces { return [[NSUserDefaults standardUserDefaults] boolForKey: @"useSpaces"]; }
- (void) setUseSpaces: (BOOL) value { [self store: @(value) key: @"useSpaces"]; }
- (BOOL) autoIndent { return [[NSUserDefaults standardUserDefaults] boolForKey: @"autoIndent"]; }
- (void) setAutoIndent: (BOOL) value { [self store: @(value) key: @"autoIndent"]; }
- (BOOL) autoClose { return [[NSUserDefaults standardUserDefaults] boolForKey: @"autoClose"]; }
- (void) setAutoClose: (BOOL) value { [self store: @(value) key: @"autoClose"]; }
- (BOOL) showLineNumbers { return [[NSUserDefaults standardUserDefaults] boolForKey: @"showLineNumbers"]; }
- (void) setShowLineNumbers: (BOOL) value { [self store: @(value) key: @"showLineNumbers"]; }
- (BOOL) wrapLines { return [[NSUserDefaults standardUserDefaults] boolForKey: @"wrapLines"]; }
- (void) setWrapLines: (BOOL) value { [self store: @(value) key: @"wrapLines"]; }

- (NSString *) themesDirectory {
	return [[NSBundle mainBundle].resourcePath stringByAppendingPathComponent: @"themes"];
}

- (NSArray<NSString *> *) availableThemes {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath: [self themesDirectory] error: nil]) {
		if ([file.pathExtension isEqualToString: @"json"])
			[names addObject: file.stringByDeletingPathExtension];
	}
	[names sortUsingSelector: @selector(localizedCaseInsensitiveCompare:)];
	return names;
}

- (std::shared_ptr<Theme>) loadTheme: (NSString *) name {
	const std::string key = ToStdString(name);
	auto found = _themes.find(key);
	if (found != _themes.end())
		return found->second;
	NSString *path = [[self themesDirectory] stringByAppendingPathComponent: [name stringByAppendingPathExtension: @"json"]];
	std::shared_ptr<Theme> theme = Theme::LoadFromFile(ToStdString(path));
	if (theme)
		_themes[key] = theme;
	return theme;
}

- (std::shared_ptr<Theme>) themeForDarkAppearance: (BOOL) dark {
	std::shared_ptr<Theme> theme;
	if (![self.themeName isEqualToString: kAutomaticTheme])
		theme = [self loadTheme: self.themeName];
	if (!theme)
		theme = [self loadTheme: dark ? @"Dark" : @"Light"];
	return theme ?: Theme::Fallback();
}

@end
