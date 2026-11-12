// Status bar: language | length, lines | Ln, Col, Pos | EOL | encoding | INS/OVR.
// This file is part of MacPad (GPL v3 or later).
#import "StatusBar.h"

static const CGFloat kSectionWidths[StatusBarSectionCount] = {
	0,   // language: takes the remaining space
	210, // length / lines
	250, // Ln / Col / Pos
	120, // line ending
	115, // encoding
	40,  // INS / OVR
};

@implementation StatusBar
{
	NSTextField *_labels[StatusBarSectionCount];
}

- (instancetype) initWithFrame: (NSRect) frame {
	self = [super initWithFrame: frame];
	if (self) {
		for (NSInteger i = 0; i < StatusBarSectionCount; ++i) {
			NSTextField *label = [NSTextField labelWithString: @""];
			label.font = [NSFont systemFontOfSize: 11];
			label.textColor = [NSColor secondaryLabelColor];
			label.lineBreakMode = NSLineBreakByTruncatingTail;
			label.cell.usesSingleLineMode = YES;
			[self addSubview: label];
			_labels[i] = label;
		}
		[self layoutSections];
	}
	return self;
}

- (BOOL) isFlipped {
	return NO;
}

- (void) resizeSubviewsWithOldSize: (NSSize) oldSize {
	[self layoutSections];
}

- (NSRect) frameForSection: (NSInteger) section {
	const NSRect bounds = self.bounds;
	CGFloat right = NSMaxX(bounds);
	for (NSInteger i = StatusBarSectionCount - 1; i > section; --i)
		right -= kSectionWidths[i];
	const CGFloat width = section == StatusBarSectionLanguage ? right : kSectionWidths[section];
	return NSMakeRect(right - width, 0, width, NSHeight(bounds));
}

- (void) layoutSections {
	for (NSInteger i = 0; i < StatusBarSectionCount; ++i) {
		const NSRect section = [self frameForSection: i];
		const CGFloat height = 16;
		_labels[i].frame = NSMakeRect(NSMinX(section) + 8, floor((NSHeight(section) - height) / 2),
		                              MAX(0, NSWidth(section) - 12), height);
	}
}

- (void) drawRect: (NSRect) dirtyRect {
	[[NSColor windowBackgroundColor] setFill];
	NSRectFill(dirtyRect);
	[[NSColor separatorColor] setFill];
	NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1));
	for (NSInteger i = 1; i < StatusBarSectionCount; ++i) {
		const NSRect section = [self frameForSection: i];
		NSRectFill(NSMakeRect(NSMinX(section), 4, 1, NSHeight(section) - 8));
	}
}

- (void) setText: (NSString *) text forSection: (StatusBarSection) section {
	if (section < 0 || section >= StatusBarSectionCount)
		return;
	if (![_labels[section].stringValue isEqualToString: text])
		_labels[section].stringValue = text ?: @"";
}

- (void) mouseDown: (NSEvent *) event {
	const NSPoint point = [self convertPoint: event.locationInWindow fromView: nil];
	for (NSInteger i = 0; i < StatusBarSectionCount; ++i) {
		if (NSPointInRect(point, [self frameForSection: i])) {
			NSMenu *menu = [self.delegate statusBar: self menuForSection: (StatusBarSection)i];
			if (menu) {
				const NSRect section = [self frameForSection: i];
				[menu popUpMenuPositioningItem: nil atLocation: NSMakePoint(NSMinX(section), NSMaxY(section)) inView: self];
			}
			return;
		}
	}
}

@end
