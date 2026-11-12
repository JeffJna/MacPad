// A text file opened on iOS.
// This file is part of MacPad (GPL v3 or later).
#import "TextDocument.h"

#import "Common.h"

#include "FileConflicts.h"
#include "LanguageCatalog.h"

@implementation TextDocument
{
	NSData *_bytes; // the file as last read, for Reopen with Encoding
	BOOL _loaded;
	BOOL _keepingVersions;
}

- (instancetype) initWithFileURL: (NSURL *) url {
	self = [super initWithFileURL: url];
	if (self) {
		_text = @"";
		_encoding = FileEncoding::Make(FileEncoding::UTF8);
		_lineEnding = LineEnding::LF;
		_language = &LanguageCatalog::Shared().NormalText();
		[[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(stateDidChange:)
		                                             name: UIDocumentStateChangedNotification object: self];
	}
	return self;
}

- (void) dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self];
}

// Saved on two devices at once (iCloud Drive): keep this version open and the others beside
// it, or in On My iPhone › MacPad when Files gave access to this file only.
- (void) stateDidChange: (NSNotification *) notification {
	if (!(self.documentState & UIDocumentStateInConflict) || _keepingVersions || !self.fileURL)
		return;
	_keepingVersions = YES;
	NSURL *url = self.fileURL;
	NSURL *ownFolder = [[NSFileManager defaultManager] URLsForDirectory: NSDocumentDirectory inDomains: NSUserDomainMask].firstObject;
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray<NSURL *> *copies = KeepVersionsInConflict(url, ownFolder);
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_keepingVersions = NO;
			if (copies.count && self.conflictHandler)
				self.conflictHandler(copies);
		});
	});
}

- (void) acceptBytes: (NSData *) data forcing: (const FileEncoding *) forced {
	std::string utf8;
	FileEncoding encoding;
	DecodeText(data, utf8, encoding, forced);
	_encoding = encoding;
	_lineEnding = DetectLineEnding(utf8, LineEnding::LF);
	if (!_languageChosenByUser)
		_language = &LanguageCatalog::Shared().Detect(ToStdString(self.fileURL.lastPathComponent ?: @""), utf8.substr(0, 4096));
	NSString *text = ToNSString(utf8);
	text = [text stringByReplacingOccurrencesOfString: @"\r\n" withString: @"\n"];
	_text = [text stringByReplacingOccurrencesOfString: @"\r" withString: @"\n"];
}

- (BOOL) loadFromContents: (id) contents ofType: (NSString *) typeName error: (NSError **) outError {
	if (![contents isKindOfClass: [NSData class]]) {
		if (outError)
			*outError = [NSError errorWithDomain: NSCocoaErrorDomain code: NSFileReadUnknownError
			                            userInfo: @{NSLocalizedDescriptionKey: @"This is a folder or a package, not a text file."}];
		return NO;
	}
	_bytes = contents;
	[self acceptBytes: contents forcing: nullptr];
	if (_loaded && self.reloadHandler) {
		void (^handler)(void) = self.reloadHandler;
		dispatch_async(dispatch_get_main_queue(), handler);
	}
	_loaded = YES;
	return YES;
}

- (id) contentsForType: (NSString *) typeName error: (NSError **) outError {
	NSString *eol = _lineEnding == LineEnding::CRLF ? @"\r\n" : (_lineEnding == LineEnding::CR ? @"\r" : @"\n");
	NSString *text = [eol isEqualToString: @"\n"] ? _text : [_text stringByReplacingOccurrencesOfString: @"\n" withString: eol];
	NSData *data = EncodeText(ToStdString(text), _encoding, outError);
	if (data)
		_bytes = data;
	return data;
}

- (void) textDidChange: (NSString *) text {
	_text = [text copy];
	[self updateChangeCount: UIDocumentChangeDone];
}

- (void) setEncoding: (FileEncoding) encoding {
	_encoding = encoding;
	[self updateChangeCount: UIDocumentChangeDone];
}

- (void) setLineEnding: (LineEnding) lineEnding {
	_lineEnding = lineEnding;
	[self updateChangeCount: UIDocumentChangeDone];
}

- (void) reinterpretWithEncoding: (FileEncoding) encoding {
	if (!_bytes)
		return;
	[self acceptBytes: _bytes forcing: &encoding];
	[self updateChangeCount: UIDocumentChangeCleared];
}

- (void) handleError: (NSError *) error userInteractionPermitted: (BOOL) userInteractionPermitted {
	void (^handler)(NSError *) = self.saveErrorHandler;
	if (handler)
		dispatch_async(dispatch_get_main_queue(), ^{ handler(error); });
	[self finishedHandlingError: error recovered: NO];
}

@end
