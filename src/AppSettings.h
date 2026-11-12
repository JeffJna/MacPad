// Application-wide preferences (stored in NSUserDefaults) and the active theme.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

#include <memory>

#include "EditorStyler.h"

class Theme;

extern NSNotificationName const AppSettingsDidChangeNotification; // view or editing options changed
extern NSNotificationName const AppThemeDidChangeNotification;    // colours or fonts changed

extern NSString *const kThemeAutomatic; // follow the macOS light/dark appearance
extern NSString *const kThemeDefault;   // the light theme, used when no theme is chosen

// Every property is stored under a default of the same name, so the Preferences window
// can read and write them through key-value coding.
@interface AppSettings : NSObject

+ (instancetype) shared;

// View
@property (nonatomic) BOOL wordWrap;
@property (nonatomic) BOOL showWhitespace;
@property (nonatomic) BOOL showEndOfLine;
@property (nonatomic) BOOL showIndentGuides;
@property (nonatomic) BOOL showLineNumbers;
@property (nonatomic) BOOL showChangeHistory;
@property (nonatomic) BOOL highlightCurrentLine;
@property (nonatomic) NSInteger edgeColumn; // vertical edge line; 0 turns it off
@property (nonatomic) NSInteger zoom;       // Scintilla zoom level, shared by every editor
@property (nonatomic) BOOL smartHighlighting;

// Editing
@property (nonatomic) BOOL useSpaces;
@property (nonatomic) NSInteger tabWidth;
@property (nonatomic) BOOL autoIndent;
@property (nonatomic) BOOL autoCloseBrackets;
@property (nonatomic) BOOL autoCloseQuotes;
@property (nonatomic) BOOL autoComplete;
@property (nonatomic) NSInteger autoCompleteMinChars;
@property (nonatomic) BOOL trimTrailingOnSave;

// General
@property (nonatomic) BOOL rememberSession; // reopen documents, unsaved text included, at the next launch
@property (nonatomic) BOOL syncWithICloud;  // new documents in iCloud Drive, saved by themselves (CloudDocuments)

// Appearance
@property (nonatomic, copy) NSString *themeName;
@property (nonatomic, copy) NSString *fontName; // empty: the font of the theme
@property (nonatomic) NSInteger fontSize;       // in points; 0: the size of the theme

- (EditorViewSettings) viewSettings;
- (EditorFont) editorFont;

// Theme files bundled with the app, without the ".xml" extension.
- (NSArray<NSString *> *) availableThemes;

- (std::shared_ptr<Theme>) currentTheme;

// Called when the system appearance changes; reloads the theme if it follows the appearance.
- (void) appearanceDidChange;

@end
