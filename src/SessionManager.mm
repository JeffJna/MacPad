// Session snapshot and periodic backup of unsaved documents.
// This file is part of MacPad (GPL v3 or later).
#import "SessionManager.h"

#include <algorithm>
#include <cmath>
#include <string>

#import "AppSettings.h"
#import "Document.h"
#import "EditorWindowController.h"
#import "SciUtil.h"

#include "LanguageCatalog.h"

static const NSTimeInterval kBackupDelay = 5.0; // unsaved text is on disk this long after a change
static const NSTimeInterval kStateDelay = 1.0;
// Larger unsaved documents are only backed up when quitting, not while typing.
static const sptr_t kPeriodicBackupLimit = 32 * 1024 * 1024;

@implementation SessionManager
{
	NSTimer *_timer;
}

+ (instancetype) shared {
	static SessionManager *manager;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		manager = [[SessionManager alloc] init];
	});
	return manager;
}

#pragma mark - Files

- (NSURL *) directory {
	NSFileManager *files = [NSFileManager defaultManager];
	NSURL *support = [files URLForDirectory: NSApplicationSupportDirectory inDomain: NSUserDomainMask
	                      appropriateForURL: nil create: YES error: nil];
	NSString *name = [NSBundle mainBundle].bundleIdentifier ?: @"MacPad";
	NSURL *directory = [support URLByAppendingPathComponent: name isDirectory: YES];
	[files createDirectoryAtURL: [directory URLByAppendingPathComponent: @"backup" isDirectory: YES]
	withIntermediateDirectories: YES attributes: nil error: nil];
	return directory;
}

- (NSURL *) sessionFile {
	return [[self directory] URLByAppendingPathComponent: @"session.plist"];
}

- (NSURL *) backupDirectory {
	return [[self directory] URLByAppendingPathComponent: @"backup" isDirectory: YES];
}

- (NSURL *) backupURLForID: (NSString *) sessionID {
	// Session ids are UUIDs written by this app, but the name still must not leave the directory.
	NSString *name = [[sessionID.lastPathComponent stringByDeletingPathExtension] stringByAppendingPathExtension: @"txt"];
	return [[self backupDirectory] URLByAppendingPathComponent: name];
}

- (void) removeSession {
	NSFileManager *files = [NSFileManager defaultManager];
	[files removeItemAtURL: [self sessionFile] error: nil];
	for (NSURL *url in [files contentsOfDirectoryAtURL: [self backupDirectory] includingPropertiesForKeys: nil options: 0 error: nil])
		[files removeItemAtURL: url error: nil];
}

#pragma mark - Writing

- (NSDictionary *) entryForDocument: (Document *) document controller: (EditorWindowController *) controller
                    forcingBackup: (BOOL) force stored: (BOOL *) stored {
	ScintillaView *editor = controller.editor;
	NSMutableDictionary *entry = [NSMutableDictionary dictionary];
	entry[@"id"] = document.sessionID;
	if (document.fileURL)
		entry[@"path"] = document.fileURL.path;
	else
		entry[@"untitled"] = @(document.untitledNumber);
	entry[@"language"] = ToNSString(document.language->name);
	entry[@"languageChosen"] = @(document.languageChosenByUser);
	entry[@"encodingKind"] = @(static_cast<int>(document.encoding.kind));
	entry[@"cfEncoding"] = @(document.encoding.cfEncoding);
	entry[@"lineEnding"] = @(static_cast<int>(document.lineEnding));
	entry[@"caret"] = @(SciCall(editor, SCI_GETCURRENTPOS));
	entry[@"anchor"] = @(SciCall(editor, SCI_GETANCHOR));
	entry[@"firstLine"] = @(SciCall(editor, SCI_GETFIRSTVISIBLELINE));

	NSMutableArray<NSNumber *> *bookmarks = [NSMutableArray array];
	for (sptr_t line = SciCall(editor, SCI_MARKERNEXT, 0, 1 << kMarkerBookmark); line >= 0 && bookmarks.count < 10000;
	     line = SciCall(editor, SCI_MARKERNEXT, line + 1, 1 << kMarkerBookmark))
		[bookmarks addObject: @(line)];
	if (bookmarks.count)
		entry[@"bookmarks"] = bookmarks;

	NSFileManager *files = [NSFileManager defaultManager];
	NSURL *backup = [self backupURLForID: document.sessionID];
	if (!document.hasUnsavedChanges) {
		[files removeItemAtURL: backup error: nil];
		return entry;
	}

	const BOOL exists = [files fileExistsAtPath: backup.path];
	const BOOL stale = !exists || document.backupSerial != document.changeSerial;
	if (stale && (force || SciCall(editor, SCI_GETLENGTH) <= kPeriodicBackupLimit)) {
		const std::string text = [controller documentText];
		NSData *data = [NSData dataWithBytesNoCopy: const_cast<char *>(text.data()) length: text.size() freeWhenDone: NO];
		if ([data writeToURL: backup options: NSDataWritingAtomic error: nil])
			document.backupSerial = document.changeSerial;
		else
			*stored = NO;
	} else if (stale) {
		*stored = NO; // too large for a periodic backup: only written when quitting
	}
	if ([files fileExistsAtPath: backup.path]) {
		entry[@"backup"] = backup.lastPathComponent;
		if (document.fileModificationDate)
			entry[@"fileModified"] = document.fileModificationDate;
	}
	return entry;
}

- (BOOL) writeSessionForcingBackups: (BOOL) force {
	if (_restoring)
		return YES;
	[_timer invalidate];
	_timer = nil;
	if (![AppSettings shared].rememberSession) {
		[self removeSession];
		return NO;
	}

	// Front to back, one entry per window (tab group).
	NSMutableArray<NSWindow *> *candidates = [NSApp.orderedWindows mutableCopy] ?: [NSMutableArray array];
	for (NSDocument *document in [NSDocumentController sharedDocumentController].documents) {
		for (NSWindowController *controller in document.windowControllers) {
			if (controller.windowLoaded && controller.window)
				[candidates addObject: controller.window];
		}
	}

	BOOL stored = YES;
	NSMutableArray *windows = [NSMutableArray array];
	NSMutableSet<NSWindow *> *visited = [NSMutableSet set];
	for (NSWindow *window in candidates) {
		if ([visited containsObject: window] || ![window.windowController isKindOfClass: [EditorWindowController class]])
			continue;
		NSArray<NSWindow *> *group = window.tabbedWindows ?: @[window];
		NSWindow *selectedWindow = window.tabGroup.selectedWindow ?: window;
		NSMutableArray *tabs = [NSMutableArray array];
		NSInteger selected = 0;
		for (NSWindow *tab in group) {
			[visited addObject: tab];
			EditorWindowController *controller = tab.windowController;
			if (![controller isKindOfClass: [EditorWindowController class]])
				continue;
			Document *document = controller.document;
			if (![document isKindOfClass: [Document class]])
				continue;
			if (tab == selectedWindow)
				selected = static_cast<NSInteger>(tabs.count);
			[tabs addObject: [self entryForDocument: document controller: controller forcingBackup: force stored: &stored]];
		}
		[visited addObject: window];
		if (tabs.count)
			[windows addObject: @{@"frame": NSStringFromRect(selectedWindow.frame), @"selected": @(selected), @"tabs": tabs}];
	}

	NSDictionary *session = @{@"version": @1, @"windows": windows};
	NSData *data = [NSPropertyListSerialization dataWithPropertyList: session format: NSPropertyListBinaryFormat_v1_0
	                                                         options: 0 error: nil];
	if (![data writeToURL: [self sessionFile] options: NSDataWritingAtomic error: nil])
		return NO;
	return stored;
}

- (BOOL) saveNow {
	return [self writeSessionForcingBackups: YES];
}

- (BOOL) prepareForTermination {
	return [self writeSessionForcingBackups: YES];
}

- (void) scheduleWriteAfter: (NSTimeInterval) delay {
	if (_restoring || _terminating)
		return;
	if (_timer && _timer.valid && _timer.fireDate.timeIntervalSinceNow <= delay)
		return;
	[_timer invalidate];
	__weak SessionManager *weakSelf = self;
	_timer = [NSTimer timerWithTimeInterval: delay repeats: NO block: ^(NSTimer *timer) {
		[weakSelf writeSessionForcingBackups: NO];
	}];
	// Common modes: the backup also runs while a menu or a modal panel is open.
	[[NSRunLoop mainRunLoop] addTimer: _timer forMode: NSRunLoopCommonModes];
}

- (void) documentTextDidChange: (Document *) document {
	[self scheduleWriteAfter: kBackupDelay];
}

- (void) documentStateDidChange {
	[self scheduleWriteAfter: kStateDelay];
}

- (void) documentDidClose: (Document *) document {
	if (_terminating || _restoring)
		return;
	[[NSFileManager defaultManager] removeItemAtURL: [self backupURLForID: document.sessionID] error: nil];
	[self scheduleWriteAfter: kStateDelay];
}

#pragma mark - Restoring

- (Document *) openEntry: (NSDictionary *) entry {
	NSDocumentController *controller = [NSDocumentController sharedDocumentController];
	NSFileManager *files = [NSFileManager defaultManager];
	NSString *path = [entry[@"path"] isKindOfClass: [NSString class]] ? entry[@"path"] : nil;
	NSString *sessionID = [entry[@"id"] isKindOfClass: [NSString class]] ? entry[@"id"] : nil;

	std::string backupText;
	BOOL hasBackup = NO;
	if ([entry[@"backup"] isKindOfClass: [NSString class]] && sessionID) {
		NSData *data = [NSData dataWithContentsOfURL: [self backupURLForID: sessionID]];
		if (data) {
			backupText.assign(static_cast<const char *>(data.bytes), data.length);
			hasBackup = YES;
		}
	}

	Document *document = nil;
	if (path) {
		NSURL *url = [NSURL fileURLWithPath: path];
		if ([controller documentForURL: url])
			return nil; // already open, for example because it was passed on the command line
		if ([files fileExistsAtPath: path])
			document = [controller makeDocumentWithContentsOfURL: url ofType: controller.defaultType error: nil];
		if (!document && !hasBackup)
			return nil; // the file is gone and nothing was unsaved
	}
	if (!document) {
		document = [controller makeUntitledDocumentOfType: controller.defaultType error: nil];
		if (![document isKindOfClass: [Document class]])
			return nil;
		if (!path && [entry[@"untitled"] integerValue] > 0)
			document.untitledNumber = [entry[@"untitled"] integerValue];
	}
	if (![document isKindOfClass: [Document class]])
		return nil;
	if (sessionID)
		document.sessionID = sessionID;

	const Language *language = LanguageCatalog::Shared().Find(ToStdString(entry[@"language"] ?: @""));
	const BOOL languageChosen = [entry[@"languageChosen"] boolValue];
	if (language && (languageChosen || !document.fileURL)) {
		document.language = language;
		document.languageChosenByUser = languageChosen;
	}

	[controller addDocument: document];
	[document makeWindowControllers];
	EditorWindowController *editorController = document.editorController;
	ScintillaView *editor = editorController.editor;

	if (hasBackup) {
		const int kind = [entry[@"encodingKind"] intValue];
		if (kind >= FileEncoding::UTF8 && kind <= FileEncoding::Legacy) {
			FileEncoding encoding = FileEncoding::Make(static_cast<FileEncoding::Kind>(kind));
			encoding.cfEncoding = static_cast<CFStringEncoding>([entry[@"cfEncoding"] unsignedIntValue]);
			document.encoding = encoding;
		}
		const int eol = [entry[@"lineEnding"] intValue];
		if (eol >= static_cast<int>(LineEnding::CRLF) && eol <= static_cast<int>(LineEnding::CR))
			document.lineEnding = static_cast<LineEnding>(eol);
		[editorController loadText: backupText keepPosition: NO];
		document.hasRestoredUnsavedText = YES;
		[document updateChangeCount: NSChangeDone];
		document.backupSerial = document.changeSerial;

		// The file changed while the app was closed: keep the date the edits were based on,
		// so the usual "modified by another program" question comes up.
		NSDate *recorded = [entry[@"fileModified"] isKindOfClass: [NSDate class]] ? entry[@"fileModified"] : nil;
		if (document.fileURL && recorded && document.fileModificationDate &&
		    std::fabs([recorded timeIntervalSinceDate: document.fileModificationDate]) > 0.001)
			document.fileModificationDate = recorded;
	}
	[editorController applyLanguage];

	const sptr_t length = SciCall(editor, SCI_GETLENGTH);
	const sptr_t anchor = std::clamp<sptr_t>([entry[@"anchor"] longLongValue], 0, length);
	const sptr_t caret = std::clamp<sptr_t>([entry[@"caret"] longLongValue], 0, length);
	SciCall(editor, SCI_SETSEL, anchor, caret);
	SciCall(editor, SCI_SETFIRSTVISIBLELINE, std::max<sptr_t>([entry[@"firstLine"] longLongValue], 0));
	if ([entry[@"bookmarks"] isKindOfClass: [NSArray class]]) {
		for (NSNumber *line in entry[@"bookmarks"]) {
			if ([line isKindOfClass: [NSNumber class]])
				SciCall(editor, SCI_MARKERADD, line.longLongValue, kMarkerBookmark);
		}
	}
	[editorController refreshStatus];
	return document;
}

- (NSUInteger) restoreSession {
	if (![AppSettings shared].rememberSession) {
		[self removeSession];
		return 0;
	}
	NSData *data = [NSData dataWithContentsOfURL: [self sessionFile]];
	NSDictionary *session = data ? [NSPropertyListSerialization propertyListWithData: data options: NSPropertyListImmutable
	                                                                          format: nil error: nil] : nil;
	NSArray *windows = [session isKindOfClass: [NSDictionary class]] ? session[@"windows"] : nil;
	if (![windows isKindOfClass: [NSArray class]])
		return 0;

	_restoring = YES;
	NSUInteger count = 0;
	NSMutableSet<NSString *> *usedBackups = [NSMutableSet set];
	// Back to front, so that the frontmost window of the last session ends up in front again.
	for (NSDictionary *group in windows.reverseObjectEnumerator) {
		if (![group isKindOfClass: [NSDictionary class]] || ![group[@"tabs"] isKindOfClass: [NSArray class]])
			continue;
		const NSInteger selected = [group[@"selected"] integerValue];
		NSWindow *previous = nil;
		NSWindow *front = nil;
		NSInteger index = 0;
		for (NSDictionary *entry in group[@"tabs"]) {
			Document *document = [entry isKindOfClass: [NSDictionary class]] ? [self openEntry: entry] : nil;
			NSWindow *window = document.editorController.window;
			if (window) {
				if (document.hasRestoredUnsavedText)
					[usedBackups addObject: [self backupURLForID: document.sessionID].lastPathComponent];
				if (!previous) {
					// The first tab opens as a window of its own, not as a tab of another group.
					NSRect frame = NSRectFromString(group[@"frame"] ?: @"");
					for (NSScreen *screen in NSScreen.screens) {
						if (NSWidth(frame) >= 200 && NSHeight(frame) >= 150 && NSIntersectsRect(frame, screen.visibleFrame)) {
							[window setFrame: frame display: NO];
							break;
						}
					}
					window.tabbingMode = NSWindowTabbingModeDisallowed;
					[window makeKeyAndOrderFront: nil];
					window.tabbingMode = NSWindowTabbingModePreferred;
				} else {
					[previous addTabbedWindow: window ordered: NSWindowAbove];
				}
				if (index == selected || !front)
					front = window;
				previous = window;
				++count;
			}
			++index;
		}
		[front makeKeyAndOrderFront: nil];
	}
	_restoring = NO;

	// Backups that no restored document claims are leftovers.
	NSFileManager *files = [NSFileManager defaultManager];
	for (NSURL *url in [files contentsOfDirectoryAtURL: [self backupDirectory] includingPropertiesForKeys: nil options: 0 error: nil]) {
		if (![usedBackups containsObject: url.lastPathComponent])
			[files removeItemAtURL: url error: nil];
	}
	return count;
}

@end
