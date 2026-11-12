// Session snapshot: the open documents, and the text of the unsaved ones, are written to
// ~/Library/Application Support/<bundle id>/ and brought back at the next launch. Quitting
// does not ask to save: unsaved text simply reappears.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

@class Document;

@interface SessionManager : NSObject

+ (instancetype) shared;

// YES while the app quits with every unsaved document safely in the session.
@property (nonatomic) BOOL terminating;
@property (nonatomic, readonly) BOOL restoring;

// Reopens the documents of the last session. Returns how many were opened.
- (NSUInteger) restoreSession;

// Writes the session, unsaved text included. Returns YES when quitting may skip the
// "save changes?" review because nothing can be lost.
- (BOOL) prepareForTermination;

// Writes the session now. Returns NO if the text of an unsaved document could not be stored.
- (BOOL) saveNow;

// The text changed: back it up soon. A crash then loses a few seconds of typing at most.
- (void) documentTextDidChange: (Document *) document;
// A document was opened, saved, renamed, or tabs were rearranged.
- (void) documentStateDidChange;
- (void) documentDidClose: (Document *) document;

@end
