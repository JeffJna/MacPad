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

// iCloud Drive (see CloudDocuments) -----------------------------------------------------

// Saving, asking about a change made elsewhere, or keeping versions in conflict.
@property (nonatomic, readonly) BOOL busyWithFile;

// Saves without asking and without trimming spaces. After an error (shown once), only a save
// by hand tries again.
- (void) saveAutomaticallyToURL: (NSURL *) url operation: (NSSaveOperationType) operation;

// Saves now, synchronously, while the app quits. Returns NO when it did not.
- (BOOL) saveBeforeQuitting;

// A file changed on two devices at once: keeps the other versions beside it and says so.
- (void) keepVersionsInConflict;

// File > Rename… and Move To…, which end in moveFileToURL:. A new extension picks the
// matching language. A file already at `url` is never replaced.
- (IBAction) renameFile: (id) sender;
- (IBAction) moveFile: (id) sender;
- (void) moveFileToURL: (NSURL *) url;

@end
