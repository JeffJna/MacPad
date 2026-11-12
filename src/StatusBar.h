// Status bar: language | length, lines | Ln, Col, Pos | EOL | encoding | INS/OVR.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, StatusBarSection) {
	StatusBarSectionLanguage,
	StatusBarSectionDocument,
	StatusBarSectionCaret,
	StatusBarSectionLineEnding,
	StatusBarSectionEncoding,
	StatusBarSectionTyping,
	StatusBarSectionCount
};

@class StatusBar;

@protocol StatusBarDelegate
// Menu shown when a section is clicked (language, line ending, encoding), or nil.
- (NSMenu *) statusBar: (StatusBar *) statusBar menuForSection: (StatusBarSection) section;
@end

@interface StatusBar : NSView

@property (nonatomic, weak) id<StatusBarDelegate> delegate;

- (void) setText: (NSString *) text forSection: (StatusBarSection) section;

@end
