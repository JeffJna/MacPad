// Find / Replace panel: find, replace, count, mark, Find All and Find in Files.
// This file is part of MacPad (GPL v3 or later).
#import "FindPanel.h"

#include <atomic>
#include <memory>
#include <vector>

#import "Document.h"
#import "EditorStyler.h"
#import "EditorWindowController.h"
#import "SciUtil.h"
#import "SearchResultsPanel.h"

#include "SearchEngine.h"
#include "TextEncoding.h"

static NSString *const kFindHistoryKey = @"findHistory";
static NSString *const kReplaceHistoryKey = @"replaceHistory";
static NSString *const kDirectoryHistoryKey = @"findDirectoryHistory";
static NSString *const kFilterHistoryKey = @"findFilterHistory";
static const NSUInteger kHistorySize = 20;

// Find in Files and Find All: files above this size are skipped, and a search stops
// collecting once it has this many hits.
static const unsigned long long kMaxSearchFileSize = 32 * 1024 * 1024;
static const size_t kMaxHitsPerFile = 5000;
static const size_t kMaxTotalHits = 50000;

namespace
{

struct SearchOptions
{
	std::string pattern;
	int flags = 0;
	bool regex = false;
	bool wrap = true;
};

void AppendUTF8(std::string &out, unsigned int codePoint)
{
	if (codePoint < 0x80)
	{
		out += static_cast<char>(codePoint);
	}
	else if (codePoint < 0x800)
	{
		out += static_cast<char>(0xC0 | (codePoint >> 6));
		out += static_cast<char>(0x80 | (codePoint & 0x3F));
	}
	else if (codePoint < 0x10000)
	{
		out += static_cast<char>(0xE0 | (codePoint >> 12));
		out += static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F));
		out += static_cast<char>(0x80 | (codePoint & 0x3F));
	}
	else
	{
		out += static_cast<char>(0xF0 | (codePoint >> 18));
		out += static_cast<char>(0x80 | ((codePoint >> 12) & 0x3F));
		out += static_cast<char>(0x80 | ((codePoint >> 6) & 0x3F));
		out += static_cast<char>(0x80 | (codePoint & 0x3F));
	}
}

// "Extended" search mode: \n, \r, \t, \0, \\, \xHH and \uHHHH.
std::string ExpandEscapes(const std::string &text)
{
	std::string out;
	for (size_t i = 0; i < text.size(); ++i)
	{
		const char c = text[i];
		if (c != '\\' || i + 1 >= text.size())
		{
			out += c;
			continue;
		}
		const char next = text[++i];
		switch (next)
		{
			case 'n': out += '\n'; break;
			case 'r': out += '\r'; break;
			case 't': out += '\t'; break;
			case '0': out += '\0'; break;
			case '\\': out += '\\'; break;
			case 'x':
			case 'u':
			{
				const size_t digits = next == 'x' ? 2 : 4;
				if (i + digits < text.size()) // enough characters for the hex digits
				{
					const std::string hex = text.substr(i + 1, digits);
					if (hex.size() == digits && hex.find_first_not_of("0123456789abcdefABCDEF") == std::string::npos)
					{
						const unsigned int value = static_cast<unsigned int>(std::stoul(hex, nullptr, 16));
						if (next == 'x')
							out += static_cast<char>(value);
						else
							AppendUTF8(out, value);
						i += digits;
						break;
					}
				}
				out += '\\';
				out += next;
				break;
			}
			default:
				out += '\\';
				out += next;
				break;
		}
	}
	return out;
}

sptr_t SearchRange(ScintillaView *editor, const SearchOptions &options, sptr_t start, sptr_t end)
{
	SciCall(editor, SCI_SETSEARCHFLAGS, options.flags);
	SciCall(editor, SCI_SETTARGETRANGE, start, end);
	return SciCall(editor, SCI_SEARCHINTARGET, options.pattern.size(), reinterpret_cast<sptr_t>(options.pattern.data()));
}

// True (once) after a search failed because the regular expression could not be compiled.
bool TakeRegexError(ScintillaView *editor)
{
	if (SciCall(editor, SCI_GETSTATUS) != SC_STATUS_WARN_REGEX)
		return false;
	SciCall(editor, SCI_SETSTATUS, 0);
	return true;
}

// Every match in an editor, with its line, for the search results window.
void CollectHits(ScintillaView *editor, const SearchOptions &options, std::vector<SearchHit> &hits, size_t limit)
{
	const sptr_t length = SciCall(editor, SCI_GETLENGTH);
	sptr_t position = 0;
	while (position <= length && hits.size() < limit)
	{
		const sptr_t found = SearchRange(editor, options, position, length);
		if (found < 0)
			break;
		const sptr_t matchEnd = SciCall(editor, SCI_GETTARGETEND);
		if (matchEnd <= found)
		{
			// Empty match (a regex such as ^ or \b): nothing to show, move on.
			if (found >= length)
				break;
			position = SciCall(editor, SCI_POSITIONAFTER, found);
			continue;
		}
		const sptr_t line = SciCall(editor, SCI_LINEFROMPOSITION, found);
		const sptr_t lineStart = SciCall(editor, SCI_POSITIONFROMLINE, line);
		const sptr_t lineEnd = SciCall(editor, SCI_GETLINEENDPOSITION, line);
		SearchHit hit;
		hit.line = line;
		hit.start = found;
		hit.end = matchEnd;
		hit.lineText = SciTextRange(editor, lineStart, lineEnd);
		hit.markStart = static_cast<size_t>(found - lineStart);
		hit.markLength = static_cast<size_t>(std::min(matchEnd, lineEnd) - found);
		hits.push_back(std::move(hit));
		position = matchEnd;
	}
}

// Files with a NUL byte near the start are not text (UTF-16 with a byte order mark aside).
bool LooksBinary(NSData *data)
{
	const unsigned char *bytes = static_cast<const unsigned char *>(data.bytes);
	const size_t length = std::min<size_t>(data.length, 8192);
	if (length >= 2 && ((bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF)))
		return false;
	return memchr(bytes, 0, length) != nullptr;
}

} // namespace

@implementation FindPanel
{
	NSComboBox *_findField;
	NSComboBox *_replaceField;
	NSButton *_wholeWord;
	NSButton *_matchCase;
	NSButton *_wrapAround;
	NSButton *_backward;
	NSButton *_modeNormal;
	NSButton *_modeExtended;
	NSButton *_modeRegex;
	NSButton *_inSelection;
	NSComboBox *_directoryField;
	NSComboBox *_filtersField;
	NSButton *_subfolders;
	NSButton *_hiddenFiles;
	NSButton *_findInFilesButton;
	NSTextField *_status;
	std::shared_ptr<std::atomic<bool>> _fileSearchCancel;
}

+ (instancetype) shared {
	static FindPanel *panel;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		panel = [[FindPanel alloc] init];
	});
	return panel;
}

- (instancetype) init {
	NSPanel *panel = [[NSPanel alloc] initWithContentRect: NSMakeRect(0, 0, 600, 384)
	                                            styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                                       NSWindowStyleMaskUtilityWindow
	                                              backing: NSBackingStoreBuffered
	                                                defer: YES];
	panel.title = @"Find / Replace";
	panel.floatingPanel = YES;
	panel.becomesKeyOnlyIfNeeded = NO;
	panel.hidesOnDeactivate = YES;
	panel.releasedWhenClosed = NO;
	self = [super initWithWindow: panel];
	if (self) {
		[self buildControlsInView: panel.contentView];
		[self loadOptions];
		// Only the position is remembered: the size of the panel is fixed.
		[panel center];
		NSString *origin = [[NSUserDefaults standardUserDefaults] stringForKey: @"findPanelOrigin"];
		if (origin) {
			const NSPoint point = NSPointFromString(origin);
			const NSRect frame = NSMakeRect(point.x, point.y, NSWidth(panel.frame), NSHeight(panel.frame));
			for (NSScreen *screen in NSScreen.screens) {
				if (NSContainsRect(screen.visibleFrame, frame)) {
					[panel setFrameOrigin: point];
					break;
				}
			}
		}
		[[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(panelDidMove:)
		                                             name: NSWindowDidMoveNotification object: panel];
	}
	return self;
}

- (NSTextField *) addLabel: (NSString *) text frame: (NSRect) frame toView: (NSView *) view {
	NSTextField *label = [NSTextField labelWithString: text];
	label.frame = frame;
	label.alignment = NSTextAlignmentRight;
	[view addSubview: label];
	return label;
}

- (NSComboBox *) addComboWithFrame: (NSRect) frame historyKey: (NSString *) key toView: (NSView *) view {
	NSComboBox *combo = [[NSComboBox alloc] initWithFrame: frame];
	combo.completes = NO;
	combo.numberOfVisibleItems = 12;
	NSArray<NSString *> *history = [[NSUserDefaults standardUserDefaults] stringArrayForKey: key];
	if (history.count)
		[combo addItemsWithObjectValues: history];
	[view addSubview: combo];
	return combo;
}

- (NSButton *) addCheckbox: (NSString *) title frame: (NSRect) frame toView: (NSView *) view {
	NSButton *button = [NSButton checkboxWithTitle: title target: nil action: nil];
	button.frame = frame;
	[view addSubview: button];
	return button;
}

- (NSButton *) addButton: (NSString *) title action: (SEL) action frame: (NSRect) frame toView: (NSView *) view {
	NSButton *button = [NSButton buttonWithTitle: title target: self action: action];
	button.frame = frame;
	[view addSubview: button];
	return button;
}

- (void) buildControlsInView: (NSView *) view {
	[self addLabel: @"Find what:" frame: NSMakeRect(12, 344, 96, 18) toView: view];
	_findField = [self addComboWithFrame: NSMakeRect(114, 340, 334, 26) historyKey: kFindHistoryKey toView: view];
	[self addLabel: @"Replace with:" frame: NSMakeRect(12, 310, 96, 18) toView: view];
	_replaceField = [self addComboWithFrame: NSMakeRect(114, 306, 334, 26) historyKey: kReplaceHistoryKey toView: view];

	_wholeWord = [self addCheckbox: @"Match whole word only" frame: NSMakeRect(16, 272, 206, 18) toView: view];
	_matchCase = [self addCheckbox: @"Match case" frame: NSMakeRect(16, 250, 206, 18) toView: view];
	_wrapAround = [self addCheckbox: @"Wrap around" frame: NSMakeRect(16, 228, 206, 18) toView: view];
	_wrapAround.state = NSControlStateValueOn;
	_backward = [self addCheckbox: @"Backward direction" frame: NSMakeRect(16, 206, 206, 18) toView: view];
	_inSelection = [self addCheckbox: @"In selection" frame: NSMakeRect(16, 184, 206, 18) toView: view];
	_inSelection.toolTip = @"Count, Replace All and Mark All only look inside the selected text.";

	NSBox *modeBox = [[NSBox alloc] initWithFrame: NSMakeRect(228, 182, 222, 108)];
	modeBox.title = @"Search Mode";
	[view addSubview: modeBox];
	NSView *modeView = modeBox.contentView;
	_modeNormal = [NSButton radioButtonWithTitle: @"Normal" target: self action: @selector(searchModeChanged:)];
	_modeExtended = [NSButton radioButtonWithTitle: @"Extended (\\n, \\r, \\t, \\0, \\x...)" target: self action: @selector(searchModeChanged:)];
	_modeRegex = [NSButton radioButtonWithTitle: @"Regular expression" target: self action: @selector(searchModeChanged:)];
	_modeNormal.frame = NSMakeRect(6, 52, 206, 18);
	_modeExtended.frame = NSMakeRect(6, 30, 206, 18);
	_modeRegex.frame = NSMakeRect(6, 8, 206, 18);
	for (NSButton *radio in @[_modeNormal, _modeExtended, _modeRegex])
		[modeView addSubview: radio];
	_modeNormal.state = NSControlStateValueOn;

	NSButton *findNext = [self addButton: @"Find Next" action: @selector(findNextClicked:) frame: NSMakeRect(460, 338, 126, 30) toView: view];
	findNext.keyEquivalent = @"\r";
	[self addButton: @"Count" action: @selector(countClicked:) frame: NSMakeRect(460, 304, 126, 30) toView: view];
	[self addButton: @"Replace" action: @selector(replaceClicked:) frame: NSMakeRect(460, 270, 126, 30) toView: view];
	[self addButton: @"Replace All" action: @selector(replaceAllClicked:) frame: NSMakeRect(460, 236, 126, 30) toView: view];
	[self addButton: @"Mark All" action: @selector(markAllClicked:) frame: NSMakeRect(460, 202, 126, 30) toView: view];

	[self addButton: @"Find All in Current Document" action: @selector(findAllInCurrentDocumentClicked:)
	          frame: NSMakeRect(12, 146, 286, 30) toView: view];
	[self addButton: @"Find All in All Opened Documents" action: @selector(findAllInOpenDocumentsClicked:)
	          frame: NSMakeRect(302, 146, 286, 30) toView: view];

	NSBox *separator = [[NSBox alloc] initWithFrame: NSMakeRect(12, 138, 576, 1)];
	separator.boxType = NSBoxSeparator;
	[view addSubview: separator];

	// Find in Files
	[self addLabel: @"Directory:" frame: NSMakeRect(12, 106, 96, 18) toView: view];
	_directoryField = [self addComboWithFrame: NSMakeRect(114, 102, 334, 26) historyKey: kDirectoryHistoryKey toView: view];
	_directoryField.placeholderString = @"Folder to search";
	[self addButton: @"Choose…" action: @selector(chooseDirectoryClicked:) frame: NSMakeRect(460, 100, 126, 30) toView: view];
	[self addLabel: @"Filters:" frame: NSMakeRect(12, 72, 96, 18) toView: view];
	_filtersField = [self addComboWithFrame: NSMakeRect(114, 68, 140, 26) historyKey: kFilterHistoryKey toView: view];
	_filtersField.stringValue = @"*.*";
	_filtersField.toolTip = @"File name patterns separated by spaces, for example: *.cpp *.h !*.min.js";
	_subfolders = [self addCheckbox: @"Sub-folders" frame: NSMakeRect(264, 72, 100, 18) toView: view];
	_subfolders.state = NSControlStateValueOn;
	_hiddenFiles = [self addCheckbox: @"Hidden" frame: NSMakeRect(366, 72, 84, 18) toView: view];
	_hiddenFiles.toolTip = @"Also search files and folders whose names start with a dot.";
	_findInFilesButton = [self addButton: @"Find in Files" action: @selector(findInFilesClicked:)
	                               frame: NSMakeRect(460, 66, 126, 30) toView: view];

	_status = [NSTextField labelWithString: @""];
	_status.frame = NSMakeRect(16, 12, 568, 34);
	_status.font = [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
	_status.lineBreakMode = NSLineBreakByWordWrapping;
	_status.maximumNumberOfLines = 2;
	[view addSubview: _status];
}

- (void) panelDidMove: (NSNotification *) notification {
	[[NSUserDefaults standardUserDefaults] setObject: NSStringFromPoint(self.window.frame.origin) forKey: @"findPanelOrigin"];
}

// The options last used are kept between launches.
- (void) loadOptions {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults registerDefaults: @{@"findWrapAround": @YES, @"findSubfolders": @YES}];
	auto state = [defaults](NSString *key) { return [defaults boolForKey: key] ? NSControlStateValueOn : NSControlStateValueOff; };
	_wholeWord.state = state(@"findWholeWord");
	_matchCase.state = state(@"findMatchCase");
	_wrapAround.state = state(@"findWrapAround");
	_subfolders.state = state(@"findSubfolders");
	_hiddenFiles.state = state(@"findHiddenFiles");
	const NSInteger mode = [defaults integerForKey: @"findMode"];
	_modeNormal.state = mode == 0 ? NSControlStateValueOn : NSControlStateValueOff;
	_modeExtended.state = mode == 1 ? NSControlStateValueOn : NSControlStateValueOff;
	_modeRegex.state = mode == 2 ? NSControlStateValueOn : NSControlStateValueOff;
	NSString *filters = [defaults stringArrayForKey: kFilterHistoryKey].firstObject;
	if (filters.length)
		_filtersField.stringValue = filters;
	NSString *directory = [defaults stringArrayForKey: kDirectoryHistoryKey].firstObject;
	if (directory.length)
		_directoryField.stringValue = directory;
	[self searchModeChanged: nil];
}

- (void) saveOptions {
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	[defaults setBool: _wholeWord.state == NSControlStateValueOn forKey: @"findWholeWord"];
	[defaults setBool: _matchCase.state == NSControlStateValueOn forKey: @"findMatchCase"];
	[defaults setBool: _wrapAround.state == NSControlStateValueOn forKey: @"findWrapAround"];
	[defaults setBool: _subfolders.state == NSControlStateValueOn forKey: @"findSubfolders"];
	[defaults setBool: _hiddenFiles.state == NSControlStateValueOn forKey: @"findHiddenFiles"];
	[defaults setInteger: _modeRegex.state == NSControlStateValueOn ? 2 : (_modeExtended.state == NSControlStateValueOn ? 1 : 0)
	              forKey: @"findMode"];
}

#pragma mark - Public

- (NSString *) findString {
	[self window];
	return _findField.stringValue;
}

- (void) setFindString: (NSString *) findString {
	[self window];
	_findField.stringValue = findString ?: @"";
}

- (void) showWithFindString: (NSString *) text focusReplace: (BOOL) focusReplace {
	[self window];
	if (text.length)
		_findField.stringValue = text;
	[self setStatus: @"" colour: nil];
	[self.window makeKeyAndOrderFront: nil];
	NSComboBox *field = focusReplace ? _replaceField : _findField;
	[self.window makeFirstResponder: field];
	[field selectText: nil];
}

- (void) showForFindInFilesWithFindString: (NSString *) text directory: (NSURL *) directory {
	[self window];
	// Start from the folder of the current document unless another one is already filled in.
	if (directory && _directoryField.stringValue.length == 0)
		_directoryField.stringValue = [directory.path stringByAbbreviatingWithTildeInPath];
	[self showWithFindString: text focusReplace: NO];
	if (_findField.stringValue.length)
		[self.window makeFirstResponder: _directoryField.stringValue.length ? _findInFilesButton : _directoryField];
}

- (BOOL) fileSearchRunning {
	return _fileSearchCancel != nullptr;
}

- (void) cancelOperation: (id) sender {
	[self.window orderOut: sender];
}

// Search > Find Next / Find Previous while the panel itself is the key window.
- (IBAction) findNext: (id) sender {
	[self findInEditor: [self targetEditor] backward: NO];
}

- (IBAction) findPrevious: (id) sender {
	[self findInEditor: [self targetEditor] backward: YES];
}

#pragma mark - Options

// The editor window the panel works on: the main window, or the frontmost editor window
// when there is no main window (the app is in the background, or a panel is in front).
- (EditorWindowController *) targetController {
	NSWindowController *controller = NSApp.mainWindow.windowController;
	if ([controller isKindOfClass: [EditorWindowController class]])
		return (EditorWindowController *)controller;
	for (NSWindow *window in NSApp.orderedWindows) {
		if (window.visible && [window.windowController isKindOfClass: [EditorWindowController class]])
			return window.windowController;
	}
	return nil;
}

- (ScintillaView *) targetEditor {
	return [self targetController].editor;
}

- (void) searchModeChanged: (id) sender {
	_wholeWord.enabled = _modeRegex.state != NSControlStateValueOn;
}

- (BOOL) isExtended {
	return _modeExtended.state == NSControlStateValueOn;
}

- (BOOL) getOptions: (SearchOptions &) options {
	[self window];
	NSString *text = _findField.stringValue;
	if (text.length == 0) {
		[self setStatus: @"Find: the search text is empty." colour: [NSColor systemRedColor]];
		return NO;
	}
	[self remember: text inCombo: _findField key: kFindHistoryKey];
	options.pattern = ToStdString(text);
	options.regex = _modeRegex.state == NSControlStateValueOn;
	if ([self isExtended])
		options.pattern = ExpandEscapes(options.pattern);
	options.flags = (_matchCase.state == NSControlStateValueOn ? SCFIND_MATCHCASE : 0) |
	                (!options.regex && _wholeWord.state == NSControlStateValueOn ? SCFIND_WHOLEWORD : 0) |
	                (options.regex ? SCFIND_REGEXP | SCFIND_CXX11REGEX : 0);
	options.wrap = _wrapAround.state == NSControlStateValueOn;
	[self saveOptions];
	return YES;
}

- (std::string) replacementText {
	NSString *text = _replaceField.stringValue;
	[self remember: text inCombo: _replaceField key: kReplaceHistoryKey];
	const std::string replacement = ToStdString(text);
	return [self isExtended] ? ExpandEscapes(replacement) : replacement;
}

- (void) remember: (NSString *) text inCombo: (NSComboBox *) combo key: (NSString *) key {
	if (text.length == 0)
		return;
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	NSMutableArray<NSString *> *history = [[defaults stringArrayForKey: key] mutableCopy] ?: [NSMutableArray array];
	if (history.count && [history.firstObject isEqualToString: text])
		return;
	[history removeObject: text];
	[history insertObject: text atIndex: 0];
	while (history.count > kHistorySize)
		[history removeLastObject];
	[defaults setObject: history forKey: key];

	NSString *current = combo.stringValue;
	[combo removeAllItems];
	[combo addItemsWithObjectValues: history];
	combo.stringValue = current;
}

- (void) setStatus: (NSString *) text colour: (NSColor *) colour {
	_status.stringValue = text ?: @"";
	_status.textColor = colour ?: [NSColor secondaryLabelColor];
}

#pragma mark - Searching

- (BOOL) findInEditor: (ScintillaView *) editor backward: (BOOL) backward {
	if (!editor)
		return NO;
	SearchOptions options;
	if (![self getOptions: options]) {
		[self showWithFindString: nil focusReplace: NO];
		return NO;
	}

	const sptr_t length = SciCall(editor, SCI_GETLENGTH);
	const sptr_t selStart = SciCall(editor, SCI_GETSELECTIONSTART);
	const sptr_t selEnd = SciCall(editor, SCI_GETSELECTIONEND);
	const sptr_t start = backward ? selStart : selEnd;
	sptr_t found = SearchRange(editor, options, start, backward ? 0 : length);

	// An empty regex match at the caret would never move forward: step over it.
	if (found >= 0 && found == start && SciCall(editor, SCI_GETTARGETEND) == found && selStart == selEnd) {
		if (!backward && start < length)
			found = SearchRange(editor, options, SciCall(editor, SCI_POSITIONAFTER, start), length);
		else if (backward && start > 0)
			found = SearchRange(editor, options, SciCall(editor, SCI_POSITIONBEFORE, start), 0);
		else
			found = -1;
	}

	BOOL wrapped = NO;
	if (found < 0 && options.wrap) {
		found = SearchRange(editor, options, backward ? length : 0, backward ? 0 : length);
		wrapped = found >= 0;
	}

	if (found < 0) {
		if (TakeRegexError(editor))
			[self setStatus: @"Find: Invalid regular expression" colour: [NSColor systemRedColor]];
		else
			[self setStatus: [NSString stringWithFormat: @"Find: Can't find the text \"%@\"", _findField.stringValue]
			         colour: [NSColor systemRedColor]];
		NSBeep();
		return NO;
	}

	const sptr_t matchEnd = SciCall(editor, SCI_GETTARGETEND);
	SciCall(editor, SCI_ENSUREVISIBLEENFORCEPOLICY, SciCall(editor, SCI_LINEFROMPOSITION, found));
	SciCall(editor, SCI_SETSEL, found, matchEnd);
	SciCall(editor, SCI_SCROLLRANGE, matchEnd, found);
	if (wrapped) {
		[self setStatus: backward ? @"Find: Found the 1st occurrence from the bottom. The beginning of the document has been reached."
		                          : @"Find: Found the 1st occurrence from the top. The end of the document has been reached."
		         colour: [NSColor systemGreenColor]];
	} else {
		[self setStatus: @"" colour: nil];
	}
	return YES;
}

// The part of the document that Count, Replace All and Mark All work on: the selection
// when "In selection" is ticked and there is one, otherwise everything.
- (void) scopeInEditor: (ScintillaView *) editor start: (sptr_t *) start end: (sptr_t *) end {
	*start = 0;
	*end = SciCall(editor, SCI_GETLENGTH);
	if (_inSelection.state != NSControlStateValueOn)
		return;
	const sptr_t selStart = SciCall(editor, SCI_GETSELECTIONSTART);
	const sptr_t selEnd = SciCall(editor, SCI_GETSELECTIONEND);
	if (selEnd > selStart) {
		*start = selStart;
		*end = selEnd;
	}
}

- (NSString *) scopeName {
	return _inSelection.state == NSControlStateValueOn ? @"selected text" : @"entire file";
}

// Visits every match between `start` and `end`: replaces it when `replacement` is given,
// otherwise fills the current indicator over it. Returns the number of matches, and through
// `finalEnd` where the range ends after the replacements changed its length.
- (NSInteger) forEachMatchInEditor: (ScintillaView *) editor
                           options: (const SearchOptions &) options
                             start: (sptr_t) position
                               end: (sptr_t) end
                           replace: (const std::string *) replacement
                          finalEnd: (sptr_t *) finalEnd {
	NSInteger count = 0;
	while (count < 10000000 && position <= end) {
		const sptr_t found = SearchRange(editor, options, position, end);
		if (found < 0)
			break;
		const sptr_t matchEnd = SciCall(editor, SCI_GETTARGETEND);
		sptr_t next = matchEnd;
		if (replacement) {
			const sptr_t replacedLength = SciCall(editor, options.regex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
			                                      replacement->size(), reinterpret_cast<sptr_t>(replacement->data()));
			next = found + replacedLength;
			end += replacedLength - (matchEnd - found);
		} else {
			SciCall(editor, SCI_INDICATORFILLRANGE, found, matchEnd - found);
		}
		++count;
		if (matchEnd == found) { // empty match: move on by one character
			if (next >= end)
				break;
			next = SciCall(editor, SCI_POSITIONAFTER, next);
		}
		position = next;
	}
	if (finalEnd)
		*finalEnd = end;
	return count;
}

// Reports a regular expression that Scintilla could not compile. Returns YES if there was one.
- (BOOL) reportRegexErrorInEditor: (ScintillaView *) editor {
	if (!TakeRegexError(editor))
		return NO;
	[self setStatus: @"Find: Invalid regular expression" colour: [NSColor systemRedColor]];
	NSBeep();
	return YES;
}

- (IBAction) findNextClicked: (id) sender {
	[self findInEditor: [self targetEditor] backward: _backward.state == NSControlStateValueOn];
}

- (IBAction) countClicked: (id) sender {
	ScintillaView *editor = [self targetEditor];
	SearchOptions options;
	if (!editor || ![self getOptions: options])
		return;
	sptr_t start = 0, end = 0;
	[self scopeInEditor: editor start: &start end: &end];
	// Count with a scratch indicator so nothing visible changes.
	const sptr_t previousIndicator = SciCall(editor, SCI_GETINDICATORCURRENT);
	SciCall(editor, SCI_SETINDICATORCURRENT, INDICATOR_MAX);
	const NSInteger count = [self forEachMatchInEditor: editor options: options start: start end: end replace: nullptr finalEnd: nullptr];
	SciCall(editor, SCI_INDICATORCLEARRANGE, 0, SciCall(editor, SCI_GETLENGTH));
	SciCall(editor, SCI_SETINDICATORCURRENT, previousIndicator);
	if ([self reportRegexErrorInEditor: editor])
		return;
	[self setStatus: [NSString stringWithFormat: @"Count: %ld match%@ in %@", (long)count, count == 1 ? @"" : @"es", [self scopeName]]
	         colour: [NSColor systemBlueColor]];
}

- (IBAction) replaceClicked: (id) sender {
	ScintillaView *editor = [self targetEditor];
	SearchOptions options;
	if (!editor || ![self getOptions: options])
		return;
	const std::string replacement = [self replacementText];
	const BOOL backward = _backward.state == NSControlStateValueOn;

	// Replace the current selection if it is a match, then move to the next one.
	const sptr_t selStart = SciCall(editor, SCI_GETSELECTIONSTART);
	const sptr_t selEnd = SciCall(editor, SCI_GETSELECTIONEND);
	if (selStart != selEnd) {
		const sptr_t found = SearchRange(editor, options, selStart, selEnd);
		if (found == selStart && SciCall(editor, SCI_GETTARGETEND) == selEnd) {
			const sptr_t replacedLength = SciCall(editor, options.regex ? SCI_REPLACETARGETRE : SCI_REPLACETARGET,
			                                      replacement.size(), reinterpret_cast<sptr_t>(replacement.data()));
			const sptr_t caret = backward ? selStart : selStart + replacedLength;
			SciCall(editor, SCI_SETSEL, caret, caret);
		}
	}
	[self findInEditor: editor backward: backward];
}

- (IBAction) replaceAllClicked: (id) sender {
	ScintillaView *editor = [self targetEditor];
	SearchOptions options;
	if (!editor || ![self getOptions: options])
		return;
	const std::string replacement = [self replacementText];
	sptr_t start = 0, end = 0;
	[self scopeInEditor: editor start: &start end: &end];
	const BOOL inSelection = end - start != SciCall(editor, SCI_GETLENGTH);
	sptr_t finalEnd = end;
	SciCall(editor, SCI_BEGINUNDOACTION);
	const NSInteger count = [self forEachMatchInEditor: editor options: options start: start end: end replace: &replacement finalEnd: &finalEnd];
	SciCall(editor, SCI_ENDUNDOACTION);
	if ([self reportRegexErrorInEditor: editor])
		return;
	if (inSelection && count)
		SciCall(editor, SCI_SETSEL, start, finalEnd); // keep the (resized) selection for another pass
	[self setStatus: [NSString stringWithFormat: @"Replace All: %ld occurrence%@ replaced in %@.", (long)count,
	                  count == 1 ? @" was" : @"s were", [self scopeName]]
	         colour: count ? [NSColor systemBlueColor] : [NSColor systemRedColor]];
}

- (IBAction) markAllClicked: (id) sender {
	ScintillaView *editor = [self targetEditor];
	SearchOptions options;
	if (!editor || ![self getOptions: options])
		return;
	sptr_t start = 0, end = 0;
	[self scopeInEditor: editor start: &start end: &end];
	SciCall(editor, SCI_SETINDICATORCURRENT, kIndicatorMarkAll);
	SciCall(editor, SCI_INDICATORCLEARRANGE, 0, SciCall(editor, SCI_GETLENGTH));
	const NSInteger count = [self forEachMatchInEditor: editor options: options start: start end: end replace: nullptr finalEnd: nullptr];
	if ([self reportRegexErrorInEditor: editor])
		return;
	[self setStatus: [NSString stringWithFormat: @"Mark: %ld match%@ in %@", (long)count, count == 1 ? @"" : @"es", [self scopeName]]
	         colour: [NSColor systemBlueColor]];
}

#pragma mark - Find All

- (void) findAllInDocuments: (NSArray<Document *> *) documents scope: (NSString *) scope {
	SearchOptions options;
	if (documents.count == 0 || ![self getOptions: options])
		return;
	SearchResultsPanel *results = [SearchResultsPanel shared];
	id search = [results beginSearchFor: _findField.stringValue scope: scope];
	size_t total = 0;
	for (Document *document in documents) {
		ScintillaView *editor = document.editorController.editor;
		if (!editor || total >= kMaxTotalHits)
			continue;
		std::vector<SearchHit> hits;
		CollectHits(editor, options, hits, std::min(kMaxHitsPerFile, kMaxTotalHits - total));
		if ([self reportRegexErrorInEditor: editor]) {
			[results finishSearch: search note: @"invalid regular expression"];
			return;
		}
		total += hits.size();
		[results addHits: hits forURL: document.fileURL document: document toSearch: search];
	}
	[results finishSearch: search note: total >= kMaxTotalHits ? @"stopped at the limit" : nil];
	const NSInteger files = [results fileCountOfSearch: search];
	[self setStatus: [NSString stringWithFormat: @"Find All: %lu hit%@ in %ld document%@", (unsigned long)total, total == 1 ? @"" : @"s",
	                  (long)files, files == 1 ? @"" : @"s"]
	         colour: total ? [NSColor systemBlueColor] : [NSColor systemRedColor]];
	if (total)
		[results showWindow: nil];
}

- (IBAction) findAllInCurrentDocumentClicked: (id) sender {
	Document *document = [self targetController].document;
	if ([document isKindOfClass: [Document class]])
		[self findAllInDocuments: @[document] scope: document.displayName];
}

- (IBAction) findAllInOpenDocumentsClicked: (id) sender {
	NSMutableArray<Document *> *documents = [NSMutableArray array];
	for (NSDocument *document in [NSDocumentController sharedDocumentController].documents) {
		if ([document isKindOfClass: [Document class]])
			[documents addObject: (Document *)document];
	}
	[self findAllInDocuments: documents scope: @"all opened documents"];
}

#pragma mark - Find in Files

- (IBAction) chooseDirectoryClicked: (id) sender {
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.canChooseDirectories = YES;
	panel.canChooseFiles = NO;
	panel.allowsMultipleSelection = NO;
	panel.prompt = @"Choose";
	NSString *current = [_directoryField.stringValue stringByExpandingTildeInPath];
	if (current.length)
		panel.directoryURL = [NSURL fileURLWithPath: current isDirectory: YES];
	[panel beginSheetModalForWindow: self.window completionHandler: ^(NSModalResponse response) {
		if (response == NSModalResponseOK && panel.URL)
			self->_directoryField.stringValue = [panel.URL.path stringByAbbreviatingWithTildeInPath];
	}];
}

// Searches the files of a folder on a background queue. The files are read from disk, so
// unsaved changes in open documents are not seen; patterns use ICU regular expressions.
- (IBAction) findInFilesClicked: (id) sender {
	if (_fileSearchCancel) { // the button reads "Stop" while a search runs
		_fileSearchCancel->store(true);
		return;
	}
	SearchOptions options;
	if (![self getOptions: options])
		return;
	SearchQuery query;
	query.pattern = options.pattern;
	query.matchCase = (options.flags & SCFIND_MATCHCASE) != 0;
	query.wholeWord = (options.flags & SCFIND_WHOLEWORD) != 0;
	query.regex = options.regex;
	NSString *error = nil;
	NSRegularExpression *expression = CompileSearchQuery(query, &error);
	if (!expression) {
		[self setStatus: [NSString stringWithFormat: @"Find in Files: %@", error ?: @"invalid search text"] colour: [NSColor systemRedColor]];
		NSBeep();
		return;
	}

	NSString *typed = [_directoryField.stringValue stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
	NSString *path = [typed stringByExpandingTildeInPath];
	BOOL isDirectory = NO;
	if (!typed.length || ![[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isDirectory] || !isDirectory) {
		[self setStatus: @"Find in Files: choose the folder to search." colour: [NSColor systemRedColor]];
		[self.window makeFirstResponder: _directoryField];
		NSBeep();
		return;
	}
	[self remember: typed inCombo: _directoryField key: kDirectoryHistoryKey];
	NSString *filters = _filtersField.stringValue.length ? _filtersField.stringValue : @"*.*";
	[self remember: filters inCombo: _filtersField key: kFilterHistoryKey];
	const FileFilter filter = FileFilter::Parse(ToStdString(filters));
	const BOOL recursive = _subfolders.state == NSControlStateValueOn;
	const BOOL hidden = _hiddenFiles.state == NSControlStateValueOn;

	SearchResultsPanel *results = [SearchResultsPanel shared];
	NSString *scope = [NSString stringWithFormat: @"%@ (%@)", [path stringByAbbreviatingWithTildeInPath], filters];
	id search = [results beginSearchFor: _findField.stringValue scope: scope];
	[results showWindow: nil];

	auto cancel = std::make_shared<std::atomic<bool>>(false);
	_fileSearchCancel = cancel;
	_findInFilesButton.title = @"Stop";
	[self setStatus: @"Find in Files: searching…" colour: nil];

	NSURL *root = [NSURL fileURLWithPath: path isDirectory: YES];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSDirectoryEnumerationOptions enumeration = NSDirectoryEnumerationSkipsPackageDescendants;
		if (!hidden)
			enumeration |= NSDirectoryEnumerationSkipsHiddenFiles;
		if (!recursive)
			enumeration |= NSDirectoryEnumerationSkipsSubdirectoryDescendants;
		NSDirectoryEnumerator<NSURL *> *files =
			[[NSFileManager defaultManager] enumeratorAtURL: root
			                     includingPropertiesForKeys: @[NSURLIsRegularFileKey, NSURLFileSizeKey]
			                                        options: enumeration
			                                   errorHandler: ^BOOL(NSURL *url, NSError *enumerationError) {
				return YES; // unreadable folders are skipped
			}];
		NSInteger searched = 0;
		size_t total = 0;
		for (NSURL *url in files) {
			if (cancel->load() || total >= kMaxTotalHits)
				break;
			@autoreleasepool {
				NSNumber *regular = nil, *size = nil;
				[url getResourceValue: &regular forKey: NSURLIsRegularFileKey error: nil];
				[url getResourceValue: &size forKey: NSURLFileSizeKey error: nil];
				if (!regular.boolValue || size.unsignedLongLongValue == 0 || size.unsignedLongLongValue > kMaxSearchFileSize)
					continue;
				if (!filter.Matches(ToStdString(url.lastPathComponent)))
					continue;
				NSData *data = [NSData dataWithContentsOfURL: url options: NSDataReadingMappedIfSafe error: nil];
				if (!data || LooksBinary(data))
					continue;
				std::string text;
				FileEncoding encoding;
				if (!DecodeText(data, text, encoding))
					continue;
				++searched;
				auto hits = std::make_shared<std::vector<SearchHit>>();
				SearchText(text, expression, *hits, std::min(kMaxHitsPerFile, kMaxTotalHits - total));
				if (hits->empty())
					continue;
				total += hits->size();
				for (SearchHit &hit : *hits)
					TrimHitLine(hit, 600);
				dispatch_async(dispatch_get_main_queue(), ^{
					[results addHits: *hits forURL: url document: nil toSearch: search];
				});
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (self->_fileSearchCancel == cancel) {
				self->_fileSearchCancel = nullptr;
				self->_findInFilesButton.title = @"Find in Files";
			}
			NSString *note = cancel->load() ? @"stopped" : (total >= kMaxTotalHits ? @"stopped at the limit" : nil);
			[results finishSearch: search note: note];
			const NSInteger matched = [results fileCountOfSearch: search];
			[self setStatus: [NSString stringWithFormat: @"Find in Files: %lu hit%@ in %ld file%@ (%ld file%@ searched)%@",
			                  (unsigned long)total, total == 1 ? @"" : @"s", (long)matched, matched == 1 ? @"" : @"s",
			                  (long)searched, searched == 1 ? @"" : @"s", note ? [@" – " stringByAppendingString: note] : @""]
			         colour: total ? [NSColor systemBlueColor] : [NSColor systemRedColor]];
		});
	});
}

@end
