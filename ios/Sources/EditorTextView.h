// The text view of the iOS editor: a TextKit 1 UITextView with a line number gutter.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <UIKit/UIKit.h>

@interface EditorTextView : UITextView

+ (instancetype) editorTextView;

@property (nonatomic) BOOL showsLineNumbers;
@property (nonatomic, strong) UIColor *gutterColor;
@property (nonatomic, strong) UIColor *lineNumberColor;
@property (nonatomic, strong) UIColor *currentLineNumberColor;

// Call after every change of the text: line starts are cached for the gutter.
- (void) textDidChange;

// 0-based line of a UTF-16 offset, and the offset where a line starts.
- (NSUInteger) lineForLocation: (NSUInteger) location;
- (NSUInteger) locationOfLine: (NSUInteger) line;
- (NSUInteger) lineCount;

@end
