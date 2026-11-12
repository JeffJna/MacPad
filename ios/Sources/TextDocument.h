// A text file opened on iOS: UIDocument with the encoding, line endings and language.
// The text is kept with "\n" line breaks; the file's own line ending is restored on saving.
// UIDocument saves automatically, so edits are never lost when the app goes away.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <UIKit/UIKit.h>

#include "TextEncoding.h"

struct Language;

@interface TextDocument : UIDocument

@property (nonatomic, copy) NSString *text;
@property (nonatomic) FileEncoding encoding;
@property (nonatomic) LineEnding lineEnding;
@property (nonatomic) const Language *language;
@property (nonatomic) BOOL languageChosenByUser;

// Called on the main queue when the file was read again because it changed elsewhere (iCloud, Files).
@property (nonatomic, copy) void (^reloadHandler)(void);

// Called on the main queue when saving fails (for example a character the encoding cannot store).
@property (nonatomic, copy) void (^saveErrorHandler)(NSError *error);

// Called on the main queue when the file had been changed on two devices at once: the
// document keeps one version, and every other is saved beside it in the files given.
@property (nonatomic, copy) void (^conflictHandler)(NSArray<NSURL *> *copies);

// The text changed in the editor: remember it and schedule an automatic save.
- (void) textDidChange: (NSString *) text;

// Encoding > Reopen with: reads the file's bytes again with `encoding`. Unsaved edits are lost.
- (void) reinterpretWithEncoding: (FileEncoding) encoding;

@end
