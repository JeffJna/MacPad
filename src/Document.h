// A text file: encoding, line endings and language, loaded and saved through NSDocument.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

#include <string>

#include "TextEncoding.h"

struct Language;
@class EditorWindowController;

@interface Document : NSDocument

@property (nonatomic) FileEncoding encoding;
@property (nonatomic) LineEnding lineEnding;
@property (nonatomic) const Language *language;
@property (nonatomic) BOOL languageChosenByUser;

@property (nonatomic, readonly) EditorWindowController *editorController;

// "new 1", "new 2", ... for documents that have never been saved.
@property (nonatomic) NSInteger untitledNumber;

// Files above 64 MB open as plain text, without the features that scan the whole document.
@property (nonatomic, readonly) BOOL largeFile;

// Unsaved changes as NSDocument sees them. `isDocumentEdited` itself answers NO while the app
// quits with a saved session, so that quitting does not ask about text the session keeps.
@property (nonatomic, readonly) BOOL hasUnsavedChanges;

// Session support (see SessionManager).
@property (nonatomic, copy) NSString *sessionID;      // names the backup file of this document
@property (nonatomic) NSUInteger changeSerial;        // bumped on every text change
@property (nonatomic) NSUInteger backupSerial;        // changeSerial at the time of the last backup
// The text came from a session backup, so it differs from the file even at Scintilla's save point.
@property (nonatomic) BOOL hasRestoredUnsavedText;

// Text read from disk before the editor window existed; handed over once.
- (std::string) takeLoadedText;

// Encoding > Reopen with Encoding: reads the file again, interpreting it with `encoding`.
- (void) reopenWithEncoding: (FileEncoding) encoding;

// Reloads the file (or asks, when there are unsaved edits) if another program changed it.
- (void) checkForExternalChange;

@end
