// Search results window.
// This file is part of MacPad (GPL v3 or later).
#import "SearchResultsPanel.h"

#import "Document.h"
#import "EditorWindowController.h"
#import "SciUtil.h"

typedef NS_ENUM(NSInteger, SearchNodeKind) {
	SearchNodeSearch,
	SearchNodeFile,
	SearchNodeHit,
};

@interface SearchNode : NSObject
@property (nonatomic) SearchNodeKind kind;
@property (nonatomic, copy) NSAttributedString *title;
@property (nonatomic) NSMutableArray<SearchNode *> *children;
@property (nonatomic, weak) SearchNode *parent;
// Search
@property (nonatomic, copy) NSString *pattern;
@property (nonatomic, copy) NSString *scope;
@property (nonatomic) NSInteger hitCount;
@property (nonatomic) BOOL finished;
@property (nonatomic, copy) NSString *note;
// File
@property (nonatomic) NSURL *url;
@property (nonatomic, weak) Document *document;
@property (nonatomic, copy) NSString *name;
// Hit
@property (nonatomic) long line;
@property (nonatomic) long start;
@property (nonatomic) long end;
@end

@implementation SearchNode
- (instancetype) init {
	self = [super init];
	if (self)
		_children = [NSMutableArray array];
	return self;
}
@end

// Return opens the selected result, as a double click does.
@interface SearchResultsOutlineView : NSOutlineView
@end

@implementation SearchResultsOutlineView
- (void) keyDown: (NSEvent *) event {
	NSString *characters = event.charactersIgnoringModifiers;
	if (characters.length == 1 && ([characters characterAtIndex: 0] == NSCarriageReturnCharacter ||
	                               [characters characterAtIndex: 0] == NSEnterCharacter)) {
		[NSApp sendAction: self.doubleAction to: self.target from: self];
		return;
	}
	[super keyDown: event];
}
@end

@interface SearchResultsPanel () <NSOutlineViewDataSource, NSOutlineViewDelegate>
@end

@implementation SearchResultsPanel
{
	NSOutlineView *_outline;
	NSTextField *_summary;
	NSMutableArray<SearchNode *> *_searches;
	NSMutableArray<SearchNode *> *_nodesToExpand;
	BOOL _reloadPending;
}

+ (instancetype) shared {
	static SearchResultsPanel *panel;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		panel = [[SearchResultsPanel alloc] init];
	});
	return panel;
}

- (instancetype) init {
	NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 760, 320)
	                                               styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                                          NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
	                                                 backing: NSBackingStoreBuffered
	                                                   defer: YES];
	window.title = @"Search Results";
	window.releasedWhenClosed = NO;
	window.restorable = NO;
	window.tabbingMode = NSWindowTabbingModeDisallowed;
	window.minSize = NSMakeSize(360, 160);
	self = [super initWithWindow: window];
	if (self) {
		_searches = [NSMutableArray array];
		_nodesToExpand = [NSMutableArray array];
		[self buildContentInView: window.contentView];
		if (![window setFrameUsingName: @"SearchResults"]) {
			// Along the bottom of the main screen, below the editor windows.
			const NSRect screen = NSScreen.mainScreen.visibleFrame;
			[window setFrame: NSMakeRect(NSMinX(screen) + 40, NSMinY(screen) + 40, MIN(900, NSWidth(screen) - 80), 300) display: NO];
		}
		window.frameAutosaveName = @"SearchResults";
	}
	return self;
}

- (void) buildContentInView: (NSView *) content {
	const NSRect bounds = content.bounds;
	const CGFloat barHeight = 30;

	NSButton *clear = [NSButton buttonWithTitle: @"Clear" target: self action: @selector(clearResults:)];
	clear.controlSize = NSControlSizeSmall;
	clear.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
	[clear sizeToFit];
	clear.frame = NSMakeRect(NSWidth(bounds) - NSWidth(clear.frame) - 10, 4, NSWidth(clear.frame), 22);
	clear.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
	[content addSubview: clear];

	_summary = [NSTextField labelWithString: @"No searches yet. Use Search > Find in Files or the Find All buttons."];
	_summary.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
	_summary.textColor = [NSColor secondaryLabelColor];
	_summary.lineBreakMode = NSLineBreakByTruncatingTail;
	_summary.frame = NSMakeRect(10, 7, NSMinX(clear.frame) - 20, 16);
	_summary.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	[content addSubview: _summary];

	NSScrollView *scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(0, barHeight, NSWidth(bounds), NSHeight(bounds) - barHeight)];
	scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	scroll.hasVerticalScroller = YES;
	scroll.hasHorizontalScroller = YES;
	scroll.borderType = NSNoBorder;

	_outline = [[SearchResultsOutlineView alloc] initWithFrame: scroll.bounds];
	NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier: @"result"];
	column.width = 4000; // long lines scroll horizontally instead of being cut
	column.minWidth = 200;
	[_outline addTableColumn: column];
	_outline.outlineTableColumn = column;
	_outline.headerView = nil;
	_outline.rowHeight = 18;
	_outline.indentationPerLevel = 14;
	_outline.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
	_outline.dataSource = self;
	_outline.delegate = self;
	_outline.target = self;
	_outline.doubleAction = @selector(openSelectedResult:);
	_outline.style = NSTableViewStyleFullWidth;
	scroll.documentView = _outline;
	[content addSubview: scroll];
}

#pragma mark - Titles

- (NSAttributedString *) titleForSearch: (SearchNode *) node {
	NSMutableString *text = [NSMutableString stringWithFormat: @"Search “%@” in %@", node.pattern, node.scope];
	const NSInteger files = static_cast<NSInteger>(node.children.count);
	if (node.finished || node.hitCount) {
		[text appendFormat: @" (%ld hit%@ in %ld file%@)", (long)node.hitCount, node.hitCount == 1 ? @"" : @"s", (long)files,
		                    files == 1 ? @"" : @"s"];
	}
	if (!node.finished)
		[text appendString: @" – searching…"];
	else if (node.note.length)
		[text appendFormat: @" – %@", node.note];
	return [[NSAttributedString alloc] initWithString: text attributes: @{
		NSFontAttributeName: [NSFont boldSystemFontOfSize: 12],
		NSForegroundColorAttributeName: [NSColor labelColor],
	}];
}

- (NSAttributedString *) titleForFile: (SearchNode *) node {
	const NSInteger hits = static_cast<NSInteger>(node.children.count);
	NSString *text = [NSString stringWithFormat: @"%@ (%ld hit%@)", node.name, (long)hits, hits == 1 ? @"" : @"s"];
	return [[NSAttributedString alloc] initWithString: text attributes: @{
		NSFontAttributeName: [NSFont systemFontOfSize: 12],
		NSForegroundColorAttributeName: [NSColor systemGreenColor],
	}];
}

- (NSAttributedString *) titleForHit: (const SearchHit &) hit {
	NSFont *font = [NSFont monospacedSystemFontOfSize: 11 weight: NSFontWeightRegular];
	NSDictionary *plain = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor labelColor]};
	NSDictionary *dim = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
	NSDictionary *marked = @{
		NSFontAttributeName: [NSFont monospacedSystemFontOfSize: 11 weight: NSFontWeightBold],
		NSForegroundColorAttributeName: [NSColor labelColor],
		NSBackgroundColorAttributeName: [[NSColor systemYellowColor] colorWithAlphaComponent: 0.45],
	};
	NSMutableAttributedString *title = [[NSMutableAttributedString alloc]
		initWithString: [NSString stringWithFormat: @"Line %ld: ", hit.line + 1] attributes: dim];

	const std::string &text = hit.lineText;
	const size_t markStart = std::min(hit.markStart, text.size());
	const size_t markEnd = std::min(markStart + hit.markLength, text.size());
	auto append = [&](size_t from, size_t to, NSDictionary *attributes) {
		if (to <= from)
			return;
		NSString *part = [[NSString alloc] initWithBytes: text.data() + from length: to - from encoding: NSUTF8StringEncoding];
		if (!part)
			part = [[NSString alloc] initWithBytes: text.data() + from length: to - from encoding: NSISOLatin1StringEncoding];
		if (part)
			[title appendAttributedString: [[NSAttributedString alloc] initWithString: part attributes: attributes]];
	};
	append(0, markStart, plain);
	append(markStart, markEnd, marked);
	append(markEnd, text.size(), plain);
	return title;
}

#pragma mark - Building results

- (id) beginSearchFor: (NSString *) pattern scope: (NSString *) scope {
	[self window];
	SearchNode *search = [[SearchNode alloc] init];
	search.kind = SearchNodeSearch;
	search.pattern = pattern ?: @"";
	search.scope = scope ?: @"";
	search.title = [self titleForSearch: search];
	[_searches insertObject: search atIndex: 0];
	// Older searches fold away, so the newest results are easy to find.
	for (SearchNode *older in _searches) {
		if (older != search)
			[_outline collapseItem: older];
	}
	[_nodesToExpand addObject: search];
	[self setNeedsReload];
	return search;
}

- (void) addHits: (const std::vector<SearchHit> &) hits forURL: (NSURL *) url document: (Document *) document toSearch: (id) token {
	SearchNode *search = token;
	if (![search isKindOfClass: [SearchNode class]] || ![_searches containsObject: search] || hits.empty())
		return;
	SearchNode *file = [[SearchNode alloc] init];
	file.kind = SearchNodeFile;
	file.parent = search;
	file.url = url;
	file.document = document;
	file.name = url ? [url.path stringByAbbreviatingWithTildeInPath] : (document.displayName ?: @"untitled");
	for (SearchHit hit : hits) {
		TrimHitLine(hit, 600);
		SearchNode *node = [[SearchNode alloc] init];
		node.kind = SearchNodeHit;
		node.parent = file;
		node.line = hit.line;
		node.start = hit.start;
		node.end = hit.end;
		node.title = [self titleForHit: hit];
		[file.children addObject: node];
	}
	file.title = [self titleForFile: file];
	[search.children addObject: file];
	search.hitCount += static_cast<NSInteger>(hits.size());
	search.title = [self titleForSearch: search];
	// Expanding thousands of files only makes the list harder to scan.
	if (search.children.count <= 200)
		[_nodesToExpand addObject: file];
	[self setNeedsReload];
}

- (void) finishSearch: (id) token note: (NSString *) note {
	SearchNode *search = token;
	if (![search isKindOfClass: [SearchNode class]])
		return;
	search.finished = YES;
	search.note = note;
	search.title = [self titleForSearch: search];
	[self setNeedsReload];
}

- (NSInteger) hitCountOfSearch: (id) search {
	return [search isKindOfClass: [SearchNode class]] ? ((SearchNode *)search).hitCount : 0;
}

- (NSInteger) fileCountOfSearch: (id) search {
	return [search isKindOfClass: [SearchNode class]] ? static_cast<NSInteger>(((SearchNode *)search).children.count) : 0;
}

// Results arrive file by file from a background search; the outline is refreshed a few times a second.
- (void) setNeedsReload {
	if (_reloadPending)
		return;
	_reloadPending = YES;
	[self performSelector: @selector(reloadNow) withObject: nil afterDelay: 0.15 inModes: @[NSRunLoopCommonModes]];
}

- (void) reloadNow {
	_reloadPending = NO;
	[_outline reloadData];
	for (SearchNode *node in _nodesToExpand)
		[_outline expandItem: node];
	[_nodesToExpand removeAllObjects];

	SearchNode *latest = _searches.firstObject;
	if (!latest)
		_summary.stringValue = @"No results.";
	else
		_summary.stringValue = latest.title.string;
}

- (IBAction) clearResults: (id) sender {
	[_searches removeAllObjects];
	[_nodesToExpand removeAllObjects];
	[self setNeedsReload];
}

#pragma mark - Opening a result

- (void) revealHit: (SearchNode *) hit inDocument: (Document *) document {
	EditorWindowController *controller = document.editorController;
	if (!controller)
		return;
	[controller.window makeKeyAndOrderFront: nil];
	ScintillaView *editor = controller.editor;
	const sptr_t length = SciCall(editor, SCI_GETLENGTH);
	// The document may have changed since the search: fall back to the line when the range moved.
	if (hit.end <= length && SciCall(editor, SCI_LINEFROMPOSITION, hit.start) == hit.line) {
		[controller selectRangeFrom: hit.start to: hit.end];
	} else {
		const sptr_t line = std::min<sptr_t>(hit.line, SciCall(editor, SCI_GETLINECOUNT) - 1);
		const sptr_t position = SciCall(editor, SCI_POSITIONFROMLINE, line);
		[controller selectRangeFrom: position to: position];
	}
}

- (IBAction) openSelectedResult: (id) sender {
	SearchNode *node = [_outline itemAtRow: _outline.clickedRow >= 0 ? _outline.clickedRow : _outline.selectedRow];
	if (!node)
		return;
	if (node.kind != SearchNodeHit) {
		if ([_outline isItemExpanded: node])
			[_outline collapseItem: node];
		else
			[_outline expandItem: node];
		return;
	}
	SearchNode *file = node.parent;
	Document *document = file.document;
	NSDocumentController *controller = [NSDocumentController sharedDocumentController];
	if (document && [controller.documents containsObject: document]) {
		[self revealHit: node inDocument: document];
		return;
	}
	if (!file.url) {
		NSBeep(); // the untitled document it was found in has been closed
		return;
	}
	[controller openDocumentWithContentsOfURL: file.url display: YES
	                        completionHandler: ^(NSDocument *opened, BOOL wasOpen, NSError *error) {
		if ([opened isKindOfClass: [Document class]])
			[self revealHit: node inDocument: (Document *)opened];
		else if (error)
			[NSApp presentError: error];
	}];
}

#pragma mark - Outline view

- (NSInteger) outlineView: (NSOutlineView *) outlineView numberOfChildrenOfItem: (id) item {
	return static_cast<NSInteger>(item ? ((SearchNode *)item).children.count : _searches.count);
}

- (id) outlineView: (NSOutlineView *) outlineView child: (NSInteger) index ofItem: (id) item {
	return item ? ((SearchNode *)item).children[static_cast<NSUInteger>(index)] : _searches[static_cast<NSUInteger>(index)];
}

- (BOOL) outlineView: (NSOutlineView *) outlineView isItemExpandable: (id) item {
	return ((SearchNode *)item).kind != SearchNodeHit;
}

- (NSView *) outlineView: (NSOutlineView *) outlineView viewForTableColumn: (NSTableColumn *) tableColumn item: (id) item {
	NSTableCellView *cell = [outlineView makeViewWithIdentifier: @"cell" owner: self];
	if (!cell) {
		cell = [[NSTableCellView alloc] initWithFrame: NSMakeRect(0, 0, 400, 18)];
		cell.identifier = @"cell";
		NSTextField *label = [NSTextField labelWithString: @""];
		label.lineBreakMode = NSLineBreakByClipping;
		label.cell.usesSingleLineMode = YES;
		label.frame = cell.bounds;
		label.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		[cell addSubview: label];
		cell.textField = label;
	}
	cell.textField.attributedStringValue = ((SearchNode *)item).title ?: [[NSAttributedString alloc] initWithString: @""];
	return cell;
}

@end
