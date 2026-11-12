// Application delegate: main menu, global options and themes.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

// Menus that the status bar pops up as copies.
@property (nonatomic, readonly) NSMenu *languageMenu;
@property (nonatomic, readonly) NSMenu *encodingMenu;
@property (nonatomic, readonly) NSMenu *lineEndingMenu;

@end
