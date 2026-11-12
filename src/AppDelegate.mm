// Application delegate: main menu, global options and themes.
// This file is part of MacPad (GPL v3 or later).
#import "AppDelegate.h"

#include <algorithm>
#include <map>
#include <strings.h>
#include <vector>

#import "AppSettings.h"
#import "CloudDocuments.h"
#import "Document.h"
#import "PreferencesWindow.h"
#import "SciUtil.h"
#import "SearchResultsPanel.h"
#import "SessionManager.h"

#include "LanguageCatalog.h"
#include "Theme.h"
#include "TextEncoding.h"

namespace
{

NSString *AppName()
{
	NSString *name = [NSBundle mainBundle].infoDictionary[@"CFBundleName"];
	return name.length ? name : [NSProcessInfo processInfo].processName;
}

NSString *KeyFor(unichar character)
{
	return [NSString stringWithCharacters: &character length: 1];
}

NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, NSString *key = @"",
                    NSEventModifierFlags modifiers = NSEventModifierFlagCommand)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: title action: action keyEquivalent: key ?: @""];
	if (key.length)
		item.keyEquivalentModifierMask = modifiers;
	[menu addItem: item];
	return item;
}

NSMenuItem *AddTaggedItem(NSMenu *menu, NSString *title, SEL action, NSInteger tag)
{
	NSMenuItem *item = AddItem(menu, title, action);
	item.tag = tag;
	return item;
}

NSMenu *AddSubmenu(NSMenu *menu, NSString *title)
{
	NSMenuItem *item = [[NSMenuItem alloc] initWithTitle: title action: nil keyEquivalent: @""];
	NSMenu *submenu = [[NSMenu alloc] initWithTitle: title];
	item.submenu = submenu;
	[menu addItem: item];
	return submenu;
}

void AddSeparator(NSMenu *menu)
{
	[menu addItem: [NSMenuItem separatorItem]];
}

} // namespace

@implementation AppDelegate
{
	NSMenu *_recentMenu;
}

#pragma mark - Launch

- (void) applicationWillFinishLaunching: (NSNotification *) notification {
	NSString *resources = [NSBundle mainBundle].resourcePath;
	LanguageCatalog::Shared().Load(ToStdString([resources stringByAppendingPathComponent: @"languages.json"]));
	StyleMap::Shared().Load(ToStdString([resources stringByAppendingPathComponent: @"stylemap.json"]));
	[[AppSettings shared] currentTheme];
	[self buildMainMenu];
	[NSApp addObserver: self forKeyPath: @"effectiveAppearance" options: 0 context: nil];
	// Before the launch finishes, so that files opened from Finder join the restored windows as tabs.
	[[SessionManager shared] restoreSession];
}

- (void) observeValueForKeyPath: (NSString *) keyPath
                       ofObject: (id) object
                         change: (NSDictionary<NSKeyValueChangeKey, id> *) change
                        context: (void *) context {
	if ([keyPath isEqualToString: @"effectiveAppearance"])
		[[AppSettings shared] appearanceDidChange];
}

- (void) applicationDidFinishLaunching: (NSNotification *) notification {
	[[CloudDocuments shared] start];
}

// A new empty document, unless the session brought documents back.
- (BOOL) applicationShouldOpenUntitledFile: (NSApplication *) sender {
	return [NSDocumentController sharedDocumentController].documents.count == 0;
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed: (NSApplication *) sender {
	return NO;
}

- (BOOL) applicationSupportsSecureRestorableState: (NSApplication *) app {
	return YES;
}

#pragma mark - Menu construction

- (void) buildMainMenu {
	NSMenu *mainMenu = [[NSMenu alloc] initWithTitle: @"Main Menu"];
	NSString *appName = AppName();

	// Application
	NSMenu *appMenu = AddSubmenu(mainMenu, appName);
	AddItem(appMenu, [NSString stringWithFormat: @"About %@", appName], @selector(showAboutPanel:));
	AddSeparator(appMenu);
	if (@available(macOS 13.0, *))
		AddItem(appMenu, @"Settings…", @selector(showPreferences:), @",");
	else
		AddItem(appMenu, @"Preferences…", @selector(showPreferences:), @",");
	AddSeparator(appMenu);
	NSMenu *services = AddSubmenu(appMenu, @"Services");
	NSApp.servicesMenu = services;
	AddSeparator(appMenu);
	AddItem(appMenu, [NSString stringWithFormat: @"Hide %@", appName], @selector(hide:), @"h");
	AddItem(appMenu, @"Hide Others", @selector(hideOtherApplications:), @"h", NSEventModifierFlagCommand | NSEventModifierFlagOption);
	AddItem(appMenu, @"Show All", @selector(unhideAllApplications:));
	AddSeparator(appMenu);
	AddItem(appMenu, [NSString stringWithFormat: @"Quit %@", appName], @selector(terminate:), @"q");

	[self buildFileMenuIn: mainMenu];
	[self buildEditMenuIn: mainMenu];
	[self buildSearchMenuIn: mainMenu];
	[self buildViewMenuIn: mainMenu];
	[self buildEncodingMenuIn: mainMenu];
	[self buildLanguageMenuIn: mainMenu];
	[self buildToolsMenuIn: mainMenu];
	[self buildMacroMenuIn: mainMenu];

	// Window
	NSMenu *windowMenu = AddSubmenu(mainMenu, @"Window");
	AddItem(windowMenu, @"Minimize", @selector(performMiniaturize:), @"m");
	AddItem(windowMenu, @"Zoom", @selector(performZoom:));
	AddSeparator(windowMenu);
	AddItem(windowMenu, @"Bring All to Front", @selector(arrangeInFront:));
	NSApp.windowsMenu = windowMenu;

	NSMenu *helpMenu = AddSubmenu(mainMenu, @"Help");
	if ([self homepage])
		AddItem(helpMenu, [NSString stringWithFormat: @"%@ Website", appName], @selector(openHomepage:));
	AddItem(helpMenu, @"License", @selector(showLicense:));
	AddItem(helpMenu, @"Acknowledgements", @selector(showAcknowledgements:));
	NSApp.helpMenu = helpMenu;

	NSApp.mainMenu = mainMenu;
}

- (void) buildFileMenuIn: (NSMenu *) mainMenu {
	const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
	const NSEventModifierFlags shift = NSEventModifierFlagShift;
	const NSEventModifierFlags option = NSEventModifierFlagOption;

	NSMenu *menu = AddSubmenu(mainMenu, @"File");
	AddItem(menu, @"New", @selector(newDocument:), @"n");
	AddItem(menu, @"Open…", @selector(openDocument:), @"o");
	_recentMenu = AddSubmenu(menu, @"Open Recent");
	_recentMenu.delegate = self;
	AddItem(menu, @"Open from iCloud…", @selector(openFromICloud:), @"o", cmd | shift);
	AddSeparator(menu);
	AddItem(menu, @"Close", @selector(performClose:), @"w");
	AddItem(menu, @"Close All", @selector(closeAllDocuments:), @"w", cmd | option);
	AddItem(menu, @"Save", @selector(saveDocument:), @"s");
	AddItem(menu, @"Save As…", @selector(saveDocumentAs:), @"s", cmd | shift);
	AddItem(menu, @"Save a Copy As…", @selector(saveDocumentTo:), @"s", cmd | shift | option);
	AddItem(menu, @"Save All", @selector(saveAllDocuments:), @"s", cmd | option);
	AddItem(menu, @"Reload from Disk", @selector(revertDocumentToSaved:));
	AddItem(menu, @"Rename…", @selector(renameFile:));
	AddItem(menu, @"Move To…", @selector(moveFile:));
	AddSeparator(menu);
	AddItem(menu, @"Reveal in Finder", @selector(revealInFinder:), @"r", cmd | shift);
	AddItem(menu, @"Open Folder in Terminal", @selector(openFolderInTerminal:));
	AddSeparator(menu);
	AddItem(menu, @"Page Setup…", @selector(runPageLayout:), @"p", cmd | shift);
	AddItem(menu, @"Print…", @selector(printDocument:), @"p");
}

- (void) buildEditMenuIn: (NSMenu *) mainMenu {
	const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
	const NSEventModifierFlags shift = NSEventModifierFlagShift;
	const NSEventModifierFlags option = NSEventModifierFlagOption;
	const NSEventModifierFlags control = NSEventModifierFlagControl;

	NSMenu *menu = AddSubmenu(mainMenu, @"Edit");
	AddItem(menu, @"Undo", @selector(undo:), @"z");
	AddItem(menu, @"Redo", @selector(redo:), @"z", cmd | shift);
	AddSeparator(menu);
	AddItem(menu, @"Cut", @selector(cut:), @"x");
	AddItem(menu, @"Copy", @selector(copy:), @"c");
	AddItem(menu, @"Paste", @selector(paste:), @"v");
	AddItem(menu, @"Delete", @selector(clear:));
	AddItem(menu, @"Select All", @selector(selectAll:), @"a");
	AddSeparator(menu);

	NSMenu *lines = AddSubmenu(menu, @"Line Operations");
	AddItem(lines, @"Duplicate Current Line", @selector(duplicateLine:), @"d");
	AddItem(lines, @"Delete Current Line", @selector(deleteLine:), @"k", cmd | shift);
	AddItem(lines, @"Move Up Current Line", @selector(moveLineUp:), KeyFor(NSUpArrowFunctionKey), cmd | option);
	AddItem(lines, @"Move Down Current Line", @selector(moveLineDown:), KeyFor(NSDownArrowFunctionKey), cmd | option);
	AddItem(lines, @"Join Lines", @selector(joinLines:), @"j", cmd | control);
	AddItem(lines, @"Insert Blank Line Above Current", @selector(insertBlankLineAbove:), @"\r", cmd | option);
	AddItem(lines, @"Insert Blank Line Below Current", @selector(insertBlankLineBelow:), @"\r", cmd | option | shift);
	AddSeparator(lines);
	AddItem(lines, @"Sort Lines Lexicographically Ascending", @selector(sortLinesAscending:));
	AddItem(lines, @"Sort Lines Lexicographically Descending", @selector(sortLinesDescending:));
	AddItem(lines, @"Sort Lines Ascending, Ignoring Case", @selector(sortLinesIgnoringCase:));
	AddItem(lines, @"Sort Lines As Numbers Ascending", @selector(sortLinesNumerically:));
	AddItem(lines, @"Reverse Line Order", @selector(reverseLines:));
	AddSeparator(lines);
	AddItem(lines, @"Remove Duplicate Lines", @selector(removeDuplicateLines:));
	AddItem(lines, @"Remove Empty Lines", @selector(removeEmptyLines:));

	NSMenu *comment = AddSubmenu(menu, @"Comment/Uncomment");
	AddItem(comment, @"Toggle Single Line Comment", @selector(toggleLineComment:), @"/");
	AddItem(comment, @"Toggle Block Comment", @selector(toggleBlockComment:), @"/", cmd | option);

	NSMenu *caseMenu = AddSubmenu(menu, @"Convert Case to");
	AddItem(caseMenu, @"UPPERCASE", @selector(toUpperCase:), @"u", cmd | shift);
	AddItem(caseMenu, @"lowercase", @selector(toLowerCase:), @"u");
	AddItem(caseMenu, @"Proper Case", @selector(toProperCase:));
	AddItem(caseMenu, @"Sentence case", @selector(toSentenceCase:));
	AddItem(caseMenu, @"iNVERT cASE", @selector(invertCase:));

	NSMenu *blank = AddSubmenu(menu, @"Blank Operations");
	AddItem(blank, @"Trim Trailing Space", @selector(trimTrailingSpace:));
	AddItem(blank, @"Trim Leading Space", @selector(trimLeadingSpace:));
	AddItem(blank, @"Trim Leading and Trailing Space", @selector(trimLeadingAndTrailingSpace:));
	AddItem(blank, @"TAB to Space", @selector(tabsToSpaces:));
	AddItem(blank, @"Space to TAB (Leading)", @selector(leadingSpacesToTabs:));

	_lineEndingMenu = AddSubmenu(menu, @"EOL Conversion");
	AddTaggedItem(_lineEndingMenu, @"Windows (CR LF)", @selector(setLineEnding:), static_cast<NSInteger>(LineEnding::CRLF));
	AddTaggedItem(_lineEndingMenu, @"Unix (LF)", @selector(setLineEnding:), static_cast<NSInteger>(LineEnding::LF));
	AddTaggedItem(_lineEndingMenu, @"Macintosh (CR)", @selector(setLineEnding:), static_cast<NSInteger>(LineEnding::CR));

	NSMenu *indentation = AddSubmenu(menu, @"Indentation");
	for (NSInteger width : {2, 3, 4, 8})
		AddTaggedItem(indentation, [NSString stringWithFormat: @"Tab Width: %ld", (long)width], @selector(setTabWidth:), width);
	AddSeparator(indentation);
	AddItem(indentation, @"Indent Using Spaces", @selector(toggleUseSpaces:));
	AddItem(indentation, @"Auto-Indent", @selector(toggleAutoIndent:));

	NSMenu *insert = AddSubmenu(menu, @"Insert");
	AddItem(insert, @"Date and Time (Short)", @selector(insertDateTimeShort:));
	AddItem(insert, @"Date and Time (Long)", @selector(insertDateTimeLong:));
	AddItem(insert, @"Date and Time (ISO 8601)", @selector(insertDateTimeISO:));

	AddSeparator(menu);
	AddItem(menu, @"Complete Word", @selector(completeWord:), @" ", control);
	AddSeparator(menu);
	NSMenu *clipboard = AddSubmenu(menu, @"Copy to Clipboard");
	AddItem(clipboard, @"Full File Path", @selector(copyFilePath:));
	AddItem(clipboard, @"File Name", @selector(copyFileName:));
	AddItem(clipboard, @"Folder Path", @selector(copyDirectoryPath:));
}

- (void) buildSearchMenuIn: (NSMenu *) mainMenu {
	const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
	const NSEventModifierFlags shift = NSEventModifierFlagShift;
	const NSEventModifierFlags option = NSEventModifierFlagOption;
	const NSEventModifierFlags control = NSEventModifierFlagControl;

	NSMenu *menu = AddSubmenu(mainMenu, @"Search");
	AddItem(menu, @"Find…", @selector(showFindPanel:), @"f");
	AddItem(menu, @"Find Next", @selector(findNext:), @"g");
	AddItem(menu, @"Find Previous", @selector(findPrevious:), @"g", cmd | shift);
	AddItem(menu, @"Replace…", @selector(showReplacePanel:), @"f", cmd | option);
	AddItem(menu, @"Use Selection for Find", @selector(useSelectionForFind:), @"e");
	AddSeparator(menu);
	AddItem(menu, @"Find in Files…", @selector(findInFiles:), @"f", cmd | shift);
	AddItem(menu, @"Search Results Window", @selector(showSearchResults:), KeyFor(NSF7FunctionKey), 0);
	AddSeparator(menu);
	AddItem(menu, @"Select Next Occurrence", @selector(selectNextOccurrence:), @"e", cmd | option);
	AddItem(menu, @"Select All Occurrences", @selector(selectAllOccurrences:), @"g", cmd | control);
	AddSeparator(menu);
	AddItem(menu, @"Go to Line…", @selector(goToLine:), @"l");
	AddItem(menu, @"Go to Matching Brace", @selector(goToMatchingBrace:), @"b");
	AddItem(menu, @"Select to Matching Brace", @selector(selectToMatchingBrace:), @"b", cmd | shift);
	AddSeparator(menu);
	AddItem(menu, @"Clear All Marks", @selector(clearMarks:));
	NSMenu *bookmarks = AddSubmenu(menu, @"Bookmark");
	AddItem(bookmarks, @"Toggle Bookmark", @selector(toggleBookmark:), KeyFor(NSF2FunctionKey), cmd);
	AddItem(bookmarks, @"Next Bookmark", @selector(nextBookmark:), KeyFor(NSF2FunctionKey), 0);
	AddItem(bookmarks, @"Previous Bookmark", @selector(previousBookmark:), KeyFor(NSF2FunctionKey), shift);
	AddItem(bookmarks, @"Clear All Bookmarks", @selector(clearBookmarks:));
}

- (void) buildViewMenuIn: (NSMenu *) mainMenu {
	const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
	const NSEventModifierFlags shift = NSEventModifierFlagShift;
	const NSEventModifierFlags option = NSEventModifierFlagOption;
	const NSEventModifierFlags control = NSEventModifierFlagControl;

	NSMenu *menu = AddSubmenu(mainMenu, @"View");
	AddItem(menu, @"Show Tab Bar", @selector(toggleTabBar:));
	AddItem(menu, @"Show All Tabs", @selector(toggleTabOverview:), @"\\", cmd | shift);
	AddSeparator(menu);
	AddItem(menu, @"Word Wrap", @selector(toggleWordWrap:));
	NSMenu *symbols = AddSubmenu(menu, @"Show Symbol");
	AddItem(symbols, @"Show White Space and TAB", @selector(toggleShowWhitespace:));
	AddItem(symbols, @"Show End of Line", @selector(toggleShowEndOfLine:));
	AddItem(symbols, @"Show All Characters", @selector(toggleShowAllCharacters:));
	AddSeparator(symbols);
	AddItem(symbols, @"Show Indent Guide", @selector(toggleIndentGuides:));
	AddItem(menu, @"Show Line Numbers", @selector(toggleLineNumbers:));
	AddItem(menu, @"Show Change History", @selector(toggleChangeHistory:));
	AddItem(menu, @"Highlight Current Line", @selector(toggleHighlightCurrentLine:));
	AddItem(menu, @"Smart Highlighting", @selector(toggleSmartHighlighting:));
	AddSeparator(menu);
	AddItem(menu, @"Zoom In", @selector(zoomInText:), @"=");
	AddItem(menu, @"Zoom Out", @selector(zoomOutText:), @"-");
	AddItem(menu, @"Restore Default Zoom", @selector(resetTextZoom:), @"0");
	AddSeparator(menu);
	AddItem(menu, @"Fold All", @selector(foldAll:), KeyFor(NSLeftArrowFunctionKey), cmd | option | shift);
	AddItem(menu, @"Unfold All", @selector(unfoldAll:), KeyFor(NSRightArrowFunctionKey), cmd | option | shift);
	AddItem(menu, @"Fold Current Level", @selector(foldCurrentLevel:), KeyFor(NSLeftArrowFunctionKey), cmd | option);
	AddItem(menu, @"Unfold Current Level", @selector(unfoldCurrentLevel:), KeyFor(NSRightArrowFunctionKey), cmd | option);
	AddSeparator(menu);

	NSMenu *themes = AddSubmenu(menu, @"Theme");
	AddItem(themes, @"Automatic (Light / Dark)", @selector(setTheme:)).representedObject = kThemeAutomatic;
	AddSeparator(themes);
	for (NSString *name in [[AppSettings shared] availableThemes])
		AddItem(themes, name, @selector(setTheme:)).representedObject = name;

	AddSeparator(menu);
	AddItem(menu, @"Enter Full Screen", @selector(toggleFullScreen:), @"f", cmd | control);
}

- (void) buildEncodingMenuIn: (NSMenu *) mainMenu {
	_encodingMenu = AddSubmenu(mainMenu, @"Encoding");
	AddTaggedItem(_encodingMenu, @"Convert to UTF-8", @selector(convertEncoding:), 1);
	AddTaggedItem(_encodingMenu, @"Convert to UTF-8-BOM", @selector(convertEncoding:), 2);
	AddTaggedItem(_encodingMenu, @"Convert to UTF-16 BE BOM", @selector(convertEncoding:), 3);
	AddTaggedItem(_encodingMenu, @"Convert to UTF-16 LE BOM", @selector(convertEncoding:), 4);
	AddTaggedItem(_encodingMenu, @"Convert to ANSI (Windows-1252)", @selector(convertEncoding:), 5);
	AddSeparator(_encodingMenu);

	NSMenu *reopen = AddSubmenu(_encodingMenu, @"Reopen with Encoding");
	const struct
	{
		NSString *title;
		CFStringEncoding encoding;
	} encodings[] = {
		{@"UTF-8", kCFStringEncodingUTF8},
		{@"UTF-16 LE", kCFStringEncodingUTF16LE},
		{@"UTF-16 BE", kCFStringEncodingUTF16BE},
		{nil, 0},
		{@"Western European (Windows-1252)", kCFStringEncodingWindowsLatin1},
		{@"Western European (ISO 8859-1)", kCFStringEncodingISOLatin1},
		{@"Western European (ISO 8859-15)", kCFStringEncodingISOLatin9},
		{@"Western European (Mac OS Roman)", kCFStringEncodingMacRoman},
		{@"Central European (Windows-1250)", kCFStringEncodingWindowsLatin2},
		{@"Cyrillic (Windows-1251)", kCFStringEncodingWindowsCyrillic},
		{@"Cyrillic (KOI8-R)", kCFStringEncodingKOI8_R},
		{@"Greek (Windows-1253)", kCFStringEncodingWindowsGreek},
		{@"Turkish (Windows-1254)", kCFStringEncodingWindowsLatin5},
		{@"Japanese (Shift-JIS)", kCFStringEncodingDOSJapanese},
		{@"Japanese (EUC-JP)", kCFStringEncodingEUC_JP},
		{@"Chinese Simplified (GB 18030)", kCFStringEncodingGB_18030_2000},
		{@"Chinese Traditional (Big5)", kCFStringEncodingBig5},
		{@"Korean (EUC-KR)", kCFStringEncodingEUC_KR},
	};
	for (const auto &entry : encodings) {
		if (!entry.title)
			AddSeparator(reopen);
		else
			AddTaggedItem(reopen, entry.title, @selector(reopenWithEncoding:), static_cast<NSInteger>(entry.encoding));
	}
}

// Normal Text, then one submenu per initial letter.
- (void) buildLanguageMenuIn: (NSMenu *) mainMenu {
	_languageMenu = AddSubmenu(mainMenu, @"Language");
	const LanguageCatalog &catalog = LanguageCatalog::Shared();
	AddItem(_languageMenu, @"Normal Text", @selector(setLanguage:)).representedObject = ToNSString(catalog.NormalText().name);
	AddSeparator(_languageMenu);

	std::map<std::string, std::vector<const Language *>> byLetter;
	for (const Language &language : catalog.All()) {
		if (language.hidden || language.name == "normal" || language.name == "ext" || language.menuName.empty())
			continue;
		std::string letter(1, static_cast<char>(std::toupper(static_cast<unsigned char>(language.menuName[0]))));
		byLetter[letter].push_back(&language);
	}
	for (auto &[letter, languages] : byLetter) {
		std::sort(languages.begin(), languages.end(), [](const Language *a, const Language *b) {
			return strcasecmp(a->menuName.c_str(), b->menuName.c_str()) < 0;
		});
		NSMenu *submenu = AddSubmenu(_languageMenu, ToNSString(letter));
		for (const Language *language : languages)
			AddItem(submenu, ToNSString(language->menuName), @selector(setLanguage:)).representedObject = ToNSString(language->name);
	}
}

- (void) buildToolsMenuIn: (NSMenu *) mainMenu {
	NSMenu *menu = AddSubmenu(mainMenu, @"Tools");
	NSMenu *hash = AddSubmenu(menu, @"Checksum");
	AddItem(hash, @"MD5", @selector(hashMD5:));
	AddItem(hash, @"SHA-1", @selector(hashSHA1:));
	AddItem(hash, @"SHA-256", @selector(hashSHA256:));
	AddItem(hash, @"SHA-512", @selector(hashSHA512:));
	AddSeparator(menu);
	AddItem(menu, @"Base64 Encode", @selector(base64Encode:));
	AddItem(menu, @"Base64 Decode", @selector(base64Decode:));
	AddItem(menu, @"URL Encode", @selector(urlEncode:));
	AddItem(menu, @"URL Decode", @selector(urlDecode:));
	AddSeparator(menu);
	AddItem(menu, @"Format JSON", @selector(formatJSON:));
	AddItem(menu, @"Minify JSON", @selector(minifyJSON:));
}

- (void) buildMacroMenuIn: (NSMenu *) mainMenu {
	const NSEventModifierFlags cmd = NSEventModifierFlagCommand;
	const NSEventModifierFlags control = NSEventModifierFlagControl;

	NSMenu *menu = AddSubmenu(mainMenu, @"Macro");
	AddItem(menu, @"Start Recording", @selector(toggleMacroRecording:), @"r", cmd | control);
	AddItem(menu, @"Playback", @selector(playMacro:), @"p", cmd | control);
	AddItem(menu, @"Run a Macro Multiple Times…", @selector(runMacroMultipleTimes:));
}

#pragma mark - Application menu and Help

- (IBAction) showPreferences: (id) sender {
	[[PreferencesWindow shared] showWindow: sender];
}

- (IBAction) showAboutPanel: (id) sender {
	NSString *text = @"A native text editor for macOS.\n\n"
	                 @"Free software under the GNU General Public License, version 3 or later, "
	                 @"with ABSOLUTELY NO WARRANTY. See Help > License.\n\n"
	                 @"Includes open-source components; see Help > Acknowledgements.";
	NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
	paragraph.alignment = NSTextAlignmentCenter;
	NSAttributedString *credits = [[NSAttributedString alloc] initWithString: text attributes: @{
		NSFontAttributeName: [NSFont systemFontOfSize: [NSFont smallSystemFontSize]],
		NSForegroundColorAttributeName: [NSColor labelColor],
		NSParagraphStyleAttributeName: paragraph,
	}];
	[NSApp orderFrontStandardAboutPanelWithOptions: @{NSAboutPanelOptionCredits: credits}];
}

// Set by the HOMEPAGE variable of the Makefile; without it the Help menu has no website item.
- (NSURL *) homepage {
	NSString *address = [NSBundle mainBundle].infoDictionary[@"MacPadHomepage"];
	NSURL *url = address.length ? [NSURL URLWithString: address] : nil;
	return [url.scheme isEqualToString: @"https"] || [url.scheme isEqualToString: @"http"] ? url : nil;
}

- (IBAction) openHomepage: (id) sender {
	NSURL *url = [self homepage];
	if (url)
		[[NSWorkspace sharedWorkspace] openURL: url];
}

// Opens a text file of the app bundle as a document, to read (Help > License, Acknowledgements).
- (void) openBundledText: (NSString *) name {
	NSURL *url = [[NSBundle mainBundle] URLForResource: name withExtension: @"txt"];
	if (!url)
		return;
	[[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL: url display: YES
	                                                            completionHandler: ^(NSDocument *document, BOOL wasOpen, NSError *error) {
		if (error)
			[NSApp presentError: error];
	}];
}

- (IBAction) showLicense: (id) sender {
	[self openBundledText: @"LICENSE"];
}

- (IBAction) showAcknowledgements: (id) sender {
	[self openBundledText: @"Acknowledgements"];
}

#pragma mark - Open Recent

- (void) menuNeedsUpdate: (NSMenu *) menu {
	if (menu != _recentMenu)
		return;
	[menu removeAllItems];
	NSArray<NSURL *> *urls = [NSDocumentController sharedDocumentController].recentDocumentURLs;
	for (NSURL *url in urls) {
		NSMenuItem *item = AddItem(menu, url.lastPathComponent, @selector(openRecentDocument:));
		item.representedObject = url;
		item.toolTip = url.path;
		NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile: url.path];
		icon.size = NSMakeSize(16, 16);
		item.image = icon;
	}
	if (urls.count)
		AddSeparator(menu);
	NSMenuItem *clear = AddItem(menu, @"Clear Menu", @selector(clearRecentDocuments:));
	clear.target = [NSDocumentController sharedDocumentController];
	clear.enabled = urls.count > 0;
}

- (IBAction) openRecentDocument: (id) sender {
	NSURL *url = [sender representedObject];
	[[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL: url display: YES
	                                                            completionHandler: ^(NSDocument *document, BOOL wasOpen, NSError *error) {
		if (error)
			[NSApp presentError: error];
	}];
}

#pragma mark - File actions

- (IBAction) saveAllDocuments: (id) sender {
	for (NSDocument *document in [NSDocumentController sharedDocumentController].documents) {
		if (document.isDocumentEdited)
			[document saveDocument: sender];
	}
}

- (IBAction) closeAllDocuments: (id) sender {
	[[NSDocumentController sharedDocumentController] closeAllDocumentsWithDelegate: nil didCloseAllSelector: nil contextInfo: nil];
}

// Also reachable when no document window is open (the editor windows handle it otherwise).
- (IBAction) showSearchResults: (id) sender {
	[[SearchResultsPanel shared] showWindow: sender];
}

- (IBAction) revealInFinder: (id) sender {
	NSURL *url = [NSDocumentController sharedDocumentController].currentDocument.fileURL;
	if (url)
		[[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs: @[url]];
}

// The Open panel, in iCloud Drive › MacPad (or iCloud Drive, before that folder exists).
- (IBAction) openFromICloud: (id) sender {
	NSURL *folder = [CloudDocuments shared].folderURL;
	if (!folder)
		return;
	if (![[NSFileManager defaultManager] fileExistsAtPath: folder.path])
		folder = folder.URLByDeletingLastPathComponent;
	NSOpenPanel *panel = [NSOpenPanel openPanel];
	panel.allowsMultipleSelection = YES;
	panel.canChooseDirectories = NO;
	panel.directoryURL = folder;
	[panel beginWithCompletionHandler: ^(NSModalResponse response) {
		if (response != NSModalResponseOK)
			return;
		for (NSURL *url in panel.URLs) {
			[[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL: url display: YES
			                                                            completionHandler: ^(NSDocument *document, BOOL wasOpen, NSError *error) {
				if (error)
					[NSApp presentError: error];
			}];
		}
	}];
}

#pragma mark - Global options

- (IBAction) toggleWordWrap: (id) sender { [AppSettings shared].wordWrap = ![AppSettings shared].wordWrap; }
- (IBAction) toggleShowWhitespace: (id) sender { [AppSettings shared].showWhitespace = ![AppSettings shared].showWhitespace; }
- (IBAction) toggleShowEndOfLine: (id) sender { [AppSettings shared].showEndOfLine = ![AppSettings shared].showEndOfLine; }
- (IBAction) toggleIndentGuides: (id) sender { [AppSettings shared].showIndentGuides = ![AppSettings shared].showIndentGuides; }
- (IBAction) toggleLineNumbers: (id) sender { [AppSettings shared].showLineNumbers = ![AppSettings shared].showLineNumbers; }
- (IBAction) toggleChangeHistory: (id) sender { [AppSettings shared].showChangeHistory = ![AppSettings shared].showChangeHistory; }
- (IBAction) toggleSmartHighlighting: (id) sender { [AppSettings shared].smartHighlighting = ![AppSettings shared].smartHighlighting; }
- (IBAction) toggleHighlightCurrentLine: (id) sender { [AppSettings shared].highlightCurrentLine = ![AppSettings shared].highlightCurrentLine; }
- (IBAction) toggleUseSpaces: (id) sender { [AppSettings shared].useSpaces = ![AppSettings shared].useSpaces; }
- (IBAction) toggleAutoIndent: (id) sender { [AppSettings shared].autoIndent = ![AppSettings shared].autoIndent; }

- (IBAction) toggleShowAllCharacters: (id) sender {
	AppSettings *settings = [AppSettings shared];
	const BOOL show = !(settings.showWhitespace && settings.showEndOfLine);
	settings.showWhitespace = show;
	settings.showEndOfLine = show;
}

- (IBAction) setTabWidth: (id) sender {
	[AppSettings shared].tabWidth = [sender tag];
}

- (IBAction) setTheme: (id) sender {
	[AppSettings shared].themeName = [sender representedObject];
}

- (BOOL) validateMenuItem: (NSMenuItem *) item {
	AppSettings *settings = [AppSettings shared];
	const SEL action = item.action;
	auto check = [item](BOOL on) {
		item.state = on ? NSControlStateValueOn : NSControlStateValueOff;
		return YES;
	};

	if (action == @selector(toggleWordWrap:))
		return check(settings.wordWrap);
	if (action == @selector(toggleShowWhitespace:))
		return check(settings.showWhitespace);
	if (action == @selector(toggleShowEndOfLine:))
		return check(settings.showEndOfLine);
	if (action == @selector(toggleShowAllCharacters:))
		return check(settings.showWhitespace && settings.showEndOfLine);
	if (action == @selector(toggleIndentGuides:))
		return check(settings.showIndentGuides);
	if (action == @selector(toggleLineNumbers:))
		return check(settings.showLineNumbers);
	if (action == @selector(toggleChangeHistory:))
		return check(settings.showChangeHistory);
	if (action == @selector(toggleSmartHighlighting:))
		return check(settings.smartHighlighting);
	if (action == @selector(toggleHighlightCurrentLine:))
		return check(settings.highlightCurrentLine);
	if (action == @selector(toggleUseSpaces:))
		return check(settings.useSpaces);
	if (action == @selector(toggleAutoIndent:))
		return check(settings.autoIndent);
	if (action == @selector(setTabWidth:))
		return check(item.tag == settings.tabWidth);
	if (action == @selector(setTheme:))
		return check([item.representedObject isEqualToString: settings.themeName]);
	if (action == @selector(revealInFinder:))
		return [NSDocumentController sharedDocumentController].currentDocument.fileURL != nil;
	if (action == @selector(openFromICloud:))
		return CloudDocuments.iCloudDriveAvailable;
	if (action == @selector(saveAllDocuments:)) {
		for (NSDocument *document in [NSDocumentController sharedDocumentController].documents) {
			if (document.isDocumentEdited)
				return YES;
		}
		return NO;
	}
	if (action == @selector(closeAllDocuments:))
		return [NSDocumentController sharedDocumentController].documents.count > 0;
	return YES;
}

@end
