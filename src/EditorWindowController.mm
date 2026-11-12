// One editor window (or window tab): a Scintilla view plus the status bar.
// This file is part of MacPad (GPL v3 or later).
#import "EditorWindowController.h"

#import "AppDelegate.h"
#import "AppSettings.h"
#import "CloudDocuments.h"
#import "Document.h"
#import "EditorStyler.h"
#import "FindPanel.h"
#import "MacroRecorder.h"
#import "SearchResultsPanel.h"
#import "SessionManager.h"
#import "StatusBar.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <strings.h>
#include <vector>

#include "Completion.h"
#include "LanguageCatalog.h"
#include "TextTools.h"
#include "Theme.h"

static NSString *const kWindowFrameName = @"EditorWindow";
static const CGFloat kStatusBarHeight = 22;
// Documents up to this size are scanned for words to complete.
static const sptr_t kWordScanLimit = 4 * 1024 * 1024;
// Documents up to this size print with syntax colours.
static const sptr_t kColourPrintLimit = 8 * 1024 * 1024;

namespace
{

bool IsWordChar(unsigned char c)
{
	return std::isalnum(c) || c == '_' || c >= 0x80;
}

bool IsBrace(int c)
{
	return c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}';
}

std::string EolString(int eolMode)
{
	switch (eolMode)
	{
		case SC_EOL_CRLF:
			return "\r\n";
		case SC_EOL_CR:
			return "\r";
		default:
			return "\n";
	}
}

FileEncoding EncodingForTag(NSInteger tag)
{
	switch (tag)
	{
		case 2:
			return FileEncoding::Make(FileEncoding::UTF8_BOM);
		case 3:
			return FileEncoding::Make(FileEncoding::UTF16BE_BOM);
		case 4:
			return FileEncoding::Make(FileEncoding::UTF16LE_BOM);
		case 5:
			return FileEncoding::MakeLegacy(kCFStringEncodingWindowsLatin1);
		default:
			return FileEncoding::Make(FileEncoding::UTF8);
	}
}

} // namespace

@interface EditorWindowController () <StatusBarDelegate>
@end

@implementation EditorWindowController
{
	ScintillaView *_editor;
	StatusBar *_status;
	NSNumberFormatter *_numberFormatter;
	// Closing brackets and quotes inserted automatically on `_pendingCloserLine`;
	// typing one of them steps over it instead of inserting a second one.
	std::vector<char> _pendingClosers;
	sptr_t _pendingCloserLine;
}

- (instancetype) init {
	NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(0, 0, 960, 680)
	                                               styleMask: NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
	                                                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
	                                                 backing: NSBackingStoreBuffered
	                                                   defer: YES];
	window.tabbingMode = NSWindowTabbingModePreferred;
	window.tabbingIdentifier = kWindowFrameName;
	window.minSize = NSMakeSize(420, 240);
	window.releasedWhenClosed = NO;
	window.restorable = NO; // SessionManager reopens documents, unsaved text included
	if (![window setFrameUsingName: kWindowFrameName])
		[window center];

	self = [super initWithWindow: window];
	if (self) {
		window.delegate = self;
		_numberFormatter = [[NSNumberFormatter alloc] init];
		_numberFormatter.numberStyle = NSNumberFormatterDecimalStyle;
		[self buildContentInWindow: window];

		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		[center addObserver: self selector: @selector(settingsDidChange:) name: AppSettingsDidChangeNotification object: nil];
		[center addObserver: self selector: @selector(themeDidChange:) name: AppThemeDidChangeNotification object: nil];
	}
	return self;
}

- (void) dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self];
}

- (void) buildContentInWindow: (NSWindow *) window {
	NSView *content = window.contentView;
	const NSRect bounds = content.bounds;

	_status = [[StatusBar alloc] initWithFrame: NSMakeRect(0, 0, NSWidth(bounds), kStatusBarHeight)];
	_status.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
	_status.delegate = self;
	[content addSubview: _status];

	_editor = [[ScintillaView alloc] initWithFrame: NSMakeRect(0, kStatusBarHeight, NSWidth(bounds), NSHeight(bounds) - kStatusBarHeight)];
	_editor.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
	_editor.delegate = self;
	[content addSubview: _editor];

	ConfigureEditor(_editor);
	ApplyViewSettings(_editor, [AppSettings shared].viewSettings);
	window.initialFirstResponder = _editor.content;
}

- (ScintillaView *) editor {
	return _editor;
}

- (Document *) doc {
	return (Document *)self.document;
}

- (void) setDocument: (id) document {
	[super setDocument: document];
	Document *doc = (Document *)document;
	if (!doc || ![doc isKindOfClass: [Document class]])
		return;
	[self loadText: [doc takeLoadedText] keepPosition: NO];
	[self applyLanguage];
	[self updateTabDecoration];
}

#pragma mark - Title and tab

- (void) synchronizeWindowTitleWithDocumentName {
	[super synchronizeWindowTitleWithDocumentName];
	[self updateTabDecoration];
}

- (void) setDocumentEdited: (BOOL) edited {
	[super setDocumentEdited: edited];
	[self updateTabDecoration];
}

// The folder next to the title, the full path as the tab's tool tip, and a dot on the tab
// of a document with unsaved changes (native window tabs do not show one themselves).
- (void) updateTabDecoration {
	Document *doc = [self doc];
	NSWindow *window = self.window;
	if (!doc || !window)
		return;
	NSURL *url = doc.fileURL;
	window.subtitle = url ? [url.path.stringByDeletingLastPathComponent stringByAbbreviatingWithTildeInPath] : @"";
	window.tab.toolTip = url ? url.path : doc.displayName;

	const BOOL edited = doc.hasUnsavedChanges;
	if (edited == (window.tab.accessoryView != nil))
		return;
	if (!edited) {
		window.tab.accessoryView = nil;
		return;
	}
	NSImage *dot = [NSImage imageWithSystemSymbolName: @"circle.fill" accessibilityDescription: @"Unsaved changes"];
	dot = [dot imageWithSymbolConfiguration: [NSImageSymbolConfiguration configurationWithPointSize: 7 weight: NSFontWeightRegular]];
	NSImageView *view = [NSImageView imageViewWithImage: dot ?: [NSImage imageNamed: NSImageNameStatusPartiallyAvailable]];
	view.contentTintColor = [NSColor systemOrangeColor];
	view.toolTip = @"Unsaved changes";
	window.tab.accessoryView = view;
}

- (void) showWindow: (id) sender {
	[super showWindow: sender];
	[self.window makeFirstResponder: _editor.content];
}

#pragma mark - Text

- (sptr_t) call: (unsigned int) message {
	return SciCall(_editor, message);
}

- (sptr_t) call: (unsigned int) message w: (uptr_t) wParam {
	return SciCall(_editor, message, wParam);
}

- (sptr_t) call: (unsigned int) message w: (uptr_t) wParam l: (sptr_t) lParam {
	return SciCall(_editor, message, wParam, lParam);
}

- (void) loadText: (const std::string &) text keepPosition: (BOOL) keepPosition {
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	const sptr_t anchor = [self call: SCI_GETANCHOR];
	const sptr_t firstLine = [self call: SCI_GETFIRSTVISIBLELINE];

	// Load without undo history, then turn change history on (it needs an empty undo buffer).
	[self call: SCI_SETCHANGEHISTORY w: SC_CHANGE_HISTORY_DISABLED];
	[self call: SCI_SETUNDOCOLLECTION w: 0];
	[self call: SCI_CLEARALL];
	if (!keepPosition)
		[self call: SCI_MARKERDELETEALL w: static_cast<uptr_t>(-1)];
	if (!text.empty()) {
		[self call: SCI_ALLOCATE w: text.size() + 4096];
		[self call: SCI_APPENDTEXT w: text.size() l: reinterpret_cast<sptr_t>(text.data())];
	}
	_pendingClosers.clear();
	[self call: SCI_SETUNDOCOLLECTION w: 1];
	[self call: SCI_EMPTYUNDOBUFFER];
	[self call: SCI_SETSAVEPOINT];
	[self call: SCI_SETCHANGEHISTORY w: SC_CHANGE_HISTORY_ENABLED | SC_CHANGE_HISTORY_MARKERS];

	Document *doc = [self doc];
	if (doc)
		[self call: SCI_SETEOLMODE w: LineEndingToSciMode(doc.lineEnding)];

	if (keepPosition) {
		const sptr_t length = [self call: SCI_GETLENGTH];
		[self call: SCI_SETSEL w: std::min(anchor, length) l: std::min(caret, length)];
		[self call: SCI_SETFIRSTVISIBLELINE w: firstLine];
	} else {
		[self call: SCI_GOTOPOS w: 0];
	}
	UpdateLineNumberMargin(_editor, [AppSettings shared].showLineNumbers);
	[self refreshStatus];
}

- (std::string) documentText {
	return SciDocumentText(_editor);
}

- (void) markSavePoint {
	[self call: SCI_SETSAVEPOINT];
}

- (void) documentDidSave {
	[self updateTabDecoration];
	[self refreshStatus];
}

- (void) applyLanguage {
	Document *doc = [self doc];
	if (!doc)
		return;
	AppSettings *settings = [AppSettings shared];
	std::shared_ptr<Theme> theme = settings.currentTheme;
	ApplyLanguage(_editor, *doc.language, *theme, settings.editorFont);
	ApplyCaretLine(_editor, *theme, settings.highlightCurrentLine);
	// Match the window chrome (scroll bars, tab bar) to the editor colours.
	self.window.appearance = [NSAppearance appearanceNamed: theme->IsDark() ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
	UpdateLineNumberMargin(_editor, [AppSettings shared].showLineNumbers);
	[self highlightMatchingBrace];
	[self updateSmartHighlight];
	[self refreshStatus];
}

- (void) settingsDidChange: (NSNotification *) notification {
	AppSettings *settings = [AppSettings shared];
	ApplyViewSettings(_editor, settings.viewSettings);
	ApplyCaretLine(_editor, *settings.currentTheme, settings.highlightCurrentLine);
	[self highlightMatchingBrace];
	[self updateSmartHighlight];
}

- (void) themeDidChange: (NSNotification *) notification {
	[self applyLanguage];
}

#pragma mark - Status bar

- (NSString *) formatNumber: (sptr_t) value {
	return [_numberFormatter stringFromNumber: @(value)] ?: [NSString stringWithFormat: @"%ld", (long)value];
}

- (void) refreshStatus {
	Document *doc = [self doc];
	if (!doc)
		return;
	[_status setText: ToNSString(doc.language->description) forSection: StatusBarSectionLanguage];
	[_status setText: [NSString stringWithFormat: @"length : %@    lines : %@",
	                   [self formatNumber: [self call: SCI_GETLENGTH]], [self formatNumber: [self call: SCI_GETLINECOUNT]]]
	      forSection: StatusBarSectionDocument];

	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	const sptr_t line = [self call: SCI_LINEFROMPOSITION w: caret];
	const sptr_t column = [self call: SCI_GETCOLUMN w: caret];
	const sptr_t selStart = [self call: SCI_GETSELECTIONSTART];
	const sptr_t selEnd = [self call: SCI_GETSELECTIONEND];
	NSString *caretText;
	if (selStart == selEnd) {
		caretText = [NSString stringWithFormat: @"Ln : %@    Col : %@    Pos : %@",
		             [self formatNumber: line + 1], [self formatNumber: column + 1], [self formatNumber: caret + 1]];
	} else {
		const sptr_t chars = [self call: SCI_COUNTCHARACTERS w: selStart l: selEnd];
		const sptr_t lines = [self call: SCI_LINEFROMPOSITION w: selEnd] - [self call: SCI_LINEFROMPOSITION w: selStart] + 1;
		caretText = [NSString stringWithFormat: @"Ln : %@    Col : %@    Sel : %@ | %@",
		             [self formatNumber: line + 1], [self formatNumber: column + 1], [self formatNumber: chars],
		             [self formatNumber: lines]];
	}
	[_status setText: caretText forSection: StatusBarSectionCaret];
	[_status setText: LineEndingDisplayName(doc.lineEnding) forSection: StatusBarSectionLineEnding];
	[_status setText: doc.encoding.DisplayName() forSection: StatusBarSectionEncoding];
	NSString *typing = [self call: SCI_GETOVERTYPE] ? @"OVR" : @"INS";
	if ([MacroRecorder shared].recording)
		typing = @"REC";
	[_status setText: typing forSection: StatusBarSectionTyping];
}

- (NSMenu *) statusBar: (StatusBar *) statusBar menuForSection: (StatusBarSection) section {
	AppDelegate *app = (AppDelegate *)NSApp.delegate;
	switch (section) {
		case StatusBarSectionLanguage:
			return [app.languageMenu copy];
		case StatusBarSectionLineEnding:
			return [app.lineEndingMenu copy];
		case StatusBarSectionEncoding:
			return [app.encodingMenu copy];
		case StatusBarSectionCaret:
			[self goToLine: nil];
			return nil;
		case StatusBarSectionTyping:
			[self call: SCI_EDITTOGGLEOVERTYPE];
			[self refreshStatus];
			return nil;
		default:
			return nil;
	}
}

#pragma mark - Scintilla notifications

- (void) notification: (SCNotification *) notification {
	switch (notification->nmhdr.code) {
		case SCN_SAVEPOINTLEFT:
			[self.document updateChangeCount: NSChangeDone];
			break;
		case SCN_SAVEPOINTREACHED:
			// Text restored from a session backup is unsaved even at Scintilla's save point.
			if (![self doc].hasRestoredUnsavedText)
				[self.document updateChangeCount: NSChangeCleared];
			break;
		case SCN_UPDATEUI:
			if (notification->updated & (SC_UPDATE_SELECTION | SC_UPDATE_CONTENT)) {
				[self highlightMatchingBrace];
				if (notification->updated & SC_UPDATE_SELECTION) {
					[self updateSmartHighlight];
					if (!_pendingClosers.empty() &&
					    [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]] != _pendingCloserLine)
						_pendingClosers.clear();
				}
				[self refreshStatus];
			}
			break;
		case SCN_MODIFIED: {
			if (notification->linesAdded != 0)
				UpdateLineNumberMargin(_editor, [AppSettings shared].showLineNumbers);
			Document *doc = [self doc];
			if (doc) {
				doc.changeSerial += 1;
				[[SessionManager shared] documentTextDidChange: doc];
				[[CloudDocuments shared] documentTextDidChange: doc];
			}
			break;
		}
		case SCN_CHARADDED:
			[self autoIndentAfterCharacter: notification->ch];
			[self autoCloseAfterCharacter: notification->ch];
			[self autoCompleteAfterCharacter: notification->ch];
			break;
		case SCN_AUTOCSELECTION:
			[self completionChosen: notification];
			break;
		case SCN_MARGINCLICK:
			if (notification->margin == kMarginBookmarks)
				[self toggleBookmarkAtLine: [self call: SCI_LINEFROMPOSITION w: notification->position]];
			break;
		case SCN_ZOOM:
			// One zoom level for every editor, remembered between launches.
			[AppSettings shared].zoom = [self call: SCI_GETZOOM];
			UpdateLineNumberMargin(_editor, [AppSettings shared].showLineNumbers);
			break;
		case SCN_MACRORECORD:
			[[MacroRecorder shared] recordMessage: static_cast<unsigned int>(notification->message)
			                               wParam: notification->wParam
			                               lParam: notification->lParam];
			break;
		case SCN_URIDROPPED:
			// A file dragged from Finder onto the text: open it instead of inserting its path.
			if (notification->text) {
				NSURL *url = [NSURL fileURLWithPath: ToNSString(notification->text)];
				dispatch_async(dispatch_get_main_queue(), ^{
					[[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL: url display: YES
					                                                            completionHandler: ^(NSDocument *document, BOOL wasOpen, NSError *error) {
						if (error)
							[NSApp presentError: error];
					}];
				});
			}
			break;
		default:
			break;
	}
}

- (int) charAt: (sptr_t) position {
	return static_cast<unsigned char>([self call: SCI_GETCHARAT w: position]);
}

- (void) highlightMatchingBrace {
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	sptr_t brace = -1;
	if (caret > 0 && IsBrace([self charAt: caret - 1]))
		brace = caret - 1;
	else if (IsBrace([self charAt: caret]))
		brace = caret;

	if (brace < 0) {
		[self call: SCI_BRACEHIGHLIGHT w: static_cast<uptr_t>(-1) l: -1];
		[self call: SCI_SETHIGHLIGHTGUIDE w: 0];
		return;
	}
	const sptr_t match = [self call: SCI_BRACEMATCH w: brace l: 0];
	if (match < 0) {
		[self call: SCI_BRACEBADLIGHT w: brace];
		[self call: SCI_SETHIGHLIGHTGUIDE w: 0];
	} else {
		[self call: SCI_BRACEHIGHLIGHT w: brace l: match];
		if ([AppSettings shared].showIndentGuides) {
			const sptr_t column = std::min([self call: SCI_GETCOLUMN w: brace], [self call: SCI_GETCOLUMN w: match]);
			[self call: SCI_SETHIGHLIGHTGUIDE w: column];
		}
	}
}

// Smart Highlighting: mark every occurrence of the selected word.
- (void) updateSmartHighlight {
	const sptr_t length = [self call: SCI_GETLENGTH];
	[self call: SCI_SETINDICATORCURRENT w: kIndicatorSmartHighlight];
	[self call: SCI_INDICATORCLEARRANGE w: 0 l: length];

	if (![AppSettings shared].smartHighlighting || [self call: SCI_GETSELECTIONS] != 1 || length > 8 * 1024 * 1024 ||
	    [self doc].largeFile)
		return;
	const sptr_t start = [self call: SCI_GETSELECTIONSTART];
	const sptr_t end = [self call: SCI_GETSELECTIONEND];
	if (start == end || end - start > 512)
		return;
	const std::string word = SciTextRange(_editor, start, end);
	for (char c : word) {
		if (!IsWordChar(static_cast<unsigned char>(c)))
			return;
	}
	if ((start > 0 && IsWordChar([self charAt: start - 1])) || (end < length && IsWordChar([self charAt: end])))
		return;

	[self call: SCI_SETSEARCHFLAGS w: SCFIND_WHOLEWORD];
	sptr_t position = 0;
	for (int count = 0; position < length && count < 20000; ++count) {
		[self call: SCI_SETTARGETRANGE w: position l: length];
		const sptr_t found = SciCallString(_editor, SCI_SEARCHINTARGET, word.size(), word);
		if (found < 0)
			break;
		const sptr_t foundEnd = [self call: SCI_GETTARGETEND];
		[self call: SCI_INDICATORFILLRANGE w: found l: foundEnd - found];
		position = foundEnd > found ? foundEnd : found + 1;
	}
}

- (void) autoIndentAfterCharacter: (int) character {
	if (![AppSettings shared].autoIndent || [self call: SCI_GETSELECTIONS] > 1)
		return;
	const int eolMode = static_cast<int>([self call: SCI_GETEOLMODE]);
	const bool newLine = eolMode == SC_EOL_CR ? character == '\r' : character == '\n';
	if (!newLine)
		return;
	const sptr_t line = [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]];
	if (line <= 0)
		return;
	const sptr_t indent = [self call: SCI_GETLINEINDENTATION w: line - 1];
	if (indent <= 0)
		return;
	[self call: SCI_SETLINEINDENTATION w: line l: indent];
	[self call: SCI_GOTOPOS w: [self call: SCI_GETLINEINDENTPOSITION w: line]];
}

#pragma mark - Auto-close and auto-completion

// Brackets and quotes close themselves in source code (not in plain text, where a lone
// parenthesis or apostrophe is ordinary writing).
- (void) autoCloseAfterCharacter: (int) character {
	AppSettings *settings = [AppSettings shared];
	Document *doc = [self doc];
	if ((!settings.autoCloseBrackets && !settings.autoCloseQuotes) || !doc || doc.language->name == "normal" ||
	    [self call: SCI_GETSELECTIONS] > 1 || [MacroRecorder shared].playing || [MacroRecorder shared].recording)
		return;
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	const sptr_t line = [self call: SCI_LINEFROMPOSITION w: caret];
	const int next = [self charAt: caret];

	// Typing a closer that is already there because it was inserted automatically: keep one.
	if (!_pendingClosers.empty() && line == _pendingCloserLine && character == _pendingClosers.back() && next == character) {
		[self call: SCI_DELETERANGE w: caret l: 1];
		_pendingClosers.pop_back();
		return;
	}

	char closer = 0;
	if (settings.autoCloseBrackets) {
		if (character == '(')
			closer = ')';
		else if (character == '[')
			closer = ']';
		else if (character == '{')
			closer = '}';
	}
	if (!closer && settings.autoCloseQuotes && (character == '"' || character == '\'' || character == '`')) {
		// Not inside a word (don't), and not when this quote ends a string that is already open.
		if (caret >= 2 && IsWordChar(static_cast<unsigned char>([self charAt: caret - 2])))
			return;
		const sptr_t lineStart = [self call: SCI_POSITIONFROMLINE w: line];
		const std::string before = SciTextRange(_editor, lineStart, caret - 1);
		int quotes = 0;
		for (size_t i = 0; i < before.size(); ++i) {
			if (before[i] == '\\')
				++i;
			else if (before[i] == character)
				++quotes;
		}
		if (quotes % 2)
			return;
		closer = static_cast<char>(character);
	}
	if (!closer)
		return;
	// Only where nothing follows that the new pair would wrap by accident.
	if (!(next == 0 || std::isspace(next) || next == ')' || next == ']' || next == '}' || next == ',' || next == ';'))
		return;

	const std::string text(1, closer);
	SciCallString(_editor, SCI_INSERTTEXT, caret, text);
	if (line != _pendingCloserLine)
		_pendingClosers.clear();
	_pendingCloserLine = line;
	_pendingClosers.push_back(closer);
}

// Shows the completion list for the word being typed: the keywords of the language and the
// other words of the document.
- (void) showCompletionsManually: (BOOL) manual {
	Document *doc = [self doc];
	if (!doc)
		return;
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	sptr_t start = caret;
	while (start > 0 && caret - start < 128 && IsCompletionWordByte(static_cast<unsigned char>([self charAt: start - 1])))
		--start;
	const std::string prefix = SciTextRange(_editor, start, caret);
	const size_t minimum = manual ? 1 : static_cast<size_t>([AppSettings shared].autoCompleteMinChars);
	if (prefix.size() < minimum || std::isdigit(static_cast<unsigned char>(prefix[0]))) {
		if (manual)
			NSBeep();
		return;
	}

	std::vector<std::string> words;
	FilterWordsWithPrefix(LanguageCompletionWords(*doc.language), prefix, words);
	const sptr_t length = [self call: SCI_GETLENGTH];
	if (length <= kWordScanLimit) {
		// Read the two halves around Scintilla's gap, so that scanning does not move it. The
		// gap is at the caret while typing, which also keeps the word being typed out of the list.
		const sptr_t gap = std::clamp<sptr_t>([self call: SCI_GETGAPPOSITION], 0, length);
		if (gap > 0)
			CollectWordsWithPrefix(reinterpret_cast<const char *>([self call: SCI_GETRANGEPOINTER w: 0 l: gap]),
			                       static_cast<size_t>(gap), prefix, words);
		if (gap < length)
			CollectWordsWithPrefix(reinterpret_cast<const char *>([self call: SCI_GETRANGEPOINTER w: gap l: length - gap]),
			                       static_cast<size_t>(length - gap), prefix, words);
	}

	const std::string list = JoinCompletionWords(words, 500);
	if (list.empty() || list == prefix) {
		if ([self call: SCI_AUTOCACTIVE])
			[self call: SCI_AUTOCCANCEL];
		if (manual)
			NSBeep();
		return;
	}
	SciCallString(_editor, SCI_AUTOCSHOW, prefix.size(), list);
}

- (void) autoCompleteAfterCharacter: (int) character {
	Document *doc = [self doc];
	if (![AppSettings shared].autoComplete || !doc || doc.largeFile || doc.language->name == "normal" ||
	    [self call: SCI_GETSELECTIONS] > 1 || [MacroRecorder shared].playing)
		return;
	if (character < 0x80 && !IsCompletionWordByte(static_cast<unsigned char>(character)))
		return;
	[self showCompletionsManually: NO];
}

// Return on a word that is already typed in full starts a new line instead of "completing" it.
- (void) completionChosen: (SCNotification *) notification {
	if (notification->listCompletionMethod != SC_AC_NEWLINE || !notification->text)
		return;
	const std::string typed = SciTextRange(_editor, notification->position, [self call: SCI_GETCURRENTPOS]);
	if (typed == notification->text) {
		[self call: SCI_AUTOCCANCEL];
		[self call: SCI_NEWLINE];
	}
}

- (IBAction) completeWord: (id) sender {
	[self showCompletionsManually: YES];
}

#pragma mark - Helpers for line based commands

// Lines covered by the selection. A selection ending at the start of a line does not include that line.
- (void) selectedLinesFirst: (sptr_t *) first last: (sptr_t *) last wholeDocumentIfEmpty: (BOOL) whole {
	const sptr_t start = [self call: SCI_GETSELECTIONSTART];
	const sptr_t end = [self call: SCI_GETSELECTIONEND];
	if (start == end && whole) {
		*first = 0;
		*last = [self call: SCI_GETLINECOUNT] - 1;
		// Keep the empty line after the final line ending out of the operation.
		if (*last > 0 && [self call: SCI_POSITIONFROMLINE w: *last] == [self call: SCI_GETLENGTH])
			--*last;
		return;
	}
	*first = [self call: SCI_LINEFROMPOSITION w: start];
	*last = [self call: SCI_LINEFROMPOSITION w: end];
	if (end > start && *last > *first && end == [self call: SCI_POSITIONFROMLINE w: *last])
		--*last;
}

- (void) transformLines: (void (^)(std::vector<std::string> &lines)) transform {
	sptr_t first = 0, last = 0;
	[self selectedLinesFirst: &first last: &last wholeDocumentIfEmpty: YES];
	const BOOL hadSelection = [self call: SCI_GETSELECTIONSTART] != [self call: SCI_GETSELECTIONEND];
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	const sptr_t start = [self call: SCI_POSITIONFROMLINE w: first];
	const sptr_t end = [self call: SCI_GETLINEENDPOSITION w: last];

	const std::string original = SciTextRange(_editor, start, end);
	std::vector<std::string> lines = SplitLines(original);
	transform(lines);
	const std::string result = JoinLines(lines, EolString(static_cast<int>([self call: SCI_GETEOLMODE])));
	if (result == original)
		return;

	[self call: SCI_SETTARGETRANGE w: start l: end];
	[self call: SCI_REPLACETARGET w: result.size() l: reinterpret_cast<sptr_t>(result.data())];
	if (hadSelection)
		[self call: SCI_SETSEL w: start l: start + static_cast<sptr_t>(result.size())];
	else
		[self call: SCI_GOTOPOS w: std::min(caret, [self call: SCI_GETLENGTH])];
}

#pragma mark - Edit menu

- (IBAction) duplicateLine: (id) sender {
	[self call: [self call: SCI_GETSELECTIONEMPTY] ? SCI_LINEDUPLICATE : SCI_SELECTIONDUPLICATE];
}

- (IBAction) deleteLine: (id) sender {
	[self call: SCI_LINEDELETE];
}

- (IBAction) moveLineUp: (id) sender {
	[self call: SCI_MOVESELECTEDLINESUP];
}

- (IBAction) moveLineDown: (id) sender {
	[self call: SCI_MOVESELECTEDLINESDOWN];
}

- (IBAction) joinLines: (id) sender {
	sptr_t start = [self call: SCI_GETSELECTIONSTART];
	sptr_t end = [self call: SCI_GETSELECTIONEND];
	if (start == end) {
		const sptr_t line = [self call: SCI_LINEFROMPOSITION w: start];
		if (line + 1 >= [self call: SCI_GETLINECOUNT])
			return;
		start = [self call: SCI_POSITIONFROMLINE w: line];
		end = [self call: SCI_GETLINEENDPOSITION w: line + 1];
	}
	[self call: SCI_SETTARGETRANGE w: start l: end];
	[self call: SCI_LINESJOIN];
}

- (void) applyLineOperation: (LineOperation) operation {
	const int tabWidth = static_cast<int>([self call: SCI_GETTABWIDTH]);
	[self transformLines: ^(std::vector<std::string> &lines) {
		ApplyLineOperation(lines, operation, tabWidth);
	}];
}

- (IBAction) sortLinesAscending: (id) sender { [self applyLineOperation: LineOperation::SortAscending]; }
- (IBAction) sortLinesDescending: (id) sender { [self applyLineOperation: LineOperation::SortDescending]; }
- (IBAction) sortLinesIgnoringCase: (id) sender { [self applyLineOperation: LineOperation::SortIgnoringCase]; }
- (IBAction) sortLinesNumerically: (id) sender { [self applyLineOperation: LineOperation::SortNumerically]; }
- (IBAction) reverseLines: (id) sender { [self applyLineOperation: LineOperation::Reverse]; }
- (IBAction) removeDuplicateLines: (id) sender { [self applyLineOperation: LineOperation::RemoveDuplicates]; }
- (IBAction) removeEmptyLines: (id) sender { [self applyLineOperation: LineOperation::RemoveEmpty]; }
- (IBAction) trimTrailingSpace: (id) sender { [self applyLineOperation: LineOperation::TrimTrailing]; }
- (IBAction) tabsToSpaces: (id) sender { [self applyLineOperation: LineOperation::TabsToSpaces]; }
- (IBAction) leadingSpacesToTabs: (id) sender { [self applyLineOperation: LineOperation::LeadingSpacesToTabs]; }
- (IBAction) trimLeadingSpace: (id) sender { [self applyLineOperation: LineOperation::TrimLeading]; }
- (IBAction) trimLeadingAndTrailingSpace: (id) sender { [self applyLineOperation: LineOperation::TrimBoth]; }

- (void) trimTrailingWhitespaceInDocument {
	[self call: SCI_BEGINUNDOACTION];
	for (sptr_t line = [self call: SCI_GETLINECOUNT] - 1; line >= 0; --line) {
		const sptr_t lineStart = [self call: SCI_POSITIONFROMLINE w: line];
		const sptr_t lineEnd = [self call: SCI_GETLINEENDPOSITION w: line];
		sptr_t keep = lineEnd;
		while (keep > lineStart) {
			const int c = [self charAt: keep - 1];
			if (c != ' ' && c != '\t')
				break;
			--keep;
		}
		if (keep < lineEnd)
			[self call: SCI_DELETERANGE w: keep l: lineEnd - keep];
	}
	[self call: SCI_ENDUNDOACTION];
}

- (void) insertBlankLineAtEndOfLine: (sptr_t) line {
	const std::string eol = EolString(static_cast<int>([self call: SCI_GETEOLMODE]));
	if (line < 0) {
		SciCallString(_editor, SCI_INSERTTEXT, 0, eol);
		[self call: SCI_GOTOPOS w: 0];
		return;
	}
	const sptr_t position = [self call: SCI_GETLINEENDPOSITION w: line];
	SciCallString(_editor, SCI_INSERTTEXT, position, eol);
	[self call: SCI_GOTOPOS w: position + static_cast<sptr_t>(eol.size())];
}

- (IBAction) insertBlankLineAbove: (id) sender {
	[self insertBlankLineAtEndOfLine: [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]] - 1];
}

- (IBAction) insertBlankLineBelow: (id) sender {
	[self insertBlankLineAtEndOfLine: [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]]];
}

- (IBAction) toUpperCase: (id) sender {
	[self call: SCI_UPPERCASE];
}

// Replaces the selection (or, without one, the whole document) with `transform` of it.
// `transform` returns NO, after explaining why in `error`, when it cannot convert the text.
- (void) transformSelectionOrDocument: (BOOL (^)(const std::string &text, std::string &result, NSString **error)) transform
                                title: (NSString *) title {
	sptr_t start = [self call: SCI_GETSELECTIONSTART];
	sptr_t end = [self call: SCI_GETSELECTIONEND];
	const BOOL hadSelection = start != end;
	if (!hadSelection) {
		start = 0;
		end = [self call: SCI_GETLENGTH];
	}
	const std::string text = SciTextRange(_editor, start, end);
	std::string result;
	NSString *error = nil;
	if (!transform(text, result, &error)) {
		NSAlert *alert = [[NSAlert alloc] init];
		alert.messageText = title;
		alert.informativeText = error ?: @"The text could not be converted.";
		[alert beginSheetModalForWindow: self.window completionHandler: nil];
		return;
	}
	if (result == text)
		return;
	[self call: SCI_SETTARGETRANGE w: start l: end];
	[self call: SCI_REPLACETARGET w: result.size() l: reinterpret_cast<sptr_t>(result.data())];
	if (hadSelection)
		[self call: SCI_SETSEL w: start l: start + static_cast<sptr_t>(result.size())];
}

- (void) convertSelectionCase: (CaseStyle) style {
	if ([self call: SCI_GETSELECTIONEMPTY])
		return;
	[self transformSelectionOrDocument: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		result = ConvertCase(text, style);
		return YES;
	} title: @"Convert Case"];
}

- (IBAction) toProperCase: (id) sender { [self convertSelectionCase: CaseStyle::Proper]; }
- (IBAction) toSentenceCase: (id) sender { [self convertSelectionCase: CaseStyle::Sentence]; }
- (IBAction) invertCase: (id) sender { [self convertSelectionCase: CaseStyle::Invert]; }

- (IBAction) toLowerCase: (id) sender {
	[self call: SCI_LOWERCASE];
}

- (IBAction) toggleLineComment: (id) sender {
	const Language *language = [self doc].language;
	const std::string token = language->commentLine;
	if (token.empty()) {
		if (!language->commentStart.empty())
			[self toggleBlockComment: sender];
		else
			NSBeep();
		return;
	}

	sptr_t first = 0, last = 0;
	[self selectedLinesFirst: &first last: &last wholeDocumentIfEmpty: NO];
	const BOOL hadSelection = [self call: SCI_GETSELECTIONSTART] != [self call: SCI_GETSELECTIONEND];
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	const sptr_t caretFromLineEnd = [self call: SCI_GETLINEENDPOSITION w: [self call: SCI_LINEFROMPOSITION w: caret]] - caret;

	// Uncomment only when every non blank line is already commented.
	bool allCommented = true;
	bool anyLine = false;
	for (sptr_t line = first; line <= last; ++line) {
		const sptr_t indent = [self call: SCI_GETLINEINDENTPOSITION w: line];
		const sptr_t lineEnd = [self call: SCI_GETLINEENDPOSITION w: line];
		if (indent == lineEnd)
			continue;
		anyLine = true;
		if (SciTextRange(_editor, indent, std::min(lineEnd, indent + static_cast<sptr_t>(token.size()))) != token)
			allCommented = false;
	}
	if (!anyLine)
		allCommented = false;

	[self call: SCI_BEGINUNDOACTION];
	for (sptr_t line = last; line >= first; --line) {
		const sptr_t indent = [self call: SCI_GETLINEINDENTPOSITION w: line];
		const sptr_t lineEnd = [self call: SCI_GETLINEENDPOSITION w: line];
		if (indent == lineEnd && anyLine)
			continue;
		if (allCommented) {
			sptr_t removeEnd = indent + static_cast<sptr_t>(token.size());
			if (removeEnd < lineEnd && [self charAt: removeEnd] == ' ')
				++removeEnd;
			[self call: SCI_DELETERANGE w: indent l: removeEnd - indent];
		} else {
			SciCallString(_editor, SCI_INSERTTEXT, indent, token + " ");
		}
	}
	[self call: SCI_ENDUNDOACTION];

	if (hadSelection) {
		[self call: SCI_SETSEL w: [self call: SCI_POSITIONFROMLINE w: first] l: [self call: SCI_GETLINEENDPOSITION w: last]];
	} else {
		const sptr_t lineEnd = [self call: SCI_GETLINEENDPOSITION w: first];
		[self call: SCI_GOTOPOS w: std::max([self call: SCI_POSITIONFROMLINE w: first], lineEnd - caretFromLineEnd)];
	}
}

- (IBAction) toggleBlockComment: (id) sender {
	const Language *language = [self doc].language;
	const std::string open = language->commentStart;
	const std::string close = language->commentEnd;
	if (open.empty() || close.empty()) {
		if (!language->commentLine.empty())
			[self toggleLineComment: sender];
		else
			NSBeep();
		return;
	}

	sptr_t start = [self call: SCI_GETSELECTIONSTART];
	sptr_t end = [self call: SCI_GETSELECTIONEND];
	if (start == end) {
		const sptr_t line = [self call: SCI_LINEFROMPOSITION w: start];
		start = [self call: SCI_GETLINEINDENTPOSITION w: line];
		end = [self call: SCI_GETLINEENDPOSITION w: line];
	}
	std::string text = SciTextRange(_editor, start, end);
	std::string replacement;
	if (text.size() >= open.size() + close.size() && text.compare(0, open.size(), open) == 0 &&
	    text.compare(text.size() - close.size(), close.size(), close) == 0) {
		replacement = text.substr(open.size(), text.size() - open.size() - close.size());
		if (!replacement.empty() && replacement.front() == ' ')
			replacement.erase(0, 1);
		if (!replacement.empty() && replacement.back() == ' ')
			replacement.pop_back();
	} else {
		replacement = open + " " + text + " " + close;
	}
	[self call: SCI_SETTARGETRANGE w: start l: end];
	[self call: SCI_REPLACETARGET w: replacement.size() l: reinterpret_cast<sptr_t>(replacement.data())];
	[self call: SCI_SETSEL w: start l: start + static_cast<sptr_t>(replacement.size())];
}

- (IBAction) setLineEnding: (id) sender {
	const LineEnding eol = static_cast<LineEnding>([sender tag]);
	const int mode = LineEndingToSciMode(eol);
	[self call: SCI_CONVERTEOLS w: mode];
	[self call: SCI_SETEOLMODE w: mode];
	[self doc].lineEnding = eol;
	[self refreshStatus];
}

- (IBAction) copyFilePath: (id) sender {
	NSURL *url = [self doc].fileURL;
	if (!url)
		return;
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString: url.path forType: NSPasteboardTypeString];
}

- (IBAction) copyFileName: (id) sender {
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString: [self doc].displayName forType: NSPasteboardTypeString];
}

- (IBAction) copyDirectoryPath: (id) sender {
	NSURL *url = [self doc].fileURL;
	if (!url)
		return;
	NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
	[pasteboard clearContents];
	[pasteboard setString: url.path.stringByDeletingLastPathComponent forType: NSPasteboardTypeString];
}

- (IBAction) openFolderInTerminal: (id) sender {
	NSURL *folder = [self doc].fileURL.URLByDeletingLastPathComponent;
	NSURL *terminal = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier: @"com.apple.Terminal"];
	if (!folder || !terminal)
		return;
	[[NSWorkspace sharedWorkspace] openURLs: @[folder] withApplicationAtURL: terminal
	                          configuration: [NSWorkspaceOpenConfiguration configuration] completionHandler: nil];
}

- (void) insertDateWithFormatter: (NSDateFormatter *) formatter {
	SciCallString(_editor, SCI_REPLACESEL, 0, ToStdString([formatter stringFromDate: [NSDate date]]));
}

- (IBAction) insertDateTimeShort: (id) sender {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateStyle = NSDateFormatterShortStyle;
	formatter.timeStyle = NSDateFormatterShortStyle;
	[self insertDateWithFormatter: formatter];
}

- (IBAction) insertDateTimeLong: (id) sender {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.dateStyle = NSDateFormatterFullStyle;
	formatter.timeStyle = NSDateFormatterShortStyle;
	[self insertDateWithFormatter: formatter];
}

- (IBAction) insertDateTimeISO: (id) sender {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
	[self insertDateWithFormatter: formatter];
}

#pragma mark - Multiple selections

// Adds the next occurrence of the selected text as another selection (the word under the
// caret is selected first), so that all of them can be edited at once.
- (IBAction) selectNextOccurrence: (id) sender {
	[self call: SCI_SETSEARCHFLAGS w: SCFIND_MATCHCASE];
	[self call: SCI_TARGETWHOLEDOCUMENT];
	[self call: SCI_MULTIPLESELECTADDNEXT];
	[self call: SCI_SCROLLCARET];
}

- (IBAction) selectAllOccurrences: (id) sender {
	[self call: SCI_SETSEARCHFLAGS w: SCFIND_MATCHCASE];
	[self call: SCI_TARGETWHOLEDOCUMENT];
	[self call: SCI_MULTIPLESELECTADDEACH];
}

#pragma mark - Tools menu

- (void) showHash: (HashAlgorithm) algorithm name: (NSString *) name {
	sptr_t start = [self call: SCI_GETSELECTIONSTART];
	sptr_t end = [self call: SCI_GETSELECTIONEND];
	const BOOL hasSelection = start != end;
	const std::string text = hasSelection ? SciTextRange(_editor, start, end) : [self documentText];
	NSString *digest = ToNSString(HashHex(text, algorithm));

	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat: @"%@ of %@", name, hasSelection ? @"the selection" : @"the document text"];
	NSTextField *field = [NSTextField wrappingLabelWithString: digest];
	field.selectable = YES;
	field.font = [NSFont monospacedSystemFontOfSize: 11 weight: NSFontWeightRegular];
	field.frame = NSMakeRect(0, 0, 420, digest.length > 64 ? 48 : 32);
	alert.accessoryView = field;
	[alert addButtonWithTitle: @"Copy"];
	[alert addButtonWithTitle: @"Close"];
	[alert beginSheetModalForWindow: self.window completionHandler: ^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn)
			return;
		NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
		[pasteboard clearContents];
		[pasteboard setString: digest forType: NSPasteboardTypeString];
	}];
}

- (IBAction) hashMD5: (id) sender { [self showHash: HashAlgorithm::MD5 name: @"MD5"]; }
- (IBAction) hashSHA1: (id) sender { [self showHash: HashAlgorithm::SHA1 name: @"SHA-1"]; }
- (IBAction) hashSHA256: (id) sender { [self showHash: HashAlgorithm::SHA256 name: @"SHA-256"]; }
- (IBAction) hashSHA512: (id) sender { [self showHash: HashAlgorithm::SHA512 name: @"SHA-512"]; }

- (IBAction) base64Encode: (id) sender {
	[self transformSelectionOrDocument: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		result = Base64Encode(text);
		return YES;
	} title: @"Base64 Encode"];
}

- (IBAction) base64Decode: (id) sender {
	[self transformSelectionOrDocument: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		if (Base64Decode(text, result))
			return YES;
		*error = @"The text is not valid Base64.";
		return NO;
	} title: @"Base64 Decode"];
}

- (IBAction) urlEncode: (id) sender {
	[self transformSelectionOrDocument: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		result = URLEncode(text);
		return YES;
	} title: @"URL Encode"];
}

- (IBAction) urlDecode: (id) sender {
	[self transformSelectionOrDocument: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		if (URLDecode(text, result))
			return YES;
		*error = @"The text contains a “%” that is not followed by two hexadecimal digits.";
		return NO;
	} title: @"URL Decode"];
}

- (void) reformatJSONMinified: (BOOL) minify {
	const std::string indent = [self call: SCI_GETUSETABS] ? std::string("\t")
	                                                       : std::string(static_cast<size_t>([self call: SCI_GETTABWIDTH]), ' ');
	const std::string eol = EolString(static_cast<int>([self call: SCI_GETEOLMODE]));
	[self transformSelectionOrDocument: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		std::string message;
		if (FormatJSON(text, minify, indent, eol, result, message))
			return YES;
		*error = ToNSString(message);
		return NO;
	} title: minify ? @"Minify JSON" : @"Format JSON"];
}

- (IBAction) formatJSON: (id) sender { [self reformatJSONMinified: NO]; }
- (IBAction) minifyJSON: (id) sender { [self reformatJSONMinified: YES]; }

#pragma mark - Macro menu

- (IBAction) toggleMacroRecording: (id) sender {
	MacroRecorder *macro = [MacroRecorder shared];
	if (macro.recording)
		[macro stopRecording];
	else
		[macro startRecordingInEditor: _editor];
	[self refreshStatus];
}

- (IBAction) playMacro: (id) sender {
	[[MacroRecorder shared] playInController: self times: 1];
}

- (IBAction) runMacroMultipleTimes: (id) sender {
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Run Macro Multiple Times";
	alert.informativeText = @"How many times should the recorded macro run?";
	NSTextField *field = [[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 220, 24)];
	field.stringValue = @"10";
	alert.accessoryView = field;
	[alert addButtonWithTitle: @"Run"];
	[alert addButtonWithTitle: @"Run Until End of File"];
	[alert addButtonWithTitle: @"Cancel"];
	[alert layout];
	alert.window.initialFirstResponder = field;
	[alert beginSheetModalForWindow: self.window completionHandler: ^(NSModalResponse response) {
		if (response == NSAlertFirstButtonReturn)
			[[MacroRecorder shared] playInController: self times: std::clamp<NSInteger>(field.integerValue, 1, 1000000)];
		else if (response == NSAlertSecondButtonReturn)
			[[MacroRecorder shared] playInController: self times: 0];
	}];
}

#pragma mark - Encoding menu

- (IBAction) convertEncoding: (id) sender {
	Document *doc = [self doc];
	const FileEncoding encoding = EncodingForTag([sender tag]);
	if (doc.encoding == encoding)
		return;
	doc.encoding = encoding;
	[doc updateChangeCount: NSChangeDone];
	[self refreshStatus];
}

- (IBAction) reopenWithEncoding: (id) sender {
	const CFStringEncoding cfEncoding = static_cast<CFStringEncoding>([sender tag]);
	FileEncoding encoding;
	if (cfEncoding == kCFStringEncodingUTF8)
		encoding = FileEncoding::Make(FileEncoding::UTF8);
	else if (cfEncoding == kCFStringEncodingUTF16LE)
		encoding = FileEncoding::Make(FileEncoding::UTF16LE_BOM);
	else if (cfEncoding == kCFStringEncodingUTF16BE)
		encoding = FileEncoding::Make(FileEncoding::UTF16BE_BOM);
	else
		encoding = FileEncoding::MakeLegacy(cfEncoding);
	[[self doc] reopenWithEncoding: encoding];
}

#pragma mark - Language menu

- (IBAction) setLanguage: (id) sender {
	NSString *name = [sender representedObject];
	const Language *language = LanguageCatalog::Shared().Find(ToStdString(name));
	if (!language)
		return;
	Document *doc = [self doc];
	doc.language = language;
	doc.languageChosenByUser = YES;
	[self applyLanguage];
}

#pragma mark - Search menu

- (NSString *) textForFind {
	sptr_t start = [self call: SCI_GETSELECTIONSTART];
	sptr_t end = [self call: SCI_GETSELECTIONEND];
	if (start == end) {
		start = [self call: SCI_WORDSTARTPOSITION w: start l: 1];
		end = [self call: SCI_WORDENDPOSITION w: end l: 1];
	}
	if (start == end || end - start > 2048)
		return nil;
	const std::string text = SciTextRange(_editor, start, end);
	if (text.find_first_of("\r\n") != std::string::npos)
		return nil;
	return ToNSString(text);
}

- (IBAction) showFindPanel: (id) sender {
	[[FindPanel shared] showWithFindString: [self textForFind] focusReplace: NO];
}

- (IBAction) showReplacePanel: (id) sender {
	[[FindPanel shared] showWithFindString: [self textForFind] focusReplace: YES];
}

- (IBAction) findNext: (id) sender {
	[[FindPanel shared] findInEditor: _editor backward: NO];
}

- (IBAction) findPrevious: (id) sender {
	[[FindPanel shared] findInEditor: _editor backward: YES];
}

- (IBAction) useSelectionForFind: (id) sender {
	NSString *text = [self textForFind];
	if (text)
		[FindPanel shared].findString = text;
}

- (IBAction) findInFiles: (id) sender {
	[[FindPanel shared] showForFindInFilesWithFindString: [self textForFind] directory: [self doc].fileURL.URLByDeletingLastPathComponent];
}

- (IBAction) showSearchResults: (id) sender {
	[[SearchResultsPanel shared] showWindow: sender];
}

- (void) selectRangeFrom: (sptr_t) start to: (sptr_t) end {
	const sptr_t length = [self call: SCI_GETLENGTH];
	start = std::clamp<sptr_t>(start, 0, length);
	end = std::clamp<sptr_t>(end, start, length);
	[self call: SCI_ENSUREVISIBLEENFORCEPOLICY w: [self call: SCI_LINEFROMPOSITION w: start]];
	[self call: SCI_SETSEL w: start l: end];
	[self call: SCI_SCROLLRANGE w: end l: start];
	[self.window makeFirstResponder: _editor.content];
}

- (IBAction) clearMarks: (id) sender {
	[self call: SCI_SETINDICATORCURRENT w: kIndicatorMarkAll];
	[self call: SCI_INDICATORCLEARRANGE w: 0 l: [self call: SCI_GETLENGTH]];
}

- (IBAction) goToLine: (id) sender {
	const sptr_t lineCount = [self call: SCI_GETLINECOUNT];
	const sptr_t current = [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]] + 1;

	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = @"Go to Line";
	alert.informativeText = [NSString stringWithFormat: @"You are here: %ld. Go to line (1 - %ld), or line:column:", (long)current, (long)lineCount];
	NSTextField *field = [[NSTextField alloc] initWithFrame: NSMakeRect(0, 0, 220, 24)];
	field.stringValue = [NSString stringWithFormat: @"%ld", (long)current];
	alert.accessoryView = field;
	[alert addButtonWithTitle: @"Go"];
	[alert addButtonWithTitle: @"Cancel"];
	[alert layout];
	alert.window.initialFirstResponder = field;

	ScintillaView *editor = _editor;
	NSWindow *window = self.window;
	[alert beginSheetModalForWindow: window completionHandler: ^(NSModalResponse response) {
		if (response != NSAlertFirstButtonReturn)
			return;
		NSArray<NSString *> *parts = [field.stringValue componentsSeparatedByCharactersInSet:
		                              [NSCharacterSet characterSetWithCharactersInString: @":,"]];
		const sptr_t line = std::clamp<sptr_t>(parts.firstObject.integerValue, 1, lineCount) - 1;
		SciCall(editor, SCI_ENSUREVISIBLEENFORCEPOLICY, line);
		SciCall(editor, SCI_GOTOLINE, line);
		if (parts.count > 1 && parts[1].integerValue > 1) {
			const sptr_t position = SciCall(editor, SCI_FINDCOLUMN, line, parts[1].integerValue - 1);
			SciCall(editor, SCI_GOTOPOS, position);
		}
		SciCall(editor, SCI_VERTICALCENTRECARET);
		[window makeFirstResponder: editor.content];
	}];
}

- (IBAction) goToMatchingBrace: (id) sender {
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	sptr_t brace = -1;
	if (caret > 0 && IsBrace([self charAt: caret - 1]))
		brace = caret - 1;
	else if (IsBrace([self charAt: caret]))
		brace = caret;
	const sptr_t match = brace >= 0 ? [self call: SCI_BRACEMATCH w: brace l: 0] : -1;
	if (match < 0) {
		NSBeep();
		return;
	}
	[self call: SCI_GOTOPOS w: match];
}

// Selects everything between a brace and its partner, braces included.
- (IBAction) selectToMatchingBrace: (id) sender {
	const sptr_t caret = [self call: SCI_GETCURRENTPOS];
	sptr_t brace = -1;
	if (caret > 0 && IsBrace([self charAt: caret - 1]))
		brace = caret - 1;
	else if (IsBrace([self charAt: caret]))
		brace = caret;
	const sptr_t match = brace >= 0 ? [self call: SCI_BRACEMATCH w: brace l: 0] : -1;
	if (match < 0) {
		NSBeep();
		return;
	}
	[self call: SCI_SETSEL w: std::min(brace, match) l: std::max(brace, match) + 1];
}

- (void) toggleBookmarkAtLine: (sptr_t) line {
	if ([self call: SCI_MARKERGET w: line] & (1 << kMarkerBookmark))
		[self call: SCI_MARKERDELETE w: line l: kMarkerBookmark];
	else
		[self call: SCI_MARKERADD w: line l: kMarkerBookmark];
}

- (IBAction) toggleBookmark: (id) sender {
	[self toggleBookmarkAtLine: [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]]];
}

- (void) goToBookmarkForward: (BOOL) forward {
	const sptr_t current = [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]];
	const sptr_t mask = 1 << kMarkerBookmark;
	sptr_t line = forward ? [self call: SCI_MARKERNEXT w: current + 1 l: mask]
	                      : [self call: SCI_MARKERPREVIOUS w: current - 1 l: mask];
	if (line < 0) // wrap around
		line = forward ? [self call: SCI_MARKERNEXT w: 0 l: mask]
		               : [self call: SCI_MARKERPREVIOUS w: [self call: SCI_GETLINECOUNT] l: mask];
	if (line < 0) {
		NSBeep();
		return;
	}
	[self call: SCI_ENSUREVISIBLEENFORCEPOLICY w: line];
	[self call: SCI_GOTOLINE w: line];
}

- (IBAction) nextBookmark: (id) sender {
	[self goToBookmarkForward: YES];
}

- (IBAction) previousBookmark: (id) sender {
	[self goToBookmarkForward: NO];
}

- (IBAction) clearBookmarks: (id) sender {
	[self call: SCI_MARKERDELETEALL w: kMarkerBookmark];
}

#pragma mark - View menu

- (IBAction) zoomInText: (id) sender {
	[self call: SCI_ZOOMIN];
}

- (IBAction) zoomOutText: (id) sender {
	[self call: SCI_ZOOMOUT];
}

- (IBAction) resetTextZoom: (id) sender {
	[self call: SCI_SETZOOM w: 0];
}

- (IBAction) foldAll: (id) sender {
	[self call: SCI_FOLDALL w: SC_FOLDACTION_CONTRACT];
}

- (IBAction) unfoldAll: (id) sender {
	[self call: SCI_FOLDALL w: SC_FOLDACTION_EXPAND];
}

- (void) foldCurrent: (int) action {
	const sptr_t line = [self call: SCI_LINEFROMPOSITION w: [self call: SCI_GETCURRENTPOS]];
	const bool isHeader = ([self call: SCI_GETFOLDLEVEL w: line] & SC_FOLDLEVELHEADERFLAG) != 0;
	const sptr_t header = isHeader ? line : [self call: SCI_GETFOLDPARENT w: line];
	if (header < 0) {
		NSBeep();
		return;
	}
	[self call: SCI_FOLDLINE w: header l: action];
	if (action == SC_FOLDACTION_CONTRACT)
		[self call: SCI_GOTOLINE w: header];
}

- (IBAction) foldCurrentLevel: (id) sender {
	[self foldCurrent: SC_FOLDACTION_CONTRACT];
}

- (IBAction) unfoldCurrentLevel: (id) sender {
	[self foldCurrent: SC_FOLDACTION_EXPAND];
}

// "+" button of the window tab bar.
- (IBAction) newWindowForTab: (id) sender {
	[[NSDocumentController sharedDocumentController] newDocument: sender];
}

#pragma mark - Printing

// A text view holding the document, coloured like the editor when the theme is a light one
// (a dark theme would waste ink, so it prints as plain black text).
- (NSView *) printableViewForPrintInfo: (NSPrintInfo *) printInfo {
	const sptr_t length = [self call: SCI_GETLENGTH];
	const std::string text = [self documentText];
	NSString *string = [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSUTF8StringEncoding];
	const BOOL validUTF8 = string != nil;
	if (!string)
		string = [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSISOLatin1StringEncoding] ?: @"";

	char fontName[256] = "";
	[self call: SCI_STYLEGETFONT w: STYLE_DEFAULT l: reinterpret_cast<sptr_t>(fontName)];
	const CGFloat fontSize = 10;
	NSFont *font = [NSFont fontWithName: ToNSString(fontName) size: fontSize] ?: [NSFont userFixedPitchFontOfSize: fontSize];
	NSFontManager *fonts = [NSFontManager sharedFontManager];

	NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
	const CGFloat charWidth = [@"0" sizeWithAttributes: @{NSFontAttributeName: font}].width;
	paragraph.tabStops = @[];
	paragraph.defaultTabInterval = charWidth * [self call: SCI_GETTABWIDTH];
	paragraph.lineBreakMode = NSLineBreakByCharWrapping;

	NSDictionary *plain = @{NSFontAttributeName: font, NSForegroundColorAttributeName: [NSColor blackColor],
	                        NSParagraphStyleAttributeName: paragraph};
	NSMutableAttributedString *attributed = [[NSMutableAttributedString alloc] initWithString: string attributes: plain];

	const BOOL coloured = validUTF8 && length > 0 && length <= kColourPrintLimit && ![AppSettings shared].currentTheme->IsDark();
	if (coloured) {
		[self call: SCI_COLOURISE w: 0 l: -1];
		std::vector<char> styled(static_cast<size_t>(length) * 2 + 2);
		Sci_TextRangeFull range;
		range.chrg.cpMin = 0;
		range.chrg.cpMax = length;
		range.lpstrText = styled.data();
		[self call: SCI_GETSTYLEDTEXTFULL w: 0 l: reinterpret_cast<sptr_t>(&range)];

		NSMutableDictionary<NSNumber *, NSDictionary *> *attributesByStyle = [NSMutableDictionary dictionary];
		NSUInteger runStart = 0; // in UTF-16 units
		NSUInteger unit = 0;
		int runStyle = static_cast<unsigned char>(styled[1]);
		[attributed beginEditing];
		auto flush = [&](NSUInteger runEnd) {
			if (runEnd <= runStart || runStyle == STYLE_DEFAULT)
				return;
			NSDictionary *attributes = attributesByStyle[@(runStyle)];
			if (!attributes) {
				const sptr_t fore = [self call: SCI_STYLEGETFORE w: runStyle];
				NSColor *colour = [NSColor colorWithSRGBRed: (fore & 0xFF) / 255.0 green: ((fore >> 8) & 0xFF) / 255.0
				                                       blue: ((fore >> 16) & 0xFF) / 255.0 alpha: 1];
				NSFont *styleFont = font;
				if ([self call: SCI_STYLEGETBOLD w: runStyle])
					styleFont = [fonts convertFont: styleFont toHaveTrait: NSBoldFontMask];
				if ([self call: SCI_STYLEGETITALIC w: runStyle])
					styleFont = [fonts convertFont: styleFont toHaveTrait: NSItalicFontMask];
				attributes = @{NSForegroundColorAttributeName: colour, NSFontAttributeName: styleFont};
				attributesByStyle[@(runStyle)] = attributes;
			}
			[attributed addAttributes: attributes range: NSMakeRange(runStart, runEnd - runStart)];
		};
		for (sptr_t i = 0; i < length; ++i) {
			const unsigned char byte = static_cast<unsigned char>(styled[static_cast<size_t>(i) * 2]);
			const int style = static_cast<unsigned char>(styled[static_cast<size_t>(i) * 2 + 1]);
			const bool startsCharacter = (byte & 0xC0) != 0x80;
			if (startsCharacter && style != runStyle) {
				flush(unit);
				runStart = unit;
				runStyle = style;
			}
			if (startsCharacter)
				unit += byte >= 0xF0 ? 2 : 1; // characters outside the BMP take two UTF-16 units
		}
		flush(std::min<NSUInteger>(unit, attributed.length));
		[attributed endEditing];
	}

	const NSSize paper = printInfo.paperSize;
	const CGFloat width = std::max<CGFloat>(paper.width - printInfo.leftMargin - printInfo.rightMargin, 200);
	NSTextView *view = [[NSTextView alloc] initWithFrame: NSMakeRect(0, 0, width, 100)];
	view.drawsBackground = NO;
	view.textContainerInset = NSZeroSize;
	view.textContainer.lineFragmentPadding = 0;
	view.verticallyResizable = YES;
	view.horizontallyResizable = NO;
	view.appearance = [NSAppearance appearanceNamed: NSAppearanceNameAqua];
	[view.textStorage setAttributedString: attributed];
	[view.layoutManager ensureLayoutForTextContainer: view.textContainer];
	[view sizeToFit];
	return view;
}

#pragma mark - Validation

- (BOOL) validateMenuItem: (NSMenuItem *) item {
	const SEL action = item.action;
	Document *doc = [self doc];
	MacroRecorder *macro = [MacroRecorder shared];
	if (action == @selector(setLanguage:)) {
		const BOOL current = doc && [item.representedObject isEqualToString: ToNSString(doc.language->name)];
		item.state = current ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (action == @selector(setLineEnding:)) {
		item.state = doc && item.tag == static_cast<NSInteger>(doc.lineEnding) ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (action == @selector(convertEncoding:)) {
		item.state = doc && EncodingForTag(item.tag) == doc.encoding ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	}
	if (action == @selector(reopenWithEncoding:) || action == @selector(copyFilePath:) ||
	    action == @selector(copyDirectoryPath:) || action == @selector(openFolderInTerminal:))
		return doc.fileURL != nil;
	if (action == @selector(toUpperCase:) || action == @selector(toLowerCase:) || action == @selector(toProperCase:) ||
	    action == @selector(toSentenceCase:) || action == @selector(invertCase:))
		return ![self call: SCI_GETSELECTIONEMPTY];
	if (action == @selector(toggleMacroRecording:)) {
		item.title = macro.recording ? @"Stop Recording" : @"Start Recording";
		return !macro.playing;
	}
	if (action == @selector(playMacro:) || action == @selector(runMacroMultipleTimes:))
		return macro.hasMacro && !macro.recording;
	return YES;
}

#pragma mark - Window delegate

- (void) windowDidBecomeKey: (NSNotification *) notification {
	// Look for changes made by other programs, or on other devices, when coming back to a file.
	[[self doc] checkForExternalChange];
	[[self doc] keepVersionsInConflict];
}

- (void) windowDidBecomeMain: (NSNotification *) notification {
	[[SessionManager shared] documentStateDidChange]; // the selected tab is part of the session
}

- (void) windowDidResignMain: (NSNotification *) notification {
	// A macro belongs to the editor it was started in.
	MacroRecorder *macro = [MacroRecorder shared];
	if (macro.recording && NSApp.mainWindow != self.window && [NSApp.mainWindow.windowController isKindOfClass: [EditorWindowController class]]) {
		[macro stopRecording];
		[self refreshStatus];
	}
}

- (void) windowDidResize: (NSNotification *) notification {
	[self.window saveFrameUsingName: kWindowFrameName];
}

- (void) windowDidMove: (NSNotification *) notification {
	[self.window saveFrameUsingName: kWindowFrameName];
}

- (void) windowWillClose: (NSNotification *) notification {
	[self.window saveFrameUsingName: kWindowFrameName];
	_editor.delegate = nil;
	[[NSNotificationCenter defaultCenter] removeObserver: self];
}

@end
