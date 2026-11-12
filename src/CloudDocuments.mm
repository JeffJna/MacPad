// iCloud Drive on the Mac: new documents there, and saving a moment after each change.
// This file is part of MacPad (GPL v3 or later).
#import "CloudDocuments.h"

#include <algorithm>

#import "AppSettings.h"
#import "Document.h"
#import "EditorWindowController.h"
#import "SciUtil.h"

#include "LanguageCatalog.h"

// A pause in typing: long enough not to save on every key.
static const NSTimeInterval kSaveDelay = 2.0;

// Where iCloud Drive lives on the Mac (Finder shows it as "iCloud Drive").
static NSString *MobileDocumentsPath()
{
	return [NSHomeDirectory() stringByAppendingPathComponent: @"Library/Mobile Documents"];
}

static NSString *ICloudDrivePath()
{
	return [MobileDocumentsPath() stringByAppendingPathComponent: @"com~apple~CloudDocs"];
}

static BOOL PathIsInside(NSString *path, NSString *folder)
{
	path = path.stringByStandardizingPath;
	folder = folder.stringByStandardizingPath;
	return [path.lowercaseString hasPrefix: [folder.lowercaseString stringByAppendingString: @"/"]];
}

@implementation CloudDocuments
{
	NSURL *_testFolder;
}

+ (instancetype) shared {
	static CloudDocuments *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		shared = [[CloudDocuments alloc] init];
	});
	return shared;
}

+ (BOOL) iCloudDriveAvailable {
	BOOL directory = NO;
	return [[NSFileManager defaultManager] fileExistsAtPath: ICloudDrivePath() isDirectory: &directory] && directory;
}

+ (BOOL) isInICloud: (NSURL *) url {
	if (!url.isFileURL)
		return NO;
	NSURL *testFolder = [CloudDocuments shared]->_testFolder;
	if (testFolder)
		return PathIsInside(url.path, testFolder.path);
	if (PathIsInside(url.path, MobileDocumentsPath()))
		return YES;
	NSNumber *ubiquitous = nil;
	[url getResourceValue: &ubiquitous forKey: NSURLIsUbiquitousItemKey error: nil];
	return ubiquitous.boolValue;
}

- (NSArray<Document *> *) documents {
	NSMutableArray<Document *> *documents = [NSMutableArray array];
	for (NSDocument *document in [NSDocumentController sharedDocumentController].documents) {
		if ([document isKindOfClass: [Document class]])
			[documents addObject: (Document *)document];
	}
	return documents;
}

#pragma mark - On and off

- (void) start {
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	[center addObserver: self selector: @selector(update) name: AppSettingsDidChangeNotification object: nil];
	// iCloud Drive may be turned on or off in System Settings while MacPad runs.
	[center addObserver: self selector: @selector(update) name: NSApplicationDidBecomeActiveNotification object: nil];
	[self update];
}

- (void) update {
	const BOOL wasActive = _active;
	if (_testFolder) {
		_folderURL = _testFolder;
		_active = [AppSettings shared].syncWithICloud;
	} else if (NSProcessInfo.processInfo.environment[@"MACPAD_SELFTEST"]) {
		_active = NO; // the self test never touches the real iCloud Drive (see useFolderForTesting:)
	} else {
		_folderURL = [NSURL fileURLWithPath: [ICloudDrivePath() stringByAppendingPathComponent: @"MacPad"] isDirectory: YES];
		_active = [AppSettings shared].syncWithICloud && CloudDocuments.iCloudDriveAvailable;
	}
	if (_active && !wasActive) {
		[[NSFileManager defaultManager] createDirectoryAtURL: _folderURL withIntermediateDirectories: YES attributes: nil error: nil];
		for (Document *document in [self documents]) {
			if (document.hasUnsavedChanges)
				[self documentTextDidChange: document]; // changes made while it was off
		}
	} else if (!_active) {
		[NSObject cancelPreviousPerformRequestsWithTarget: self];
	}
}

- (void) useFolderForTesting: (NSURL *) folder {
	_testFolder = folder;
	if (!folder) {
		_active = NO;
		[NSObject cancelPreviousPerformRequestsWithTarget: self];
		return;
	}
	[self update];
}

#pragma mark - Saving

- (void) documentTextDidChange: (Document *) document {
	if (!_active)
		return;
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(saveDocument:) object: document];
	[self performSelector: @selector(saveDocument:) withObject: document afterDelay: kSaveDelay];
}

- (void) saveDocument: (Document *) document {
	if (!_active || ![[self documents] containsObject: document] || !document.hasUnsavedChanges)
		return;
	if (document.busyWithFile) {
		[self documentTextDidChange: document]; // try again in a moment
		return;
	}
	NSURL *url = document.fileURL;
	if (url) {
		if ([CloudDocuments isInICloud: url])
			[document saveAutomaticallyToURL: url operation: NSSaveOperation];
	} else if (document.editorController && ![document.editorController documentText].empty()) {
		// A new document becomes a file in iCloud Drive › MacPad, so that the iPhone sees it.
		[document saveAutomaticallyToURL: [self fileURLForNewDocument: document] operation: NSSaveAsOperation];
	}
}

// "new 3.txt", or "new 4.txt" when that name is taken; the extension follows the language.
- (NSURL *) fileURLForNewDocument: (Document *) document {
	const Language *language = document.language;
	NSString *extension = language->extensions.empty() ? @"txt" : ToNSString(language->extensions.front());
	NSFileManager *manager = [NSFileManager defaultManager];
	[manager createDirectoryAtURL: _folderURL withIntermediateDirectories: YES attributes: nil error: nil];
	for (NSInteger number = std::max<NSInteger>(1, document.untitledNumber);; ++number) {
		NSString *name = [[NSString stringWithFormat: @"new %ld", (long)number] stringByAppendingPathExtension: extension];
		// A file kept only in iCloud can show as ".name.icloud" until it is downloaded.
		NSString *placeholder = [NSString stringWithFormat: @".%@.icloud", name];
		if (![manager fileExistsAtPath: [_folderURL.path stringByAppendingPathComponent: name]] &&
		    ![manager fileExistsAtPath: [_folderURL.path stringByAppendingPathComponent: placeholder]])
			return [_folderURL URLByAppendingPathComponent: name isDirectory: NO];
	}
}

- (void) saveDocumentsNow {
	if (!_active)
		return;
	[NSObject cancelPreviousPerformRequestsWithTarget: self];
	for (Document *document in [self documents]) {
		if (document.hasUnsavedChanges && document.fileURL && [CloudDocuments isInICloud: document.fileURL])
			[document saveBeforeQuitting];
	}
}

@end
