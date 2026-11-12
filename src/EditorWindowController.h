// One editor window (or window tab): a Scintilla view plus the status bar.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>

#import "SciUtil.h"

@interface EditorWindowController : NSWindowController <ScintillaNotificationProtocol, NSWindowDelegate>

@property (nonatomic, readonly) ScintillaView *editor;

// Replaces the whole text (file load or reload), clearing undo history and the dirty flag.
- (void) loadText: (const std::string &) text keepPosition: (BOOL) keepPosition;
- (std::string) documentText;
- (void) markSavePoint;
- (void) documentDidSave;

// Re-applies lexer and colours after a language or theme change.
- (void) applyLanguage;
- (void) refreshStatus;

// Word under the caret or the single-line selection, used to seed the Find panel.
- (NSString *) textForFind;

// Selects a range of the document and scrolls it into view (search results, Go to Line).
- (void) selectRangeFrom: (sptr_t) start to: (sptr_t) end;

// "Trim trailing whitespace on save".
- (void) trimTrailingWhitespaceInDocument;

// The document as a paginating text view for File > Print.
- (NSView *) printableViewForPrintInfo: (NSPrintInfo *) printInfo;

@end
