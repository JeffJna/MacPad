// Preferences window. Each control carries the name of the AppSettings property it edits
// as its identifier, and reads and writes it through key-value coding.
// This file is part of MacPad (GPL v3 or later).
#import "PreferencesWindow.h"

#import "AppSettings.h"

@implementation PreferencesWindow
{
	NSMutableArray<NSControl *> *_controls;
}

+ (instancetype) shared {
	static PreferencesWindow *window;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		window = [[PreferencesWindow alloc] init];
	});
	return window;
}

- (instancetype) init {
	NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 560, 400)
	                                               styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
	                                                 backing: NSBackingStoreBuffered
	                                                   defer: YES];
	if (@available(macOS 13.0, *))
		window.title = @"Settings";
	else
		window.title = @"Preferences";
	window.releasedWhenClosed = NO;
	window.restorable = NO;
	window.tabbingMode = NSWindowTabbingModeDisallowed;
	self = [super initWithWindow: window];
	if (self) {
		_controls = [NSMutableArray array];
		NSTabView *tabs = [[NSTabView alloc] initWithFrame: NSInsetRect(window.contentView.bounds, 12, 12)];
		tabs.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[self addTab: @"General" rows: [self generalRows] toTabView: tabs];
		[self addTab: @"Editing" rows: [self editingRows] toTabView: tabs];
		[self addTab: @"Appearance" rows: [self appearanceRows] toTabView: tabs];
		[window.contentView addSubview: tabs];
		[window center];
		window.frameAutosaveName = @"Preferences";
		[self refresh];
		[[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(refresh)
		                                             name: AppSettingsDidChangeNotification object: nil];
	}
	return self;
}

// Escape closes the window.
- (void) cancelOperation: (id) sender {
	[self.window performClose: sender];
}

#pragma mark - Controls

- (NSTextField *) label: (NSString *) text {
	NSTextField *label = [NSTextField labelWithString: text];
	label.alignment = NSTextAlignmentRight;
	return label;
}

- (NSTextField *) note: (NSString *) text {
	NSTextField *label = [NSTextField wrappingLabelWithString: text];
	label.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
	label.textColor = [NSColor secondaryLabelColor];
	label.maximumNumberOfLines = 0;
	label.preferredMaxLayoutWidth = 340;
	[label.widthAnchor constraintEqualToConstant: 340].active = YES;
	[label setContentCompressionResistancePriority: NSLayoutPriorityRequired forOrientation: NSLayoutConstraintOrientationVertical];
	return label;
}

- (NSButton *) checkbox: (NSString *) title key: (NSString *) key {
	NSButton *button = [NSButton checkboxWithTitle: title target: self action: @selector(checkboxChanged:)];
	button.identifier = key;
	[_controls addObject: button];
	return button;
}

// A pop-up whose items carry integer tags, for an integer setting.
- (NSPopUpButton *) popupForKey: (NSString *) key titles: (NSArray<NSString *> *) titles tags: (NSArray<NSNumber *> *) tags {
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
	for (NSUInteger i = 0; i < titles.count; ++i) {
		[popup addItemWithTitle: titles[i]];
		popup.lastItem.tag = tags[i].integerValue;
	}
	popup.identifier = key;
	popup.target = self;
	popup.action = @selector(integerPopupChanged:);
	[_controls addObject: popup];
	return popup;
}

// A pop-up whose items carry strings as represented objects, for a string setting.
- (NSPopUpButton *) popupForKey: (NSString *) key titles: (NSArray<NSString *> *) titles values: (NSArray<NSString *> *) values {
	NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame: NSZeroRect pullsDown: NO];
	for (NSUInteger i = 0; i < titles.count; ++i) {
		if (titles[i].length == 0) {
			[popup.menu addItem: [NSMenuItem separatorItem]];
			continue;
		}
		[popup addItemWithTitle: titles[i]];
		popup.lastItem.representedObject = values[i];
	}
	popup.identifier = key;
	popup.target = self;
	popup.action = @selector(stringPopupChanged:);
	[_controls addObject: popup];
	return popup;
}

- (NSArray<NSNumber *> *) numbersFrom: (NSInteger) first to: (NSInteger) last {
	NSMutableArray<NSNumber *> *numbers = [NSMutableArray array];
	for (NSInteger i = first; i <= last; ++i)
		[numbers addObject: @(i)];
	return numbers;
}

- (NSArray<NSString *> *) titlesForNumbers: (NSArray<NSNumber *> *) numbers {
	NSMutableArray<NSString *> *titles = [NSMutableArray array];
	for (NSNumber *number in numbers)
		[titles addObject: number.stringValue];
	return titles;
}

#pragma mark - Tabs

// `rows` holds pairs: a label (or NSNull for none) and the control next to it.
- (void) addTab: (NSString *) title rows: (NSArray<NSArray *> *) rows toTabView: (NSTabView *) tabs {
	NSMutableArray<NSArray<NSView *> *> *views = [NSMutableArray array];
	for (NSArray *row in rows) {
		NSView *label = [row[0] isKindOfClass: [NSView class]] ? row[0] : NSGridCell.emptyContentView;
		[views addObject: @[label, row[1]]];
	}
	NSGridView *grid = [NSGridView gridViewWithViews: views];
	grid.translatesAutoresizingMaskIntoConstraints = NO;
	grid.rowSpacing = 10;
	grid.columnSpacing = 10;
	grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
	[grid columnAtIndex: 0].xPlacement = NSGridCellPlacementTrailing;
	[grid columnAtIndex: 1].xPlacement = NSGridCellPlacementLeading;

	NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier: title];
	item.label = title;
	NSView *container = [[NSView alloc] initWithFrame: NSMakeRect(0, 0, 500, 320)];
	[container addSubview: grid];
	[NSLayoutConstraint activateConstraints: @[
		[grid.topAnchor constraintEqualToAnchor: container.topAnchor constant: 22],
		[grid.centerXAnchor constraintEqualToAnchor: container.centerXAnchor],
		[grid.leadingAnchor constraintGreaterThanOrEqualToAnchor: container.leadingAnchor constant: 16],
	]];
	item.view = container;
	[tabs addTabViewItem: item];
}

- (NSArray<NSArray *> *) generalRows {
	return @[
		@[[self label: @"When quitting:"], [self checkbox: @"Remember open documents and unsaved changes" key: @"rememberSession"]],
		@[[NSNull null], [self note: @"Quitting does not ask to save. Everything, unsaved text included, is back at the next "
		                             @"launch, and unsaved text is backed up a few seconds after each change."]],
		@[[self label: @"When saving:"], [self checkbox: @"Trim trailing whitespace" key: @"trimTrailingOnSave"]],
		@[[self label: @"Selection:"], [self checkbox: @"Highlight other occurrences of the selected word" key: @"smartHighlighting"]],
	];
}

- (NSArray<NSArray *> *) editingRows {
	NSArray<NSNumber *> *widths = [self numbersFrom: 1 to: 8];
	NSArray<NSNumber *> *counts = [self numbersFrom: 1 to: 6];
	return @[
		@[[self label: @"Tab width:"], [self popupForKey: @"tabWidth" titles: [self titlesForNumbers: widths] tags: widths]],
		@[[NSNull null], [self checkbox: @"Insert spaces instead of tabs" key: @"useSpaces"]],
		@[[NSNull null], [self checkbox: @"Keep the indentation of the previous line" key: @"autoIndent"]],
		@[[self label: @"Auto-close:"], [self checkbox: @"Brackets  ( )  [ ]  { }" key: @"autoCloseBrackets"]],
		@[[NSNull null], [self checkbox: @"Quotes  \" \"  ' '  ` `" key: @"autoCloseQuotes"]],
		@[[self label: @"Auto-completion:"], [self checkbox: @"Suggest words while typing" key: @"autoComplete"]],
		@[[self label: @"Suggest from character:"], [self popupForKey: @"autoCompleteMinChars" titles: [self titlesForNumbers: counts] tags: counts]],
		@[[NSNull null], [self note: @"Auto-close and suggestions while typing apply to source code, not to Normal Text. "
		                             @"Control-Space shows suggestions anywhere."]],
	];
}

- (NSArray<NSArray *> *) appearanceRows {
	AppSettings *settings = [AppSettings shared];
	NSMutableArray<NSString *> *themeTitles = [@[@"Automatic (Light / Dark)", @""] mutableCopy];
	NSMutableArray<NSString *> *themeValues = [@[kThemeAutomatic, @""] mutableCopy];
	for (NSString *theme in [settings availableThemes]) {
		[themeTitles addObject: theme];
		[themeValues addObject: theme];
	}

	// Fixed-pitch font families only: column selection and alignment need them.
	NSMutableArray<NSString *> *fontTitles = [@[@"Font of the theme", @""] mutableCopy];
	NSMutableArray<NSString *> *fontValues = [@[@"", @""] mutableCopy];
	NSFontManager *manager = [NSFontManager sharedFontManager];
	for (NSString *family in manager.availableFontFamilies) {
		NSFont *font = [manager fontWithFamily: family traits: 0 weight: 5 size: 12];
		if (font.fixedPitch && ![family hasPrefix: @"."]) {
			[fontTitles addObject: family];
			[fontValues addObject: family];
		}
	}

	NSMutableArray<NSString *> *sizeTitles = [@[@"Size of the theme"] mutableCopy];
	NSMutableArray<NSNumber *> *sizeTags = [@[@0] mutableCopy];
	for (NSNumber *size in @[@9, @10, @11, @12, @13, @14, @15, @16, @18, @20, @22, @24, @28, @32, @36]) {
		[sizeTitles addObject: [NSString stringWithFormat: @"%@ pt", size]];
		[sizeTags addObject: size];
	}

	NSArray<NSNumber *> *edges = @[@0, @72, @79, @80, @88, @100, @120, @132];
	NSMutableArray<NSString *> *edgeTitles = [NSMutableArray array];
	for (NSNumber *edge in edges)
		[edgeTitles addObject: edge.integerValue ? [NSString stringWithFormat: @"Column %@", edge] : @"Off"];

	return @[
		@[[self label: @"Theme:"], [self popupForKey: @"themeName" titles: themeTitles values: themeValues]],
		@[[self label: @"Font:"], [self popupForKey: @"fontName" titles: fontTitles values: fontValues]],
		@[[self label: @"Font size:"], [self popupForKey: @"fontSize" titles: sizeTitles tags: sizeTags]],
		@[[self label: @"Show:"], [self checkbox: @"Line numbers" key: @"showLineNumbers"]],
		@[[NSNull null], [self checkbox: @"Change history in the margin" key: @"showChangeHistory"]],
		@[[NSNull null], [self checkbox: @"Indent guides" key: @"showIndentGuides"]],
		@[[NSNull null], [self checkbox: @"Highlight of the current line" key: @"highlightCurrentLine"]],
		@[[NSNull null], [self checkbox: @"Wrap long lines" key: @"wordWrap"]],
		@[[self label: @"Vertical edge:"], [self popupForKey: @"edgeColumn" titles: edgeTitles tags: edges]],
	];
}

#pragma mark - Values

- (void) refresh {
	AppSettings *settings = [AppSettings shared];
	for (NSControl *control in _controls) {
		id value = [settings valueForKey: control.identifier];
		if ([control isKindOfClass: [NSPopUpButton class]]) {
			NSPopUpButton *popup = (NSPopUpButton *)control;
			NSInteger index = -1;
			if ([value isKindOfClass: [NSString class]])
				index = [popup indexOfItemWithRepresentedObject: value];
			else if ([value isKindOfClass: [NSNumber class]])
				index = [popup indexOfItemWithTag: [value integerValue]];
			if (index < 0 && [value isKindOfClass: [NSNumber class]]) {
				// A value set some other way (the defaults command, an older version): show it as it is.
				[popup addItemWithTitle: [value stringValue]];
				popup.lastItem.tag = [value integerValue];
				index = popup.numberOfItems - 1;
			}
			if (index >= 0)
				[popup selectItemAtIndex: index];
		} else if ([control isKindOfClass: [NSButton class]]) {
			((NSButton *)control).state = [value boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
		}
	}
	for (NSControl *control in _controls) {
		if ([control.identifier isEqualToString: @"autoCompleteMinChars"])
			control.enabled = settings.autoComplete;
	}
}

- (IBAction) checkboxChanged: (NSButton *) sender {
	[[AppSettings shared] setValue: @(sender.state == NSControlStateValueOn) forKey: sender.identifier];
}

- (IBAction) integerPopupChanged: (NSPopUpButton *) sender {
	[[AppSettings shared] setValue: @(sender.selectedTag) forKey: sender.identifier];
}

- (IBAction) stringPopupChanged: (NSPopUpButton *) sender {
	[[AppSettings shared] setValue: sender.selectedItem.representedObject ?: @"" forKey: sender.identifier];
}

@end
