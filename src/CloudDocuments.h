// iCloud Drive on the Mac, so that documents reach the iPhone and iPad: new documents are
// kept in iCloud Drive › MacPad, and documents in iCloud Drive are saved a moment after each
// change. "Sync with iCloud Drive" in Settings turns it on and off; it needs iCloud Drive to
// be on in System Settings. Versions saved on two devices at once are kept (see Document).
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

@class Document;

@interface CloudDocuments : NSObject

+ (instancetype) shared;

// iCloud Drive is on in System Settings.
@property (class, nonatomic, readonly) BOOL iCloudDriveAvailable;

// iCloud Drive is on, and so is "Sync with iCloud Drive".
@property (nonatomic, readonly) BOOL active;

// iCloud Drive › MacPad.
@property (nonatomic, readonly) NSURL *folderURL;

// Called once the app has launched.
- (void) start;

// The text of `document` changed: save it in a moment if it belongs in iCloud Drive.
- (void) documentTextDidChange: (Document *) document;

// Before quitting: saves the documents in iCloud Drive now, so that the other devices get the
// last changes. Other documents stay in the session as usual.
- (void) saveDocumentsNow;

// Whether `url` is in iCloud Drive.
+ (BOOL) isInICloud: (NSURL *) url;

// Tests: `folder` stands for iCloud Drive › MacPad and saving is on; nil turns it off again.
- (void) useFolderForTesting: (NSURL *) folder;

@end
