// A text file: encoding, line endings and language, loaded and saved through NSDocument.
// This file is part of MacPad (GPL v3 or later).
#import "Document.h"

#include <algorithm>
#include <cmath>
#include <fcntl.h>
#include <unistd.h>

#import "AppSettings.h"
#import "EditorWindowController.h"
#import "SciUtil.h"
#import "SessionManager.h"

#include "LanguageCatalog.h"

static NSInteger gUntitledCounter = 0;

// Scintilla is built with 32-bit document positions.
static const unsigned long long kMaxFileSize = 0x7FFFFFFFull - 0x1000;
static const size_t kLargeFileSize = 64 * 1024 * 1024;

@implementation Document
{
	std::string _loadedText;
	BOOL _externalChangePromptVisible;
	BOOL _saving;
	dispatch_source_t _fileWatcher;
}

@synthesize untitledNumber = _untitledNumber;

+ (BOOL) autosavesInPlace {
	// Classic editor behaviour: explicit saves and a dirty marker, no autosave over the file.
	return NO;
}

- (instancetype) init {
	self = [super init];
	if (self) {
		self.hasUndoManager = NO; // Scintilla keeps its own undo history
		_encoding = FileEncoding::Make(FileEncoding::UTF8);
		_lineEnding = LineEnding::LF;
		_language = &LanguageCatalog::Shared().NormalText();
	}
	return self;
}

#pragma mark - Name

- (NSInteger) untitledNumber {
	if (_untitledNumber == 0)
		_untitledNumber = ++gUntitledCounter;
	return _untitledNumber;
}

- (void) setUntitledNumber: (NSInteger) number {
	_untitledNumber = number;
	gUntitledCounter = std::max(gUntitledCounter, number);
}

// Always the full file name: an editor should not hide extensions the way Finder may.
- (NSString *) displayName {
	if (self.fileURL)
		return self.fileURL.lastPathComponent ?: [super displayName];
	return [NSString stringWithFormat: @"new %ld", (long)self.untitledNumber];
}

- (NSString *) sessionID {
	if (!_sessionID)
		_sessionID = [NSUUID UUID].UUIDString;
	return _sessionID;
}

#pragma mark - Windows

- (void) makeWindowControllers {
	[self addWindowController: [[EditorWindowController alloc] init]];
}

- (EditorWindowController *) editorController {
	for (NSWindowController *controller in self.windowControllers) {
		if ([controller isKindOfClass: [EditorWindowController class]])
			return (EditorWindowController *)controller;
	}
	return nil;
}

- (std::string) takeLoadedText {
	std::string text;
	text.swap(_loadedText);
	return text;
}

#pragma mark - Unsaved changes

- (BOOL) hasUnsavedChanges {
	return [super isDocumentEdited];
}

- (BOOL) isDocumentEdited {
	if ([SessionManager shared].terminating)
		return NO;
	return [super isDocumentEdited];
}

- (void) updateChangeCount: (NSDocumentChangeType) change {
	[super updateChangeCount: change];
	[[SessionManager shared] documentStateDidChange];
}

#pragma mark - Reading

- (void) acceptText: (std::string &) text encoding: (const FileEncoding &) encoding fromURL: (NSURL *) url {
	_encoding = encoding;
	_lineEnding = DetectLineEnding(text, LineEnding::LF);
	_largeFile = text.size() > kLargeFileSize;
	_hasRestoredUnsavedText = NO;
	if (!_languageChosenByUser) {
		if (_largeFile) {
			_language = &LanguageCatalog::Shared().NormalText();
		} else {
			_language = &LanguageCatalog::Shared().Detect(ToStdString(url.lastPathComponent ?: @""), text.substr(0, 4096));
		}
	}

	EditorWindowController *editor = self.editorController;
	if (editor) {
		[editor loadText: text keepPosition: YES];
		[editor applyLanguage];
	} else {
		_loadedText.swap(text);
	}
}

- (BOOL) readFromURL: (NSURL *) url ofType: (NSString *) typeName error: (NSError **) outError {
	NSNumber *isDirectory = nil;
	[url getResourceValue: &isDirectory forKey: NSURLIsDirectoryKey error: nil];
	NSNumber *size = nil;
	[url getResourceValue: &size forKey: NSURLFileSizeKey error: nil];
	if (isDirectory.boolValue || size.unsignedLongLongValue > kMaxFileSize) {
		if (outError) {
			NSString *reason = isDirectory.boolValue ? @"It is a folder, not a text file."
			                                         : @"Files larger than 2 GB cannot be opened.";
			*outError = [NSError errorWithDomain: NSCocoaErrorDomain
			                                code: NSFileReadTooLargeError
			                            userInfo: @{NSLocalizedDescriptionKey: [NSString stringWithFormat:
			                                            @"“%@” could not be opened.", url.lastPathComponent],
			                                        NSLocalizedRecoverySuggestionErrorKey: reason}];
		}
		return NO;
	}

	NSData *data = [NSData dataWithContentsOfURL: url options: NSDataReadingMappedIfSafe error: outError];
	if (!data)
		return NO;
	std::string text;
	FileEncoding encoding;
	if (!DecodeText(data, text, encoding)) {
		if (outError)
			*outError = [NSError errorWithDomain: NSCocoaErrorDomain code: NSFileReadInapplicableStringEncodingError userInfo: nil];
		return NO;
	}
	[self acceptText: text encoding: encoding fromURL: url];
	return YES;
}

- (void) reopenWithEncoding: (FileEncoding) forced {
	NSURL *url = self.fileURL;
	if (!url)
		return;

	void (^reload)(void) = ^{
		NSError *error = nil;
		NSData *data = [NSData dataWithContentsOfURL: url options: 0 error: &error];
		if (!data) {
			[self presentError: error];
			return;
		}
		std::string text;
		FileEncoding encoding;
		DecodeText(data, text, encoding, &forced);
		[self acceptText: text encoding: encoding fromURL: url];
		[self updateChangeCount: NSChangeCleared];
	};

	if (!self.isDocumentEdited) {
		reload();
		return;
	}
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat: @"Reopen “%@” with a different encoding?", self.displayName];
	alert.informativeText = @"Your unsaved changes will be lost.";
	[alert addButtonWithTitle: @"Reopen"];
	[alert addButtonWithTitle: @"Cancel"];
	[alert beginSheetModalForWindow: self.windowForSheet completionHandler: ^(NSModalResponse response) {
		if (response == NSAlertFirstButtonReturn)
			reload();
	}];
}

#pragma mark - Writing

- (NSData *) dataOfType: (NSString *) typeName error: (NSError **) outError {
	EditorWindowController *editor = self.editorController;
	const std::string text = editor ? [editor documentText] : _loadedText;
	return EncodeText(text, _encoding, outError);
}

// Any name and extension can be typed. A new document is offered the usual extension
// of its language ("new 1.py"), and an existing one its full file name.
- (BOOL) prepareSavePanel: (NSSavePanel *) savePanel {
	savePanel.allowedContentTypes = @[];
	savePanel.allowsOtherFileTypes = YES;
	savePanel.extensionHidden = NO;
	if (self.fileURL) {
		savePanel.nameFieldStringValue = self.fileURL.lastPathComponent;
	} else {
		NSString *extension = _language->extensions.empty() ? @"txt" : ToNSString(_language->extensions.front());
		savePanel.nameFieldStringValue = [self.displayName stringByAppendingPathExtension: extension];
	}
	return YES;
}

- (void) saveToURL: (NSURL *) url
            ofType: (NSString *) typeName
  forSaveOperation: (NSSaveOperationType) saveOperation
 completionHandler: (void (^)(NSError *)) completionHandler {
	NSURL *previousURL = self.fileURL;
	if (saveOperation != NSSaveToOperation && [AppSettings shared].trimTrailingOnSave)
		[self.editorController trimTrailingWhitespaceInDocument];
	_saving = YES;
	[super saveToURL: url ofType: typeName forSaveOperation: saveOperation completionHandler: ^(NSError *error) {
		self->_saving = NO;
		[self startWatchingFile]; // a safe save replaces the file, so watch the new one
		if (!error && saveOperation != NSSaveToOperation) {
			EditorWindowController *editor = self.editorController;
			self.hasRestoredUnsavedText = NO;
			[editor markSavePoint];
			[self updateChangeCount: NSChangeCleared];
			// "Save As" with a new extension picks the matching language.
			if (!self.languageChosenByUser && ![previousURL isEqual: self.fileURL]) {
				const std::string firstLine;
				self.language = &LanguageCatalog::Shared().Detect(ToStdString(self.fileURL.lastPathComponent ?: @""), firstLine);
				[editor applyLanguage];
			}
			[editor documentDidSave];
		}
		completionHandler(error);
	}];
}

#pragma mark - Printing

- (NSPrintOperation *) printOperationWithSettings: (NSDictionary<NSPrintInfoAttributeKey, id> *) printSettings
                                            error: (NSError **) outError {
	NSPrintInfo *info = [self.printInfo copy];
	[info.dictionary addEntriesFromDictionary: printSettings];
	info.horizontalPagination = NSPrintingPaginationModeFit;
	info.verticalPagination = NSPrintingPaginationModeAutomatic;
	info.verticallyCentered = NO;
	info.horizontallyCentered = NO;
	NSView *view = [self.editorController printableViewForPrintInfo: info];
	NSPrintOperation *operation = [NSPrintOperation printOperationWithView: view printInfo: info];
	operation.jobTitle = self.displayName;
	return operation;
}

#pragma mark - Changes made by other programs

// File presenter notifications only cover coordinated writes, so the file itself is
// watched too: writes in place, and deletes/renames from editors that save atomically.
- (void) setFileURL: (NSURL *) fileURL {
	[super setFileURL: fileURL];
	[self startWatchingFile];
	[[SessionManager shared] documentStateDidChange];
}

- (void) close {
	[self stopWatchingFile];
	[super close];
	[[SessionManager shared] documentDidClose: self];
}

- (void) stopWatchingFile {
	if (_fileWatcher) {
		dispatch_source_cancel(_fileWatcher);
		_fileWatcher = nil;
	}
}

- (void) startWatchingFile {
	[self stopWatchingFile];
	NSURL *url = self.fileURL;
	if (!url)
		return;
	const int fd = open(url.fileSystemRepresentation, O_EVTONLY);
	if (fd < 0)
		return;
	dispatch_source_t watcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, static_cast<uintptr_t>(fd),
	                                                   DISPATCH_VNODE_WRITE | DISPATCH_VNODE_EXTEND | DISPATCH_VNODE_DELETE |
	                                                   DISPATCH_VNODE_RENAME,
	                                                   dispatch_get_main_queue());
	__weak Document *weakSelf = self;
	__weak dispatch_source_t weakWatcher = watcher;
	dispatch_source_set_event_handler(watcher, ^{
		Document *strongSelf = weakSelf;
		dispatch_source_t source = weakWatcher;
		if (!strongSelf || !source)
			return;
		if (dispatch_source_get_data(source) & (DISPATCH_VNODE_DELETE | DISPATCH_VNODE_RENAME)) {
			// The file was replaced: follow the new one once the other program is done.
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
				[strongSelf startWatchingFile];
				[strongSelf checkForExternalChange];
			});
		} else {
			[NSObject cancelPreviousPerformRequestsWithTarget: strongSelf selector: @selector(checkForExternalChange) object: nil];
			[strongSelf performSelector: @selector(checkForExternalChange) withObject: nil afterDelay: 0.25];
		}
	});
	dispatch_source_set_cancel_handler(watcher, ^{
		close(fd);
	});
	_fileWatcher = watcher;
	dispatch_resume(watcher);
}

- (void) presentedItemDidChange {
	[super presentedItemDidChange];
	dispatch_async(dispatch_get_main_queue(), ^{
		[self checkForExternalChange];
	});
}

- (void) checkForExternalChange {
	NSURL *url = self.fileURL;
	NSDate *known = self.fileModificationDate;
	if (!url || !known || _externalChangePromptVisible || _saving)
		return;
	NSDate *onDisk = [[NSFileManager defaultManager] attributesOfItemAtPath: url.path error: nil].fileModificationDate;
	if (!onDisk || std::fabs([onDisk timeIntervalSinceDate: known]) < 0.001)
		return;

	if (!self.isDocumentEdited) {
		[self reloadFromDisk];
		return;
	}
	NSWindow *window = self.windowForSheet;
	if (!window || window.attachedSheet)
		return; // ask again when the window comes back to the front

	_externalChangePromptVisible = YES;
	NSAlert *alert = [[NSAlert alloc] init];
	alert.messageText = [NSString stringWithFormat: @"“%@” has been modified by another program.", self.displayName];
	alert.informativeText = @"Do you want to reload it and lose the changes made here?";
	[alert addButtonWithTitle: @"Reload"];
	[alert addButtonWithTitle: @"Keep My Version"];
	[alert beginSheetModalForWindow: window completionHandler: ^(NSModalResponse response) {
		self->_externalChangePromptVisible = NO;
		if (response == NSAlertFirstButtonReturn)
			[self reloadFromDisk];
		else
			self.fileModificationDate = onDisk; // saving later overwrites without another warning
	}];
}

- (void) reloadFromDisk {
	NSError *error = nil;
	if (![self revertToContentsOfURL: self.fileURL ofType: self.fileType error: &error] && error)
		[self presentError: error];
}

@end
