// The text view of the iOS editor, with a line number gutter.
// This file is part of MacPad (GPL v3 or later).
#import "EditorTextView.h"

#include <algorithm>
#include <cmath>
#include <vector>

// Draws the line numbers of the visible lines. It stays in the visible part of the text view
// (moving with the scroll offset), so it never needs a backing store as tall as the document.
@interface LineNumberGutter : UIView
@property (nonatomic, weak) EditorTextView *textView;
@end

@implementation EditorTextView
{
	LineNumberGutter *_gutter;
	std::vector<NSUInteger> _lineStarts;
	CGFloat _gutterWidth;
}

+ (instancetype) editorTextView {
	// TextKit 1: the gutter needs the layout manager's line fragments.
	EditorTextView *view = [self textViewUsingTextLayoutManager: NO];
	[view setUpGutter];
	return view;
}

- (void) setUpGutter {
	_gutter = [[LineNumberGutter alloc] initWithFrame: CGRectZero];
	_gutter.textView = self;
	_gutter.opaque = NO;
	_gutter.userInteractionEnabled = NO;
	_gutter.contentMode = UIViewContentModeRedraw;
	[self addSubview: _gutter];
	_showsLineNumbers = YES;
	_lineStarts.push_back(0);
	self.gutterColor = [UIColor secondarySystemBackgroundColor];
	self.lineNumberColor = [UIColor tertiaryLabelColor];
	self.currentLineNumberColor = [UIColor labelColor];
}

- (void) setShowsLineNumbers: (BOOL) shows {
	_showsLineNumbers = shows;
	_gutter.hidden = !shows;
	[self updateGutterWidth];
}

- (void) setFont: (UIFont *) font {
	[super setFont: font];
	[self updateGutterWidth];
}

- (void) textDidChange {
	NSString *text = self.textStorage.string;
	_lineStarts.clear();
	_lineStarts.push_back(0);
	const NSUInteger length = text.length;
	// Scan in chunks: characterAtIndex: one by one is slow for long texts.
	unichar buffer[4096];
	for (NSUInteger chunk = 0; chunk < length; chunk += 4096) {
		const NSUInteger count = std::min<NSUInteger>(4096, length - chunk);
		[text getCharacters: buffer range: NSMakeRange(chunk, count)];
		for (NSUInteger i = 0; i < count; ++i) {
			if (buffer[i] == '\n')
				_lineStarts.push_back(chunk + i + 1);
		}
	}
	[self updateGutterWidth];
	[_gutter setNeedsDisplay];
}

- (NSUInteger) lineCount {
	return _lineStarts.size();
}

- (NSUInteger) lineForLocation: (NSUInteger) location {
	const auto found = std::upper_bound(_lineStarts.begin(), _lineStarts.end(), location);
	return static_cast<NSUInteger>(found - _lineStarts.begin()) - 1;
}

- (NSUInteger) locationOfLine: (NSUInteger) line {
	return line < _lineStarts.size() ? _lineStarts[line] : self.textStorage.length;
}

- (void) updateGutterWidth {
	CGFloat width = 0;
	if (_showsLineNumbers) {
		const int digits = std::max(2, static_cast<int>(std::floor(std::log10(std::max<double>(1, _lineStarts.size())))) + 1);
		UIFont *font = [UIFont monospacedDigitSystemFontOfSize: self.font.pointSize * 0.85 weight: UIFontWeightRegular];
		width = std::ceil([@"8" sizeWithAttributes: @{NSFontAttributeName: font}].width * digits) + 14;
	}
	if (std::fabs(width - _gutterWidth) < 0.5)
		return;
	_gutterWidth = width;
	UIEdgeInsets insets = self.textContainerInset;
	insets.left = width + 6;
	self.textContainerInset = insets;
	[self setNeedsLayout];
}

- (void) layoutSubviews {
	[super layoutSubviews];
	_gutter.frame = CGRectMake(self.contentOffset.x, self.contentOffset.y, _gutterWidth, self.bounds.size.height);
	[_gutter setNeedsDisplay];
	[self sendSubviewToBack: _gutter];
}

- (CGFloat) gutterWidth {
	return _gutterWidth;
}

@end

@implementation LineNumberGutter

- (void) drawRect: (CGRect) rect {
	EditorTextView *textView = self.textView;
	if (!textView)
		return;
	[textView.gutterColor setFill];
	UIRectFill(self.bounds);

	NSLayoutManager *layout = textView.layoutManager;
	NSTextContainer *container = textView.textContainer;
	const UIEdgeInsets insets = textView.textContainerInset;
	const CGPoint offset = textView.contentOffset;
	// The visible part of the text, in text container coordinates.
	const CGRect visible = CGRectMake(0, offset.y - insets.top, container.size.width, self.bounds.size.height);
	const NSRange glyphs = [layout glyphRangeForBoundingRect: visible inTextContainer: container];

	UIFont *font = [UIFont monospacedDigitSystemFontOfSize: textView.font.pointSize * 0.85 weight: UIFontWeightRegular];
	NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.alignment = NSTextAlignmentRight;
	NSDictionary *normal = @{NSFontAttributeName: font, NSForegroundColorAttributeName: textView.lineNumberColor,
	                         NSParagraphStyleAttributeName: paragraph};
	NSDictionary *current = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize: font.pointSize weight: UIFontWeightSemibold],
	                          NSForegroundColorAttributeName: textView.currentLineNumberColor, NSParagraphStyleAttributeName: paragraph};
	NSString *text = textView.textStorage.string;
	const NSUInteger caretLine = [textView lineForLocation: textView.selectedRange.location];
	const CGFloat width = self.bounds.size.width - 6;

	auto drawNumber = [&](NSUInteger line, CGRect fragment) {
		const CGFloat y = fragment.origin.y + insets.top - offset.y;
		const CGFloat baselineShift = (fragment.size.height - font.lineHeight) / 2;
		NSString *label = [NSString stringWithFormat: @"%lu", (unsigned long)(line + 1)];
		[label drawInRect: CGRectMake(0, y + baselineShift, width, font.lineHeight) withAttributes: line == caretLine ? current : normal];
	};

	[layout enumerateLineFragmentsForGlyphRange: glyphs usingBlock: ^(CGRect fragment, CGRect usedRect, NSTextContainer *textContainer,
	                                                                  NSRange glyphRange, BOOL *stop) {
		const NSUInteger character = [layout characterIndexForGlyphAtIndex: glyphRange.location];
		// Only the first fragment of a line gets a number; wrapped continuations do not.
		if (character == 0 || (character <= text.length && [text characterAtIndex: character - 1] == '\n'))
			drawNumber([textView lineForLocation: character], fragment);
	}];
	// The empty line after a final line break.
	const CGRect extra = layout.extraLineFragmentRect;
	if (!CGRectIsEmpty(extra) || (text.length == 0))
		drawNumber(textView.lineCount - 1, CGRectIsEmpty(extra) ? CGRectMake(0, 0, 0, font.lineHeight) : extra);
}

@end
