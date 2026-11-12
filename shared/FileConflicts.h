// Versions of a file in iCloud Drive that were saved on two devices at once.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The current version of `url` stays; every version in conflict with it is copied beside it
// as "name (device).ext", so nothing is lost, and then marked as resolved. Where the folder
// cannot be written to (iOS may only grant the file itself), the copy goes to
// `fallbackFolder` instead. Returns the copies. Blocks: call it away from the main thread.
NSArray<NSURL *> *KeepVersionsInConflict(NSURL *url, NSURL *_Nullable fallbackFolder);

// "notes (iPhone).txt" for a version of "notes.txt" saved on "iPhone", or the first name
// after it that `exists` says is free ("notes (iPhone) 2.txt").
NSString *ConflictCopyName(NSString *fileName, NSString *_Nullable device, BOOL (^exists)(NSString *name));

// `fileName` if it is free, otherwise "name 2.ext", "name 3.ext", ...
NSString *UniqueFileName(NSString *fileName, BOOL (^exists)(NSString *name));

NS_ASSUME_NONNULL_END
