// The iOS editor: a text view with syntax highlighting, line numbers, find and replace,
// a row of extra keys above the keyboard and the editing, encoding and tool commands.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <UIKit/UIKit.h>

@class EditorTextView;
@class TextDocument;

@interface EditorViewController : UIViewController <UITextViewDelegate>

- (instancetype) initWithDocument: (TextDocument *) document;

@property (nonatomic, readonly) TextDocument *document;
@property (nonatomic, readonly) EditorTextView *textView;

// Called after the document has been closed (the Files button).
@property (nonatomic, copy) void (^closeHandler)(void);

// Colours the text now instead of after the short pause that follows typing.
- (void) highlightNow;

// Saves now (UIDocument also saves by itself after changes and when the app goes away).
- (void) saveNow;

@end
