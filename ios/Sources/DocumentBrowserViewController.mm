// The Files browser the app starts with.
// This file is part of MacPad (GPL v3 or later).
#import "DocumentBrowserViewController.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "EditorViewController.h"
#import "TextDocument.h"

static NSString *const kLastDocumentKey = @"lastDocumentBookmark";

@interface DocumentBrowserViewController () <UIDocumentBrowserViewControllerDelegate>
@end

@implementation DocumentBrowserViewController
{
	EditorViewController *_currentEditor;
	NSURL *_securityScopedURL; // reopened from a bookmark: access must be released on close
}

- (instancetype) init {
	// Any file: plain text and source code, but also files without a known type (Makefile, .env).
	self = [super initForOpeningContentTypes: @[UTTypeText, UTTypeData]];
	if (self) {
		self.delegate = self;
		self.allowsDocumentCreation = YES;
		self.allowsPickingMultipleItems = NO;
	}
	return self;
}

- (EditorViewController *) currentEditor {
	return _currentEditor;
}

#pragma mark - Opening

- (void) presentDocumentAtURL: (NSURL *) url {
	if (!url)
		return;
	if (_currentEditor) {
		// Another document is open: close it first.
		EditorViewController *editor = _currentEditor;
		editor.closeHandler = nil;
		_currentEditor = nil;
		[editor saveNow];
		[editor.document closeWithCompletionHandler: ^(BOOL success) {
			[editor dismissViewControllerAnimated: NO completion: ^{
				[self presentDocumentAtURL: url];
			}];
		}];
		return;
	}

	TextDocument *document = [[TextDocument alloc] initWithFileURL: url];
	[document openWithCompletionHandler: ^(BOOL success) {
		if (!success) {
			[self stopAccessingReopenedURL];
			[self forgetLastDocument];
			UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"The document could not be opened"
			                                                               message: url.lastPathComponent
			                                                        preferredStyle: UIAlertControllerStyleAlert];
			[alert addAction: [UIAlertAction actionWithTitle: @"OK" style: UIAlertActionStyleCancel handler: nil]];
			[self presentViewController: alert animated: YES completion: nil];
			return;
		}
		EditorViewController *editor = [[EditorViewController alloc] initWithDocument: document];
		__weak DocumentBrowserViewController *weakSelf = self;
		editor.closeHandler = ^{
			DocumentBrowserViewController *strongSelf = weakSelf;
			if (!strongSelf)
				return;
			strongSelf->_currentEditor = nil;
			[strongSelf stopAccessingReopenedURL];
			[strongSelf forgetLastDocument];
		};
		UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController: editor];
		navigation.modalPresentationStyle = UIModalPresentationFullScreen;
		self->_currentEditor = editor;
		[self rememberLastDocument: url];
		[self presentViewController: navigation animated: YES completion: nil];
	}];
}

- (void) rememberLastDocument: (NSURL *) url {
	NSData *bookmark = [url bookmarkDataWithOptions: 0 includingResourceValuesForKeys: nil relativeToURL: nil error: nil];
	if (bookmark)
		[[NSUserDefaults standardUserDefaults] setObject: bookmark forKey: kLastDocumentKey];
}

- (void) forgetLastDocument {
	[[NSUserDefaults standardUserDefaults] removeObjectForKey: kLastDocumentKey];
}

- (void) stopAccessingReopenedURL {
	[_securityScopedURL stopAccessingSecurityScopedResource];
	_securityScopedURL = nil;
}

- (void) reopenLastDocument {
	NSData *bookmark = [[NSUserDefaults standardUserDefaults] dataForKey: kLastDocumentKey];
	if (!bookmark || _currentEditor)
		return;
	BOOL stale = NO;
	NSURL *url = [NSURL URLByResolvingBookmarkData: bookmark options: NSURLBookmarkResolutionWithoutUI relativeToURL: nil
	                           bookmarkDataIsStale: &stale error: nil];
	if (!url) {
		[self forgetLastDocument];
		return;
	}
	if ([url startAccessingSecurityScopedResource])
		_securityScopedURL = url;
	[self presentDocumentAtURL: url];
}

#pragma mark - UIDocumentBrowserViewControllerDelegate

- (void) documentBrowser: (UIDocumentBrowserViewController *) controller didPickDocumentsAtURLs: (NSArray<NSURL *> *) urls {
	[self presentDocumentAtURL: urls.firstObject];
}

- (void) documentBrowser: (UIDocumentBrowserViewController *) controller
didRequestDocumentCreationWithHandler: (void (^)(NSURL *, UIDocumentBrowserImportMode)) importHandler {
	// An empty text file, moved by the browser to the folder the user is looking at.
	NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent: [NSUUID UUID].UUIDString];
	[[NSFileManager defaultManager] createDirectoryAtPath: directory withIntermediateDirectories: YES attributes: nil error: nil];
	NSURL *url = [NSURL fileURLWithPath: [directory stringByAppendingPathComponent: @"Untitled.txt"]];
	if (![[NSData data] writeToURL: url atomically: YES]) {
		importHandler(nil, UIDocumentBrowserImportModeNone);
		return;
	}
	importHandler(url, UIDocumentBrowserImportModeMove);
}

- (void) documentBrowser: (UIDocumentBrowserViewController *) controller
didImportDocumentAtURL: (NSURL *) sourceURL
    toDestinationURL: (NSURL *) destinationURL {
	[self presentDocumentAtURL: destinationURL];
}

- (void) documentBrowser: (UIDocumentBrowserViewController *) controller
failedToImportDocumentAtURL: (NSURL *) documentURL
                 error: (NSError *) error {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"The document could not be created"
	                                                               message: error.localizedDescription
	                                                        preferredStyle: UIAlertControllerStyleAlert];
	[alert addAction: [UIAlertAction actionWithTitle: @"OK" style: UIAlertActionStyleCancel handler: nil]];
	[self presentViewController: alert animated: YES completion: nil];
}

@end
