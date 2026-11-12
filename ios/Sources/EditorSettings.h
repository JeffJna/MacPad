// Settings of the iOS app (stored in NSUserDefaults) and the active theme.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <UIKit/UIKit.h>

#include <memory>

class Theme;

extern NSNotificationName const EditorSettingsDidChangeNotification;
extern NSString *const kAutomaticTheme; // Light or Dark, following the system appearance

@interface EditorSettings : NSObject

+ (instancetype) shared;

@property (nonatomic, copy) NSString *themeName;
@property (nonatomic) CGFloat fontSize;
@property (nonatomic) NSInteger tabWidth;
@property (nonatomic) BOOL useSpaces;
@property (nonatomic) BOOL autoIndent;
@property (nonatomic) BOOL autoClose;
@property (nonatomic) BOOL showLineNumbers;
@property (nonatomic) BOOL wrapLines;

// Theme names, from the theme files bundled with the app.
- (NSArray<NSString *> *) availableThemes;

// The theme to use with the given appearance (Automatic picks Light or Dark).
- (std::shared_ptr<Theme>) themeForDarkAppearance: (BOOL) dark;

@end
