// Tests of the iOS app, run in the app on a simulator: `make ios-test`.
// This file is part of MacPad (GPL v3 or later).
#import <XCTest/XCTest.h>

#import "Common.h"
#import "EditorSettings.h"
#import "EditorTextView.h"
#import "EditorViewController.h"
#import "TextDocument.h"

#include "Highlighter.h"
#include "LanguageCatalog.h"
#include "SciLexer.h"
#include "TextEncoding.h"
#include "TextTools.h"
#include "Theme.h"

@interface MacPadTests : XCTestCase
@end

@implementation MacPadTests

- (NSURL *) writeFile: (NSString *) name bytes: (NSData *) data {
	NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent: [NSUUID UUID].UUIDString];
	[[NSFileManager defaultManager] createDirectoryAtPath: directory withIntermediateDirectories: YES attributes: nil error: nil];
	NSURL *url = [NSURL fileURLWithPath: [directory stringByAppendingPathComponent: name]];
	[data writeToURL: url atomically: YES];
	return url;
}

- (void) spin {
	[[NSRunLoop mainRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: 0.05]];
}

- (TextDocument *) openDocument: (NSURL *) url {
	TextDocument *document = [[TextDocument alloc] initWithFileURL: url];
	XCTestExpectation *opened = [self expectationWithDescription: @"open"];
	[document openWithCompletionHandler: ^(BOOL success) {
		XCTAssertTrue(success);
		[opened fulfill];
	}];
	[self waitForExpectations: @[opened] timeout: 5];
	return document;
}

- (void) closeDocument: (TextDocument *) document {
	XCTestExpectation *closed = [self expectationWithDescription: @"close"];
	[document closeWithCompletionHandler: ^(BOOL success) {
		[closed fulfill];
	}];
	[self waitForExpectations: @[closed] timeout: 5];
}

#pragma mark - Shared core

- (void) testLanguagesAreLoaded {
	const LanguageCatalog &catalog = LanguageCatalog::Shared();
	XCTAssertGreaterThan(catalog.All().size(), 90u);
	XCTAssertEqual(catalog.All().front().name, std::string("normal"));
	XCTAssertTrue(catalog.Find("python") != nullptr);
}

- (void) testLanguageDetection {
	const LanguageCatalog &catalog = LanguageCatalog::Shared();
	XCTAssertEqual(catalog.Detect("main.swift", "").name, std::string("swift"));
	XCTAssertEqual(catalog.Detect("Makefile", "").name, std::string("makefile"));
	XCTAssertEqual(catalog.Detect("notes.md", "").name, std::string("markdown"));
	XCTAssertEqual(catalog.Detect("run", "#!/usr/bin/env python3\nprint(1)\n").name, std::string("python"));
	XCTAssertEqual(catalog.Detect("data", "<?xml version=\"1.0\"?>\n").name, std::string("xml"));
	XCTAssertEqual(catalog.Detect("App.m", "#import <UIKit/UIKit.h>\n").name, std::string("objc"));
	XCTAssertEqual(catalog.Detect("readme.txt", "hello").name, std::string("normal"));
}

- (void) testThemesLoad {
	EditorSettings *settings = [EditorSettings shared];
	settings.themeName = kAutomaticTheme;
	NSArray<NSString *> *themes = [settings availableThemes];
	XCTAssertGreaterThanOrEqual(themes.count, 10u);
	for (NSString *name in themes) {
		NSString *path = [[[NSBundle mainBundle].resourcePath stringByAppendingPathComponent: @"themes"]
			stringByAppendingPathComponent: [name stringByAppendingPathExtension: @"json"]];
		std::shared_ptr<Theme> theme = Theme::LoadFromFile(ToStdString(path));
		XCTAssertTrue(theme != nullptr, @"%@", name);
		XCTAssertNotEqual(theme->Style(StyleRole::Keyword).color, theme->Background(), @"%@", name);
		// Roles a theme leaves out borrow from related ones.
		XCTAssertEqual(theme->Style(StyleRole::CommentDocKeyword).italic, YES, @"%@", name);
	}
	XCTAssertTrue([settings themeForDarkAppearance: YES]->IsDark());
	XCTAssertFalse([settings themeForDarkAppearance: NO]->IsDark());
}

- (void) testHighlighting {
	const Language *python = LanguageCatalog::Shared().Find("python");
	const std::string text = "def f(x):\n    return 'a' + 1  # done\n";
	const std::vector<unsigned char> styles = StyleText(text, *python);
	XCTAssertEqual(styles.size(), text.size());
	XCTAssertEqual(styles[text.find("def")], SCE_P_WORD);
	XCTAssertEqual(styles[text.find("return")], SCE_P_WORD);
	XCTAssertEqual(styles[text.find("'a'")], SCE_P_CHARACTER);
	XCTAssertEqual(styles[text.find("1")], SCE_P_NUMBER);
	XCTAssertEqual(styles[text.find("# done")], SCE_P_COMMENTLINE);
	const std::vector<StyleRole> *roles = StyleMap::Shared().RolesForLexer("python");
	XCTAssertTrue(roles && (*roles)[SCE_P_WORD] == StyleRole::Keyword && (*roles)[SCE_P_COMMENTLINE] == StyleRole::Comment);
}

- (void) testEncodings {
	NSString *french = @"Café crème brûlée, naïve déjà vu. À bientôt, été à la forêt.\n";
	std::string utf8;
	FileEncoding encoding;
	XCTAssertTrue(DecodeText([french dataUsingEncoding: NSWindowsCP1252StringEncoding], utf8, encoding));
	XCTAssertEqual(encoding.kind, FileEncoding::Legacy);
	XCTAssertEqualObjects(ToNSString(utf8), french);

	NSString *japanese = @"日本語のテキストです。これは文字コードの検出テストです。東京都の天気は晴れです。\n";
	XCTAssertTrue(DecodeText([japanese dataUsingEncoding: NSShiftJISStringEncoding], utf8, encoding));
	XCTAssertEqualObjects(ToNSString(utf8), japanese);

	NSError *error = nil;
	XCTAssertNil(EncodeText("\xE6\x97\xA5", FileEncoding::MakeLegacy(kCFStringEncodingWindowsLatin1), &error));
	XCTAssertNotNil(error, @"a character the encoding cannot store is an error, not silently dropped");
}

- (void) testLineOperationsAndTools {
	std::vector<std::string> lines = SplitLines("b\na\nb\n\nc");
	ApplyLineOperation(lines, LineOperation::RemoveDuplicates, 4);
	ApplyLineOperation(lines, LineOperation::RemoveEmpty, 4);
	ApplyLineOperation(lines, LineOperation::SortAscending, 4);
	XCTAssertEqual(JoinLines(lines, "\n"), std::string("a\nb\nc"));

	std::string formatted, message;
	XCTAssertTrue(FormatJSON("{\"a\":[1,2]}", false, "  ", "\n", formatted, message));
	XCTAssertEqual(formatted, std::string("{\n  \"a\": [\n    1,\n    2\n  ]\n}"));
	XCTAssertEqual(HashHex("abc", HashAlgorithm::SHA256), std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
}

#pragma mark - Editor

- (void) testEditorColoursAndTyping {
	[EditorSettings shared].themeName = @"Light";
	[EditorSettings shared].autoIndent = YES;
	[EditorSettings shared].autoClose = YES;
	[EditorSettings shared].useSpaces = YES;
	[EditorSettings shared].tabWidth = 4;
	NSURL *url = [self writeFile: @"sample.py" bytes: [@"def f():\n    return 1\n" dataUsingEncoding: NSUTF8StringEncoding]];
	TextDocument *document = [self openDocument: url];
	XCTAssertEqual(document.language->name, std::string("python"));

	EditorViewController *editor = [[EditorViewController alloc] initWithDocument: document];
	UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController: editor];
	UIWindow *window = [[UIWindow alloc] initWithFrame: CGRectMake(0, 0, 390, 844)];
	window.rootViewController = navigation;
	[window makeKeyAndVisible];
	[editor loadViewIfNeeded];
	[editor highlightNow];

	EditorTextView *textView = editor.textView;
	UIColor *keyword = [textView.textStorage attribute: NSForegroundColorAttributeName atIndex: 0 effectiveRange: nil];
	std::shared_ptr<Theme> theme = [[EditorSettings shared] themeForDarkAppearance: NO];
	XCTAssertEqualObjects(keyword, ColorFromRGB(theme->Style(StyleRole::Keyword).color), @"'def' has the keyword colour");
	UIColor *name = [textView.textStorage attribute: NSForegroundColorAttributeName atIndex: 4 effectiveRange: nil];
	XCTAssertEqualObjects(name, ColorFromRGB(theme->Style(StyleRole::Function).color), @"'f' has the function name colour");
	UIColor *number = [textView.textStorage attribute: NSForegroundColorAttributeName atIndex: 20 effectiveRange: nil];
	XCTAssertEqualObjects(number, ColorFromRGB(theme->Style(StyleRole::Number).color), @"'1' has the number colour");
	XCTAssertEqual([textView lineCount], 3u);

	// Return after "def f():" indents one level more than the line.
	textView.selectedRange = NSMakeRange(8, 0);
	XCTAssertFalse([editor textView: textView shouldChangeTextInRange: NSMakeRange(8, 0) replacementText: @"\n"]);
	XCTAssertEqualObjects(textView.text, @"def f():\n    \n    return 1\n");
	XCTAssertEqual(textView.selectedRange.location, 13u);
	[self spin];

	// An opening bracket closes itself; typing the closer steps over it.
	XCTAssertFalse([editor textView: textView shouldChangeTextInRange: NSMakeRange(13, 0) replacementText: @"("]);
	XCTAssertEqualObjects(textView.text, @"def f():\n    ()\n    return 1\n");
	[self spin];
	XCTAssertFalse([editor textView: textView shouldChangeTextInRange: NSMakeRange(14, 0) replacementText: @")"]);
	XCTAssertEqual(textView.selectedRange.location, 15u);
	XCTAssertEqualObjects(textView.text, @"def f():\n    ()\n    return 1\n");

	// Undo takes the last edit back.
	[textView.undoManager undo];
	[self spin];
	XCTAssertEqualObjects(textView.text, @"def f():\n    \n    return 1\n");

	[editor saveNow];
	[self closeDocument: document];
	NSString *saved = [NSString stringWithContentsOfURL: url encoding: NSUTF8StringEncoding error: nil];
	XCTAssertEqualObjects(saved, @"def f():\n    \n    return 1\n");
	window.hidden = YES;
}

- (void) testSavingKeepsEncodingAndLineEndings {
	NSData *bytes = [@"Olá, mundo!\r\nSegunda linha: ação.\r\n" dataUsingEncoding: NSWindowsCP1252StringEncoding];
	NSURL *url = [self writeFile: @"windows.txt" bytes: bytes];
	TextDocument *document = [self openDocument: url];
	XCTAssertEqual(document.lineEnding, LineEnding::CRLF);
	XCTAssertEqual(document.encoding.kind, FileEncoding::Legacy);
	XCTAssertEqualObjects(document.text, @"Olá, mundo!\nSegunda linha: ação.\n", @"edited with plain line breaks");

	[document textDidChange: [document.text stringByAppendingString: @"Mais uma.\n"]];
	[self closeDocument: document];
	NSData *saved = [NSData dataWithContentsOfURL: url];
	NSData *expected = [@"Olá, mundo!\r\nSegunda linha: ação.\r\nMais uma.\r\n" dataUsingEncoding: NSWindowsCP1252StringEncoding];
	XCTAssertEqualObjects(saved, expected, @"saved back as Windows-1252 with CR LF");
}

@end
