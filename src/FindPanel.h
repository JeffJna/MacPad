// Find / Replace panel: find, replace, count, mark, Find All and Find in Files.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

@class ScintillaView;

@interface FindPanel : NSWindowController

+ (instancetype) shared;

@property (nonatomic, copy) NSString *findString;

// YES while a Find in Files search is running in the background.
@property (nonatomic, readonly) BOOL fileSearchRunning;

- (void) showWithFindString: (NSString *) text focusReplace: (BOOL) focusReplace;

// Search > Find in Files: shows the panel with `directory` as the folder to search.
- (void) showForFindInFilesWithFindString: (NSString *) text directory: (NSURL *) directory;

// Find Next / Find Previous from the menu, using the panel's current options.
- (BOOL) findInEditor: (ScintillaView *) editor backward: (BOOL) backward;

@end
