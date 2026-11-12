// The Files browser the app starts with: open, create, move and rename documents in iCloud
// Drive, On My iPhone or any file provider.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <UIKit/UIKit.h>

@class EditorViewController;

@interface DocumentBrowserViewController : UIDocumentBrowserViewController

@property (nonatomic, readonly) EditorViewController *currentEditor;

- (void) presentDocumentAtURL: (NSURL *) url;

// Opens the document that was open when the app last went away, if any.
- (void) reopenLastDocument;

@end
