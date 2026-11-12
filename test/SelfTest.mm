// End-to-end self test of MacPad. `make test` links this file into a copy of the app; when
// MACPAD_SELFTEST=<output dir> is set it drives the real UI (documents, themes, Find/Replace,
// Find in Files, encodings, editing commands, macros, auto-completion, sessions, external
// file changes), writes log.txt and window screenshots to that directory, then exits with a
// non-zero status on failure.
// This file is part of MacPad (GPL v3 or later).
#import <Cocoa/Cocoa.h>
#include <dlfcn.h>

#import "AppSettings.h"
#import "CloudDocuments.h"
#import "Document.h"
#import "EditorWindowController.h"
#import "FindPanel.h"
#import "MacroRecorder.h"
#import "PreferencesWindow.h"
#import "SciUtil.h"
#import "SearchResultsPanel.h"
#import "SessionManager.h"

#include "FileConflicts.h"
#include "Highlighter.h"
#include "LanguageCatalog.h"
#include "SearchEngine.h"
#include "Theme.h"
#include "TextTools.h"

static NSString *gOut;
static FILE *gLog;
static int gFails;
static int gPasses;

#define LOG(fmt, ...) do { fprintf(gLog, fmt "\n", ##__VA_ARGS__); fflush(gLog); } while (0)
#define CHECK(cond, fmt, ...) do { if (cond) { gPasses++; LOG("PASS: " fmt, ##__VA_ARGS__); } else { gFails++; LOG("FAIL: " fmt, ##__VA_ARGS__); } } while (0)

static void Pump(double seconds) {
	[[NSRunLoop currentRunLoop] runUntilDate: [NSDate dateWithTimeIntervalSinceNow: seconds]];
}

// Real on-screen pixels of one of our own windows (title bar and tabs included).
typedef CGImageRef (*WindowImageFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
static void WindowShot(NSWindow *window, NSString *name) {
	static WindowImageFn fn = (WindowImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
	if (!fn) { LOG("no CGWindowListCreateImage"); return; }
	CGImageRef image = fn(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)window.windowNumber,
	                      kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
	if (!image) { LOG("window capture failed for %s", name.UTF8String); return; }
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage: image];
	CGImageRelease(image);
	NSData *png = [rep representationUsingType: NSBitmapImageFileTypePNG properties: @{}];
	[png writeToFile: [gOut stringByAppendingPathComponent: [name stringByAppendingPathExtension: @"png"]] atomically: YES];
}

static Document *Open(NSString *path) {
	__block Document *result = nil;
	__block BOOL done = NO;
	[[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL: [NSURL fileURLWithPath: path] display: YES
	                                                            completionHandler: ^(NSDocument *document, BOOL wasOpen, NSError *error) {
		result = (Document *)document;
		if (error)
			LOG("open error %s", error.description.UTF8String);
		done = YES;
	}];
	for (int i = 0; i < 200 && !done; ++i)
		Pump(0.05);
	Pump(0.3);
	return result;
}

static Document *NewDocument() {
	Document *doc = [[NSDocumentController sharedDocumentController] openUntitledDocumentAndDisplay: YES error: nil];
	Pump(0.2);
	return doc;
}

static void Close(Document *doc) {
	[doc updateChangeCount: NSChangeCleared];
	[doc close];
	Pump(0.1);
}

static std::string Text(Document *doc) {
	return SciDocumentText(doc.editorController.editor);
}

static void SetText(Document *doc, const char *text) {
	SciCall(doc.editorController.editor, SCI_SETTEXT, 0, reinterpret_cast<sptr_t>(text));
}

static void Send(SEL action, id target, NSInteger tag = 0, id represented = nil) {
	NSMenuItem *item = [[NSMenuItem alloc] init];
	item.tag = tag;
	item.representedObject = represented;
	[NSApp sendAction: action to: target from: item];
	Pump(0.05);
}

static NSString *WriteFile(NSString *name, NSData *data) {
	NSString *dir = [gOut stringByAppendingPathComponent: @"files"];
	[[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES attributes: nil error: nil];
	NSString *path = [dir stringByAppendingPathComponent: name];
	[[NSFileManager defaultManager] createDirectoryAtPath: path.stringByDeletingLastPathComponent
	                          withIntermediateDirectories: YES attributes: nil error: nil];
	[data writeToFile: path atomically: YES];
	return path;
}

// Types text the way the keyboard does (one character at a time, through the input client),
// so that auto-indent, auto-close and auto-completion react to it.
static void Type(ScintillaView *editor, NSString *text) {
	for (NSUInteger i = 0; i < text.length; ++i)
		[editor.content insertText: [text substringWithRange: NSMakeRange(i, 1)] replacementRange: NSMakeRange(NSNotFound, 0)];
	Pump(0.03);
}

static void CloseAll() {
	for (NSDocument *doc in [[NSDocumentController sharedDocumentController].documents copy])
		Close((Document *)doc);
}

static NSData *Bytes(const char *bytes, size_t length) {
	return [NSData dataWithBytes: bytes length: length];
}

static NSData *Utf8(const char *text) {
	return Bytes(text, strlen(text));
}

static std::string StatusText(EditorWindowController *controller) {
	std::string all;
	for (NSView *view in controller.window.contentView.subviews) {
		if ([NSStringFromClass([view class]) isEqualToString: @"StatusBar"]) {
			for (NSView *label in view.subviews) {
				if ([label isKindOfClass: [NSTextField class]]) {
					all += ToStdString(((NSTextField *)label).stringValue);
					all += " | ";
				}
			}
		}
	}
	return all;
}

static const char kCppSample[] =
	"// Sample used by the self test.\n"
	"#include <string>\n"
	"\n"
	"class Counter\n"
	"{\n"
	"public:\n"
	"\tint first() const;\n"
	"\tint second() const;\n"
	"};\n"
	"\n"
	"int Counter::first() const\n"
	"{\n"
	"\treturn 1;\n"
	"}\n"
	"\n"
	"int Counter::second() const\n"
	"{\n"
	"\tif (first() > 0)\n"
	"\t{\n"
	"\t\treturn 2;\n"
	"\t}\n"
	"\treturn 0;\n"
	"}\n";

static void TestHighlightingAndThemes() {
	LOG("== C++ highlighting and themes");
	[AppSettings shared].themeName = kThemeDefault; // "Automatic" depends on the system appearance
	Document *doc = Open(WriteFile(@"Counter.cpp", Utf8(kCppSample)));
	CHECK(doc != nil, "opened Counter.cpp");
	if (!doc)
		return;
	[doc.editorController.window makeKeyAndOrderFront: nil];
	ScintillaView *ed = doc.editorController.editor;
	CHECK(doc.language->name == "cpp", "language detected as cpp (got %s)", doc.language->name.c_str());
	const std::string text = Text(doc);
	const size_t ret = text.find("return ");
	SciCall(ed, SCI_COLOURISE, 0, -1);
	const int style = static_cast<int>(SciCall(ed, SCI_GETSTYLEAT, ret));
	CHECK(style == SCE_C_WORD, "'return' styled as keyword (style %d)", style);
	const sptr_t fore = SciCall(ed, SCI_STYLEGETFORE, SCE_C_WORD);
	const unsigned keyword = [AppSettings shared].currentTheme->Style(StyleRole::Keyword).color;
	CHECK(fore == SciColourFromRGB(keyword), "keyword colour comes from the theme (0x%06lx)", (long)fore);
	CHECK(SciCall(ed, SCI_STYLEGETITALIC, SCE_C_COMMENTLINE), "comments are italic in the Light theme");

	// The highlighter used on iOS gives the same styles as Scintilla, byte for byte.
	auto sameStyles = [](Document *d) {
		ScintillaView *view = d.editorController.editor;
		SciCall(view, SCI_COLOURISE, 0, -1);
		const std::string all = SciDocumentText(view);
		const std::vector<unsigned char> styles = StyleText(all, *d.language);
		size_t different = 0;
		for (size_t i = 0; i < all.size(); ++i)
			different += styles[i] != static_cast<unsigned char>(SciCall(view, SCI_GETSTYLEAT, i));
		return different;
	};
	CHECK(sameStyles(doc) == 0, "highlighter without Scintilla matches Scintilla for C++ (%zu bytes differ)", sameStyles(doc));
	const size_t comment = text.find("//");
	CHECK(SciCall(ed, SCI_GETSTYLEAT, comment) == SCE_C_COMMENTLINE, "// comment styled as comment line");
	CHECK(SciCall(ed, SCI_GETMARGINWIDTHN, 0) > 0, "line number margin visible");
	CHECK(StatusText(doc.editorController).find("C++ |") == 0, "status bar shows language: %s",
	      StatusText(doc.editorController).c_str());

	// Smart highlighting: select a word and check other occurrences get the indicator.
	const size_t word = text.find("Counter::");
	SciCall(ed, SCI_SETSEL, word, word + strlen("Counter"));
	Pump(0.2);
	const size_t second = text.find("Counter::", word + 5);
	const sptr_t indicators = SciCall(ed, SCI_INDICATORALLONFOR, second);
	CHECK(indicators & (1 << 29), "smart highlighting marks other occurrences");
	SciCall(ed, SCI_GOTOPOS, 0);
	WindowShot(doc.editorController.window, @"01-cpp-default-theme");

	[AppSettings shared].themeName = @"Dark";
	Pump(0.3);
	const sptr_t back = SciCall(ed, SCI_STYLEGETBACK, STYLE_DEFAULT);
	CHECK((back & 0xFF) < 0x80, "dark theme applied (default back 0x%06lx)", (long)back);
	WindowShot(doc.editorController.window, @"02-cpp-dark-theme");

	[AppSettings shared].themeName = @"Midnight";
	Pump(0.3);
	WindowShot(doc.editorController.window, @"03-cpp-midnight");

	int loaded = 0;
	for (NSString *theme in [[AppSettings shared] availableThemes]) {
		[AppSettings shared].themeName = theme;
		Pump(0.05);
		++loaded;
	}
	CHECK(loaded >= 10, "all %d bundled themes applied without crashing", loaded);
	[AppSettings shared].themeName = @"A theme that does not exist";
	Pump(0.1);
	CHECK([AppSettings shared].currentTheme->Name() == "Light" || [AppSettings shared].currentTheme->Name() == "Dark",
	      "an unknown theme falls back to Light or Dark (%s)", [AppSettings shared].currentTheme->Name().c_str());
	[AppSettings shared].themeName = kThemeDefault;
	Pump(0.2);
	Close(doc);
}

static void TestLanguageDetection() {
	LOG("== Language detection");
	const struct { NSString *name; const char *content; const char *language; } cases[] = {
		{@"script.py", "def f():\n    return 1\n", "python"},
		{@"page.html", "<html><body><script>var a = 1;</script><?php echo 1; ?></body></html>\n", "html"},
		{@"Makefile", "all:\n\tcc main.c\n", "makefile"},
		{@"data.json", "{\"a\": [1, 2, true]}\n", "json"},
		{@"run", "#!/bin/bash\necho hi\n", "shell"},
		{@"tool", "#!/usr/bin/env python3.12\nprint(1)\n", "python"},
		{@"view.m", "#import <Foundation/Foundation.h>\n@interface A : NSObject\n@end\n", "objc"},
		{@"fit.m", "x = linspace(0, 1);\nplot(x, x.^2)\n", "matlab"},
		{@"README.md", "# Title\n\nSome *text*.\n", "markdown"},
		{@".zshrc", "export PATH=$HOME/bin:$PATH\n", "shell"},
		{@"index.php", "<?php echo 1; ?>\n", "php"},
		{@"noext", "<?xml version=\"1.0\"?>\n<a/>\n", "xml"},
		{@"main.rs", "fn main() {}\n", "rust"},
		{@"app.ts", "let x: number = 1;\n", "typescript"},
		{@"CMakeLists.txt", "project(x)\n", "cmake"},
		{@"notes.txt", "hello\n", "normal"},
	};
	for (const auto &entry : cases) {
		Document *doc = Open(WriteFile(entry.name, Utf8(entry.content)));
		CHECK(doc && doc.language->name == entry.language, "%s -> %s (got %s)", entry.name.UTF8String, entry.language,
		      doc ? doc.language->name.c_str() : "nil");
		if ([entry.name isEqualToString: @"page.html"]) {
			ScintillaView *ed = doc.editorController.editor;
			SciCall(ed, SCI_COLOURISE, 0, -1);
			const std::string text = Text(doc);
			const int jsStyle = static_cast<int>(SciCall(ed, SCI_GETSTYLEAT, text.find("var")));
			const int phpStyle = static_cast<int>(SciCall(ed, SCI_GETSTYLEAT, text.find("echo")));
			CHECK(jsStyle == SCE_HJ_KEYWORD, "embedded JavaScript keyword styled (style %d)", jsStyle);
			CHECK(phpStyle == SCE_HPHP_WORD, "embedded PHP keyword styled (style %d)", phpStyle);
			const std::string page = Text(doc);
			const std::vector<unsigned char> styles = StyleText(page, *doc.language);
			size_t different = 0;
			for (size_t i = 0; i < page.size(); ++i)
				different += styles[i] != static_cast<unsigned char>(SciCall(ed, SCI_GETSTYLEAT, i));
			CHECK(different == 0, "highlighter without Scintilla matches Scintilla for HTML (%zu bytes differ)", different);
			WindowShot(doc.editorController.window, @"04-html-embedded");
		}
		Close(doc);
	}
}

static void TestEncodings() {
	LOG("== Encodings and line endings");
	// UTF-16 LE with BOM, CRLF
	const char utf16[] = "\xFF\xFE" "h\0\xE9\0l\0l\0o\0\r\0\n\0w\0o\0r\0l\0d\0";
	Document *doc = Open(WriteFile(@"utf16le.txt", Bytes(utf16, sizeof(utf16) - 1)));
	CHECK(doc && [doc.encoding.DisplayName() isEqualToString: @"UTF-16 LE BOM"], "UTF-16 LE BOM detected (%s)",
	      doc ? doc.encoding.DisplayName().UTF8String : "nil");
	CHECK(doc && Text(doc) == "h\xC3\xA9llo\r\nworld", "UTF-16 text decoded");
	CHECK(doc && doc.lineEnding == LineEnding::CRLF, "CRLF detected");
	CHECK(doc && StatusText(doc.editorController).find("Windows (CR LF)") != std::string::npos, "status bar shows CRLF");
	Close(doc);

	// Windows-1252 (not valid UTF-8)
	const char cp1252[] = "Caf\xE9 cr\xE8me br\xFBl\xE9" "e, na\xEFve d\xE9j\xE0 vu. \xC0 bient\xF4t, \xE9t\xE9 \xE0 la for\xEAt.\n";
	doc = Open(WriteFile(@"cp1252.txt", Bytes(cp1252, sizeof(cp1252) - 1)));
	CHECK(doc && doc.encoding.kind == FileEncoding::Legacy, "legacy encoding detected (%s)", doc ? doc.encoding.DisplayName().UTF8String : "nil");
	CHECK(doc && Text(doc).find("Caf\xC3\xA9 cr\xC3\xA8me") == 0, "Windows-1252 text decoded to UTF-8");
	Close(doc);

	// Shift-JIS: 日本語のテキストです。これは文字コードの検出テストです。
	NSString *japanese = @"日本語のテキストです。これは文字コードの検出テストです。東京都の天気は晴れです。\n";
	NSData *sjis = [japanese dataUsingEncoding: NSShiftJISStringEncoding];
	doc = Open(WriteFile(@"sjis.txt", sjis));
	CHECK(doc && Text(doc) == ToStdString(japanese), "Shift-JIS decoded (%s)", doc ? doc.encoding.DisplayName().UTF8String : "nil");
	Close(doc);

	// Convert UTF-8 file to UTF-16 BE BOM and save.
	NSString *path = WriteFile(@"convert.txt", Utf8("ol\xC3\xA1 mundo\n"));
	doc = Open(path);
	Send(@selector(convertEncoding:), doc.editorController, 3);
	CHECK(doc.isDocumentEdited, "encoding change marks document dirty");
	[doc saveDocument: nil];
	Pump(0.5);
	NSData *saved = [NSData dataWithContentsOfFile: path];
	NSData *expected = [[@"olá mundo\n" dataUsingEncoding: NSUTF16BigEndianStringEncoding] mutableCopy];
	NSMutableData *withBom = [NSMutableData dataWithBytes: "\xFE\xFF" length: 2];
	[withBom appendData: expected];
	CHECK([saved isEqualToData: withBom], "saved as UTF-16 BE with BOM (%lu bytes)", (unsigned long)saved.length);
	CHECK(!doc.isDocumentEdited, "document clean after save");
	Close(doc);

	// Saving a character that does not exist in Windows-1252 fails with an error instead of losing data.
	path = WriteFile(@"ansi.txt", Utf8("plain\n"));
	doc = Open(path);
	Send(@selector(convertEncoding:), doc.editorController, 5);
	SciCall(doc.editorController.editor, SCI_APPENDTEXT, 3, reinterpret_cast<sptr_t>("\xE2\x82\xAC")); // euro sign exists in cp1252
	NSError *error = nil;
	NSData *data = [doc dataOfType: @"public.data" error: &error];
	CHECK(data && data.length == 7 && ((const unsigned char *)data.bytes)[6] == 0x80, "euro sign saved as 0x80 in Windows-1252");
	SciCall(doc.editorController.editor, SCI_APPENDTEXT, 3, reinterpret_cast<sptr_t>("\xE6\x97\xA5")); // 日 not in cp1252
	data = [doc dataOfType: @"public.data" error: &error];
	CHECK(data == nil && error != nil, "unrepresentable character reported instead of silently dropped");
	Close(doc);

	// EOL conversion
	doc = NewDocument();
	SetText(doc, "a\r\nb\r\nc");
	Send(@selector(setLineEnding:), doc.editorController, static_cast<NSInteger>(LineEnding::LF));
	CHECK(Text(doc) == "a\nb\nc", "EOL converted to LF");
	CHECK(SciCall(doc.editorController.editor, SCI_GETEOLMODE) == SC_EOL_LF, "EOL mode set to LF");
	Close(doc);
}

static void TestFindReplace() {
	LOG("== Find / Replace");
	Document *doc = NewDocument();
	[doc.editorController.window makeKeyAndOrderFront: nil];
	Pump(0.2);
	ScintillaView *ed = doc.editorController.editor;
	SetText(doc, "foo bar foo\nFoo baz\n");
	SciCall(ed, SCI_GOTOPOS, 0);
	FindPanel *panel = [FindPanel shared];
	panel.findString = @"foo";
	[panel findInEditor: ed backward: NO];
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 0 && SciCall(ed, SCI_GETSELECTIONEND) == 3, "first match selected");
	[panel findInEditor: ed backward: NO];
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 8, "second match selected");
	[panel findInEditor: ed backward: NO];
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 12, "case-insensitive match 'Foo'");
	[panel findInEditor: ed backward: NO];
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 0, "wrapped around to the top");
	[panel findInEditor: ed backward: YES];
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 12, "backward search wraps to the bottom");

	NSComboBox *replace = [panel valueForKey: @"_replaceField"];
	replace.stringValue = @"qux";
	[NSApp sendAction: @selector(replaceAllClicked:) to: panel from: nil];
	CHECK(Text(doc) == "qux bar qux\nqux baz\n", "Replace All (normal): %s", Text(doc).c_str());

	NSButton *regex = [panel valueForKey: @"_modeRegex"];
	NSButton *normal = [panel valueForKey: @"_modeNormal"];
	NSButton *extended = [panel valueForKey: @"_modeExtended"];
	regex.state = NSControlStateValueOn;
	normal.state = NSControlStateValueOff;
	panel.findString = @"b(a.)";
	replace.stringValue = @"\\1!";
	[NSApp sendAction: @selector(replaceAllClicked:) to: panel from: nil];
	CHECK(Text(doc) == "qux ar! qux\nqux az!\n", "Replace All (regex with group): %s", Text(doc).c_str());

	regex.state = NSControlStateValueOff;
	extended.state = NSControlStateValueOn;
	panel.findString = @"\\n";
	replace.stringValue = @"|";
	[NSApp sendAction: @selector(replaceAllClicked:) to: panel from: nil];
	CHECK(Text(doc) == "qux ar! qux|qux az!|", "Replace All (extended \\n): %s", Text(doc).c_str());

	extended.state = NSControlStateValueOff;
	normal.state = NSControlStateValueOn;
	panel.findString = @"qux";
	[NSApp sendAction: @selector(countClicked:) to: panel from: nil];
	NSTextField *status = [panel valueForKey: @"_status"];
	CHECK([status.stringValue containsString: @"3 matches"], "Count: %s", status.stringValue.UTF8String);
	[NSApp sendAction: @selector(markAllClicked:) to: panel from: nil];
	CHECK(SciCall(ed, SCI_INDICATORALLONFOR, 0) & (1 << 31), "Mark All sets the mark indicator");

	Document *second = NewDocument();
	Pump(0.4);
	CHECK(second.editorController.window.tabbedWindows.count >= 2, "new document opens as a tab (%lu tabs)",
	      (unsigned long)second.editorController.window.tabbedWindows.count);
	Close(second);
	Close(doc);
}

static void TestLineOperations() {
	LOG("== Line operations and comments");
	Document *doc = NewDocument();
	ScintillaView *ed = doc.editorController.editor;
	Send(@selector(setLanguage:), doc.editorController, 0, @"cpp");
	CHECK(doc.language->name == "cpp", "language set from menu");

	SetText(doc, "int a;\nint b;\n");
	SciCall(ed, SCI_GOTOPOS, 2);
	Send(@selector(toggleLineComment:), doc.editorController);
	CHECK(Text(doc) == "// int a;\nint b;\n", "comment current line: %s", Text(doc).c_str());
	Send(@selector(toggleLineComment:), doc.editorController);
	CHECK(Text(doc) == "int a;\nint b;\n", "uncomment current line: %s", Text(doc).c_str());
	SciCall(ed, SCI_SETSEL, 0, SciCall(ed, SCI_GETLENGTH));
	Send(@selector(toggleLineComment:), doc.editorController);
	CHECK(Text(doc) == "// int a;\n// int b;\n", "comment selected lines: %s", Text(doc).c_str());
	SciCall(ed, SCI_SETSEL, 0, 0);
	SciCall(ed, SCI_SETSEL, 0, 6);
	Send(@selector(toggleBlockComment:), doc.editorController);
	CHECK(Text(doc).compare(0, 12, "/* // int */") == 0, "block comment: %s", Text(doc).c_str());

	SetText(doc, "c\nb\na\nb\n");
	SciCall(ed, SCI_GOTOPOS, 0);
	Send(@selector(sortLinesAscending:), doc.editorController);
	CHECK(Text(doc) == "a\nb\nb\nc\n", "sort ascending keeps final newline: %s", Text(doc).c_str());
	Send(@selector(removeDuplicateLines:), doc.editorController);
	CHECK(Text(doc) == "a\nb\nc\n", "remove duplicates: %s", Text(doc).c_str());
	SetText(doc, "x  \n\n  \ny\t\n");
	Send(@selector(removeEmptyLines:), doc.editorController);
	CHECK(Text(doc) == "x  \ny\t\n", "remove empty lines: %s", Text(doc).c_str());
	Send(@selector(trimTrailingSpace:), doc.editorController);
	CHECK(Text(doc) == "x\ny\n", "trim trailing space: %s", Text(doc).c_str());
	SciCall(ed, SCI_GOTOPOS, 0);
	Send(@selector(duplicateLine:), doc.editorController);
	CHECK(Text(doc) == "x\nx\ny\n", "duplicate line: %s", Text(doc).c_str());

	// Auto-indent after Enter
	SetText(doc, "    if (a)");
	SciCall(ed, SCI_DOCUMENTEND);
	[ed.content insertText: @"\n" replacementRange: NSMakeRange(NSNotFound, 0)];
	Pump(0.05);
	// With "use tabs" and tab width 4, Scintilla rebuilds the indentation as a tab.
	CHECK(Text(doc) == "    if (a)\n\t", "auto-indent copies indentation: '%s'", Text(doc).c_str());

	Close(doc);
}

static void TestDirtyAndReload() {
	LOG("== Dirty flag and external changes");
	NSString *path = WriteFile(@"reload.txt", Utf8("first\n"));
	Document *doc = Open(path);
	ScintillaView *ed = doc.editorController.editor;
	CHECK(!doc.isDocumentEdited, "clean after open");
	SciCall(ed, SCI_APPENDTEXT, 1, reinterpret_cast<sptr_t>("x"));
	Pump(0.05);
	CHECK(doc.isDocumentEdited, "dirty after typing");
	SciCall(ed, SCI_UNDO);
	Pump(0.05);
	CHECK(!doc.isDocumentEdited, "clean again after undo to save point");

	NSTask *task = [NSTask launchedTaskWithExecutableURL: [NSURL fileURLWithPath: @"/bin/sh"]
	                                           arguments: @[@"-c", [NSString stringWithFormat: @"sleep 1; printf 'second\\n' > '%@'", path]]
	                                               error: nil
	                                  terminationHandler: nil];
	[task waitUntilExit];
	for (int i = 0; i < 40 && Text(doc) != "second\n"; ++i)
		Pump(0.1);
	CHECK(Text(doc) == "second\n", "reloaded after another program changed the file (file presenter): %s", Text(doc).c_str());
	if (Text(doc) != "second\n") {
		[doc checkForExternalChange];
		Pump(0.2);
		CHECK(Text(doc) == "second\n", "reloaded by explicit check (window focus path)");
	}
	CHECK(!doc.isDocumentEdited, "clean after reload");

	// Atomic save by another editor: write a temp file and rename it over the original.
	NSTask *atomic = [NSTask launchedTaskWithExecutableURL: [NSURL fileURLWithPath: @"/bin/sh"]
	                                             arguments: @[@"-c", [NSString stringWithFormat: @"sleep 1; printf 'third\\n' > '%@.tmp' && mv '%@.tmp' '%@'", path, path, path]]
	                                                 error: nil
	                                    terminationHandler: nil];
	[atomic waitUntilExit];
	for (int i = 0; i < 40 && Text(doc) != "third\n"; ++i)
		Pump(0.1);
	CHECK(Text(doc) == "third\n", "reloaded after the file was replaced (atomic save): %s", Text(doc).c_str());

	// Unsaved edits + external change: ask instead of reloading.
	SciCall(ed, SCI_APPENDTEXT, 5, reinterpret_cast<sptr_t>("mine\n"));
	Pump(0.05);
	NSTask *third = [NSTask launchedTaskWithExecutableURL: [NSURL fileURLWithPath: @"/bin/sh"]
	                                            arguments: @[@"-c", [NSString stringWithFormat: @"sleep 1; printf 'fourth\\n' > '%@'", path]]
	                                                error: nil
	                                   terminationHandler: nil];
	[third waitUntilExit];
	NSWindow *window = doc.editorController.window;
	for (int i = 0; i < 40 && !window.attachedSheet; ++i)
		Pump(0.1);
	CHECK(window.attachedSheet != nil, "asks before reloading over unsaved edits");
	CHECK(Text(doc) == "third\nmine\n", "unsaved edits kept while asking");
	if (window.attachedSheet) {
		WindowShot(window, @"07-reload-prompt");
		[window endSheet: window.attachedSheet returnCode: NSAlertSecondButtonReturn]; // Keep My Version
		Pump(0.2);
	}
	CHECK(Text(doc) == "third\nmine\n" && doc.isDocumentEdited, "Keep My Version leaves the edits in place");
	Close(doc);
}

static void TestEditingCommands() {
	LOG("== New editing commands");
	Document *doc = NewDocument();
	[doc.editorController.window makeKeyAndOrderFront: nil];
	EditorWindowController *controller = doc.editorController;
	ScintillaView *ed = controller.editor;

	SetText(doc, "10\n9\nabc\n2\n");
	SciCall(ed, SCI_GOTOPOS, 0);
	Send(@selector(sortLinesNumerically:), controller);
	CHECK(Text(doc) == "2\n9\n10\nabc\n", "sort as numbers: %s", Text(doc).c_str());
	Send(@selector(reverseLines:), controller);
	CHECK(Text(doc) == "abc\n10\n9\n2\n", "reverse line order: %s", Text(doc).c_str());

	SetText(doc, "  x \n\ty\t\n");
	Send(@selector(trimLeadingSpace:), controller);
	CHECK(Text(doc) == "x \ny\t\n", "trim leading space: '%s'", Text(doc).c_str());
	SetText(doc, "a  \nb\t \n  c");
	SciCall(ed, SCI_GOTOPOS, 1);
	[controller trimTrailingWhitespaceInDocument];
	CHECK(Text(doc) == "a\nb\n  c", "trim trailing whitespace in the whole document: '%s'", Text(doc).c_str());

	SetText(doc, "hello wORLD don't");
	SciCall(ed, SCI_SELECTALL);
	Send(@selector(toProperCase:), controller);
	CHECK(Text(doc) == "Hello World Don't", "Proper Case: %s", Text(doc).c_str());
	Send(@selector(invertCase:), controller);
	CHECK(Text(doc) == "hELLO wORLD dON'T", "invert case: %s", Text(doc).c_str());
	SetText(doc, "ol\xC3\xA1 mundo. segunda FRASE");
	SciCall(ed, SCI_SELECTALL);
	Send(@selector(toSentenceCase:), controller);
	CHECK(Text(doc) == "Ol\xC3\xA1 mundo. Segunda frase", "Sentence case: %s", Text(doc).c_str());

	SetText(doc, "one\ntwo");
	SciCall(ed, SCI_GOTOPOS, 1);
	Send(@selector(insertBlankLineBelow:), controller);
	CHECK(Text(doc) == "one\n\ntwo" && SciCall(ed, SCI_GETCURRENTPOS) == 4, "insert blank line below: %s", Text(doc).c_str());
	SciCall(ed, SCI_GOTOPOS, 6);
	Send(@selector(insertBlankLineAbove:), controller);
	CHECK(Text(doc) == "one\n\n\ntwo", "insert blank line above: %s", Text(doc).c_str());

	SetText(doc, "foo bar foo baz foo");
	SciCall(ed, SCI_GOTOPOS, 1);
	Send(@selector(selectNextOccurrence:), controller);
	Send(@selector(selectNextOccurrence:), controller);
	CHECK(SciCall(ed, SCI_GETSELECTIONS) == 2, "Select Next Occurrence adds a selection (%ld)", (long)SciCall(ed, SCI_GETSELECTIONS));
	Send(@selector(selectAllOccurrences:), controller);
	CHECK(SciCall(ed, SCI_GETSELECTIONS) == 3, "Select All Occurrences (%ld)", (long)SciCall(ed, SCI_GETSELECTIONS));
	Type(ed, @"X");
	CHECK(Text(doc) == "X bar X baz X", "typing replaces every selection: %s", Text(doc).c_str());

	SetText(doc, "f(a[1])");
	SciCall(ed, SCI_GOTOPOS, 1);
	Send(@selector(selectToMatchingBrace:), controller);
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 1 && SciCall(ed, SCI_GETSELECTIONEND) == 7, "select to matching brace");

	SciCall(ed, SCI_SETSEL, 0, 0);
	Send(@selector(insertDateTimeISO:), controller);
	CHECK(Text(doc).size() == 7 + 19 && Text(doc)[4] == '-' && Text(doc)[13] == ':', "insert ISO date and time: %s", Text(doc).c_str());

	// A file dragged from Finder onto the text arrives as SCN_URIDROPPED and opens as a document.
	NSString *dropped = WriteFile(@"dropped.txt", Utf8("dropped\n"));
	SCNotification drop = {};
	drop.nmhdr.code = SCN_URIDROPPED;
	drop.text = dropped.fileSystemRepresentation;
	[controller notification: &drop];
	Document *droppedDocument = nil;
	for (int i = 0; i < 60 && !droppedDocument; ++i) {
		Pump(0.05);
		droppedDocument = (Document *)[[NSDocumentController sharedDocumentController] documentForURL: [NSURL fileURLWithPath: dropped]];
	}
	Pump(0.2);
	CHECK(droppedDocument && Text(droppedDocument) == "dropped\n" && Text(doc).size() == 7 + 19,
	      "a file dropped on the editor opens instead of inserting its path");
	if (droppedDocument)
		Close(droppedDocument);
	Close(doc);
}

static void TestTools() {
	LOG("== Tools");
	CHECK(HashHex("abc", HashAlgorithm::MD5) == "900150983cd24fb0d6963f7d28e17f72", "MD5");
	CHECK(HashHex("abc", HashAlgorithm::SHA1) == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1");
	CHECK(HashHex("abc", HashAlgorithm::SHA256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256");
	CHECK(HashHex("abc", HashAlgorithm::SHA512).compare(0, 16, "ddaf35a193617aba") == 0, "SHA-512");

	Document *doc = NewDocument();
	[doc.editorController.window makeKeyAndOrderFront: nil];
	EditorWindowController *controller = doc.editorController;
	ScintillaView *ed = controller.editor;

	SetText(doc, "ol\xC3\xA1 mundo");
	Send(@selector(base64Encode:), controller);
	CHECK(Text(doc) == "b2zDoSBtdW5kbw==", "Base64 encode: %s", Text(doc).c_str());
	Send(@selector(base64Decode:), controller);
	CHECK(Text(doc) == "ol\xC3\xA1 mundo", "Base64 decode: %s", Text(doc).c_str());

	SetText(doc, "x=a b&c/\xC3\xA7");
	SciCall(ed, SCI_SETSEL, 2, SciCall(ed, SCI_GETLENGTH));
	Send(@selector(urlEncode:), controller);
	CHECK(Text(doc) == "x=a%20b%26c%2F%C3%A7", "URL encode (selection only): %s", Text(doc).c_str());
	Send(@selector(urlDecode:), controller);
	CHECK(Text(doc) == "x=a b&c/\xC3\xA7", "URL decode: %s", Text(doc).c_str());

	const char *compact = "{\"b\":1,\"a\":[1,2.50,{\"x\":null,\"s\":\"a,b:{c}\"}],\"e\":{},\"l\":[]}";
	SetText(doc, compact);
	SciCall(ed, SCI_GOTOPOS, 0);
	Send(@selector(formatJSON:), controller);
	const char *pretty =
		"{\n\t\"b\": 1,\n\t\"a\": [\n\t\t1,\n\t\t2.50,\n\t\t{\n\t\t\t\"x\": null,\n\t\t\t\"s\": \"a,b:{c}\"\n\t\t}\n\t],\n"
		"\t\"e\": {},\n\t\"l\": []\n}";
	CHECK(Text(doc) == pretty, "Format JSON keeps key order and number text:\n%s", Text(doc).c_str());
	Send(@selector(minifyJSON:), controller);
	CHECK(Text(doc) == compact, "Minify JSON: %s", Text(doc).c_str());

	SetText(doc, "{\"a\": }");
	Send(@selector(formatJSON:), controller);
	Pump(0.5);
	NSWindow *window = controller.window;
	CHECK(window.attachedSheet != nil && Text(doc) == "{\"a\": }", "invalid JSON is reported and left untouched");
	if (window.attachedSheet) {
		[window endSheet: window.attachedSheet];
		Pump(0.3);
	}
	Close(doc);
}

static void TestAutoCloseAndCompletion() {
	LOG("== Auto-close and auto-completion");
	Document *doc = NewDocument();
	[doc.editorController.window makeKeyAndOrderFront: nil];
	EditorWindowController *controller = doc.editorController;
	ScintillaView *ed = controller.editor;

	Type(ed, @"(");
	CHECK(Text(doc) == "(", "no auto-close in Normal Text: %s", Text(doc).c_str());

	Send(@selector(setLanguage:), controller, 0, @"cpp");
	SetText(doc, "");
	Type(ed, @"f(");
	CHECK(Text(doc) == "f()" && SciCall(ed, SCI_GETCURRENTPOS) == 2, "bracket closes itself: %s", Text(doc).c_str());
	Type(ed, @"x)");
	CHECK(Text(doc) == "f(x)" && SciCall(ed, SCI_GETCURRENTPOS) == 4, "typing the closer steps over it: %s", Text(doc).c_str());
	Type(ed, @" \"");
	CHECK(Text(doc) == "f(x) \"\"", "quote closes itself: %s", Text(doc).c_str());
	Type(ed, @"a\"");
	CHECK(Text(doc) == "f(x) \"a\"", "closing quote steps over: %s", Text(doc).c_str());
	SetText(doc, "don");
	SciCall(ed, SCI_DOCUMENTEND);
	Type(ed, @"'");
	CHECK(Text(doc) == "don'", "no quote pair inside a word: %s", Text(doc).c_str());
	SetText(doc, "x = (y");
	SciCall(ed, SCI_GOTOPOS, 4);
	Type(ed, @"[");
	CHECK(Text(doc) == "x = [(y", "no closer in front of other text: %s", Text(doc).c_str());

	// Words of the document
	SetText(doc, "alphabet alphanumeric\n");
	SciCall(ed, SCI_DOCUMENTEND);
	Type(ed, @"al");
	CHECK(!SciCall(ed, SCI_AUTOCACTIVE), "no suggestions before the third character");
	Type(ed, @"p");
	CHECK(SciCall(ed, SCI_AUTOCACTIVE), "suggestions appear on the third character");
	char current[256] = "";
	SciCall(ed, SCI_AUTOCGETCURRENTTEXT, 0, reinterpret_cast<sptr_t>(current));
	CHECK(strcmp(current, "alphabet") == 0, "first suggestion is a word of the document: %s", current);
	WindowShot(controller.window, @"08-auto-completion");
	SciCall(ed, SCI_TAB);
	CHECK(Text(doc) == "alphabet alphanumeric\nalphabet", "Tab completes the word: %s", Text(doc).c_str());

	// Keywords of the language
	SetText(doc, "");
	Type(ed, @"retu");
	current[0] = '\0';
	if (SciCall(ed, SCI_AUTOCACTIVE))
		SciCall(ed, SCI_AUTOCGETCURRENTTEXT, 0, reinterpret_cast<sptr_t>(current));
	CHECK(strcmp(current, "return") == 0, "language keywords are suggested: %s", current);
	// Return on a fully typed word starts a new line instead of swallowing the key.
	Type(ed, @"rn");
	SciCall(ed, SCI_NEWLINE); // what the Return key sends
	CHECK(Text(doc) == "return\n", "Return after a complete word adds the line break: '%s'", Text(doc).c_str());
	SciCall(ed, SCI_AUTOCCANCEL);

	[AppSettings shared].autoComplete = NO;
	[AppSettings shared].autoCloseBrackets = NO;
	SetText(doc, "alphabet\n");
	SciCall(ed, SCI_DOCUMENTEND);
	Type(ed, @"alph(");
	CHECK(!SciCall(ed, SCI_AUTOCACTIVE) && Text(doc) == "alphabet\nalph(", "both can be turned off: %s", Text(doc).c_str());
	[AppSettings shared].autoComplete = YES;
	[AppSettings shared].autoCloseBrackets = YES;
	SciCall(ed, SCI_AUTOCCANCEL);
	Close(doc);
}

static void TestMacro() {
	LOG("== Macros");
	Document *doc = NewDocument();
	[doc.editorController.window makeKeyAndOrderFront: nil];
	EditorWindowController *controller = doc.editorController;
	ScintillaView *ed = controller.editor;
	MacroRecorder *macro = [MacroRecorder shared];

	SetText(doc, "one\ntwo\nthree\nfour\n");
	SciCall(ed, SCI_GOTOPOS, 0);
	Send(@selector(toggleMacroRecording:), controller);
	CHECK(macro.recording, "recording started");
	CHECK(StatusText(controller).find("REC") != std::string::npos, "status bar shows REC");
	Type(ed, @"- ");
	SciCall(ed, SCI_LINEDOWN);
	SciCall(ed, SCI_HOME);
	Send(@selector(toggleMacroRecording:), controller);
	CHECK(!macro.recording && macro.hasMacro, "recording stopped with %lu steps", (unsigned long)macro.stepCount);
	Send(@selector(playMacro:), controller);
	CHECK(Text(doc) == "- one\n- two\nthree\nfour\n", "playback repeats typing and caret movement: %s", Text(doc).c_str());
	[macro playInController: controller times: 0];
	CHECK(Text(doc) == "- one\n- two\n- three\n- four\n", "run until the end of the file: %s", Text(doc).c_str());
	SciCall(ed, SCI_UNDO);
	CHECK(Text(doc) == "- one\n- two\nthree\nfour\n", "a macro run is one undo step: %s", Text(doc).c_str());

	// Menu commands are recorded as commands, not as the Scintilla messages they send.
	SetText(doc, "x\ny\n");
	SciCall(ed, SCI_GOTOPOS, 0);
	Send(@selector(toggleMacroRecording:), controller);
	Send(@selector(duplicateLine:), controller);
	Send(@selector(toggleMacroRecording:), controller);
	CHECK(macro.stepCount == 1 && Text(doc) == "x\nx\ny\n", "menu command recorded once (%lu steps)", (unsigned long)macro.stepCount);
	[macro playInController: controller times: 2];
	CHECK(Text(doc) == "x\nx\nx\nx\ny\n", "menu command replayed twice: %s", Text(doc).c_str());
	Close(doc);
}

static NSArray *SearchGroups() {
	return [[SearchResultsPanel shared] valueForKey: @"_searches"];
}

static void TestFindAllAndFindInFiles() {
	LOG("== Find All, In selection, Find in Files");
	// The search engine used for files, on its own: byte offsets and lines with multi-byte text.
	SearchQuery query;
	query.pattern = "needle";
	std::vector<SearchHit> hits;
	SearchText("\xC3\xA9 needle\n\xE6\x97\xA5\xE6\x9C\xAC needle x", CompileSearchQuery(query, nil), hits, 100);
	CHECK(hits.size() == 2 && hits[0].start == 3 && hits[0].end == 9 && hits[0].line == 0 && hits[1].start == 17 &&
	      hits[1].line == 1 && hits[1].lineText == "\xE6\x97\xA5\xE6\x9C\xAC needle x" && hits[1].markStart == 7,
	      "file search reports byte offsets and lines (%lu hits)", (unsigned long)hits.size());
	query.pattern = "Cat";
	query.wholeWord = true;
	query.matchCase = true;
	hits.clear();
	SearchText("Cat Catalog cat\r\nconCat Cat", CompileSearchQuery(query, nil), hits, 100);
	CHECK(hits.size() == 2 && hits[0].start == 0 && hits[1].line == 1, "whole word and match case in files (%lu hits)", (unsigned long)hits.size());
	const FileFilter filter = FileFilter::Parse("*.cpp *.h !test_*");
	CHECK(filter.Matches("Main.CPP") && filter.Matches("a.h") && !filter.Matches("a.txt") && !filter.Matches("test_a.cpp") &&
	      FileFilter::Parse("*.*").Matches("Makefile"), "file filters");

	Document *doc = NewDocument();
	[doc.editorController.window makeKeyAndOrderFront: nil];
	Pump(0.2);
	ScintillaView *ed = doc.editorController.editor;
	FindPanel *panel = [FindPanel shared];
	[panel window];
	NSComboBox *replace = [panel valueForKey: @"_replaceField"];
	NSButton *inSelection = [panel valueForKey: @"_inSelection"];
	NSButton *matchCase = [panel valueForKey: @"_matchCase"];
	NSButton *regex = [panel valueForKey: @"_modeRegex"];
	NSButton *normal = [panel valueForKey: @"_modeNormal"];
	NSTextField *status = [panel valueForKey: @"_status"];
	SearchResultsPanel *results = [SearchResultsPanel shared];
	[results clearResults: nil];

	SetText(doc, "aa aa aa");
	SciCall(ed, SCI_SETSEL, 0, 5);
	panel.findString = @"aa";
	replace.stringValue = @"b";
	inSelection.state = NSControlStateValueOn;
	[NSApp sendAction: @selector(countClicked:) to: panel from: nil];
	CHECK([status.stringValue containsString: @"2 matches in selected text"], "Count in selection: %s", status.stringValue.UTF8String);
	[NSApp sendAction: @selector(replaceAllClicked:) to: panel from: nil];
	CHECK(Text(doc) == "b b aa", "Replace All in selection: %s", Text(doc).c_str());
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 0 && SciCall(ed, SCI_GETSELECTIONEND) == 3, "selection follows the replaced text");
	inSelection.state = NSControlStateValueOff;

	regex.state = NSControlStateValueOn;
	normal.state = NSControlStateValueOff;
	panel.findString = @"(";
	CHECK(![panel findInEditor: ed backward: NO] && [status.stringValue containsString: @"Invalid regular expression"],
	      "invalid regular expression is reported: %s", status.stringValue.UTF8String);
	regex.state = NSControlStateValueOff;
	normal.state = NSControlStateValueOn;

	SetText(doc, "foo\nbar Foo foo\nbaz\n");
	panel.findString = @"foo";
	[NSApp sendAction: @selector(findAllInCurrentDocumentClicked:) to: panel from: nil];
	Pump(0.4);
	id group = SearchGroups().firstObject;
	CHECK([results hitCountOfSearch: group] == 3 && [results fileCountOfSearch: group] == 1, "Find All in Current Document: %ld hits",
	      (long)[results hitCountOfSearch: group]);
	NSOutlineView *outline = [results valueForKey: @"_outline"];
	CHECK(outline.numberOfRows == 5, "results list: search, document and 3 lines (%ld rows)", (long)outline.numberOfRows);
	[outline selectRowIndexes: [NSIndexSet indexSetWithIndex: 3] byExtendingSelection: NO];
	[results openSelectedResult: nil];
	Pump(0.2);
	CHECK(SciCall(ed, SCI_GETSELECTIONSTART) == 8 && SciCall(ed, SCI_GETSELECTIONEND) == 11, "opening a result selects the match (%ld-%ld)",
	      (long)SciCall(ed, SCI_GETSELECTIONSTART), (long)SciCall(ed, SCI_GETSELECTIONEND));

	Document *other = NewDocument();
	SetText(other, "xfoo\n");
	[NSApp sendAction: @selector(findAllInOpenDocumentsClicked:) to: panel from: nil];
	Pump(0.4);
	group = SearchGroups().firstObject;
	CHECK([results hitCountOfSearch: group] == 4 && [results fileCountOfSearch: group] == 2, "Find All in All Opened Documents: %ld hits in %ld",
	      (long)[results hitCountOfSearch: group], (long)[results fileCountOfSearch: group]);
	Close(other);

	// Find in Files
	NSString *root = [gOut stringByAppendingPathComponent: @"files/tree"];
	WriteFile(@"tree/a.txt", Utf8("needle here\nnothing\nNEEDLE again\n"));
	WriteFile(@"tree/sub/b.cpp", Utf8("int needle;\n"));
	WriteFile(@"tree/c.bin", Bytes("\0\0needle\0", 9));
	WriteFile(@"tree/.hidden/d.txt", Utf8("needle\n"));
	WriteFile(@"tree/e.log", Utf8("needle\n"));
	const char latin1[] = "caf\xE9 cr\xE8me d\xE9j\xE0 needle fa\xE7" "ade\n";
	WriteFile(@"tree/latin1.txt", Bytes(latin1, sizeof(latin1) - 1));

	auto runFileSearch = [&](NSString *filters, BOOL subfolders, BOOL hidden) {
		((NSComboBox *)[panel valueForKey: @"_directoryField"]).stringValue = [root stringByAbbreviatingWithTildeInPath];
		((NSComboBox *)[panel valueForKey: @"_filtersField"]).stringValue = filters;
		((NSButton *)[panel valueForKey: @"_subfolders"]).state = subfolders ? NSControlStateValueOn : NSControlStateValueOff;
		((NSButton *)[panel valueForKey: @"_hiddenFiles"]).state = hidden ? NSControlStateValueOn : NSControlStateValueOff;
		[NSApp sendAction: @selector(findInFilesClicked:) to: panel from: nil];
		for (int i = 0; i < 200 && panel.fileSearchRunning; ++i)
			Pump(0.05);
		Pump(0.4);
		return SearchGroups().firstObject;
	};
	panel.findString = @"needle";
	group = runFileSearch(@"*.txt *.cpp", YES, NO);
	CHECK(!panel.fileSearchRunning, "Find in Files finished");
	CHECK([results hitCountOfSearch: group] == 4 && [results fileCountOfSearch: group] == 3,
	      "Find in Files with filters and sub-folders: %ld hits in %ld files (%s)", (long)[results hitCountOfSearch: group],
	      (long)[results fileCountOfSearch: group], status.stringValue.UTF8String);
	[results.window orderFront: nil];
	Pump(0.3);
	WindowShot(results.window, @"09-search-results");

	group = runFileSearch(@"*.txt *.cpp", NO, NO);
	CHECK([results hitCountOfSearch: group] == 3 && [results fileCountOfSearch: group] == 2, "without sub-folders: %ld hits",
	      (long)[results hitCountOfSearch: group]);
	group = runFileSearch(@"*.* !*.log", YES, YES);
	CHECK([results hitCountOfSearch: group] == 5 && [results fileCountOfSearch: group] == 4,
	      "hidden folders on, *.log excluded, binary file skipped: %ld hits in %ld files", (long)[results hitCountOfSearch: group],
	      (long)[results fileCountOfSearch: group]);
	matchCase.state = NSControlStateValueOn;
	group = runFileSearch(@"a.txt", YES, NO);
	CHECK([results hitCountOfSearch: group] == 1, "match case in files: %ld hits", (long)[results hitCountOfSearch: group]);
	matchCase.state = NSControlStateValueOff;

	// Opening a result from a file that is not open yet.
	group = runFileSearch(@"*.cpp", YES, NO);
	[outline selectRowIndexes: [NSIndexSet indexSetWithIndex: 2] byExtendingSelection: NO];
	[results openSelectedResult: nil];
	Document *opened = nil;
	for (int i = 0; i < 60 && !opened; ++i) {
		Pump(0.05);
		opened = (Document *)[[NSDocumentController sharedDocumentController]
			documentForURL: [NSURL fileURLWithPath: [root stringByAppendingPathComponent: @"sub/b.cpp"]]];
	}
	Pump(0.3);
	CHECK(opened && SciCall(opened.editorController.editor, SCI_GETSELECTIONSTART) == 4 &&
	      SciCall(opened.editorController.editor, SCI_GETSELECTIONEND) == 10, "opening a file result opens the file at the match");
	if (opened)
		Close(opened);

	((NSPanel *)panel.window).hidesOnDeactivate = NO;
	[panel showWithFindString: @"needle" focusReplace: NO];
	Pump(0.4);
	WindowShot(panel.window, @"05-find-panel");
	[panel.window orderOut: nil];
	[results.window orderOut: nil];
	Close(doc);
}

static void TestSettingsAndAppearance() {
	LOG("== Settings, font and tab decoration");
	AppSettings *settings = [AppSettings shared];
	Document *first = Open(WriteFile(@"settings.cpp", Utf8(kCppSample)));
	Document *second = NewDocument();
	ScintillaView *ed = first.editorController.editor;
	ScintillaView *ed2 = second.editorController.editor;
	[first.editorController.window makeKeyAndOrderFront: nil];
	CHECK([first.displayName isEqualToString: @"settings.cpp"], "tab title keeps the file extension: %s", first.displayName.UTF8String);

	settings.fontName = @"Courier";
	settings.fontSize = 17;
	Pump(0.2);
	char font[256] = "";
	SciCall(ed, SCI_STYLEGETFONT, SCE_C_WORD, reinterpret_cast<sptr_t>(font));
	CHECK(strcmp(font, "Courier") == 0 && SciCall(ed, SCI_STYLEGETSIZE, SCE_C_WORD) == 17, "font from Preferences applies to every style: %s %ld",
	      font, (long)SciCall(ed, SCI_STYLEGETSIZE, SCE_C_WORD));
	settings.fontName = @"";
	settings.fontSize = 0;
	Pump(0.2);
	SciCall(ed, SCI_STYLEGETFONT, STYLE_DEFAULT, reinterpret_cast<sptr_t>(font));
	CHECK(strcmp(font, "Menlo") == 0, "theme font is back: %s", font);

	settings.edgeColumn = 80;
	CHECK(SciCall(ed, SCI_GETEDGEMODE) == EDGE_LINE && SciCall(ed, SCI_GETEDGECOLUMN) == 80, "vertical edge at column 80");
	settings.edgeColumn = 0;
	CHECK(SciCall(ed, SCI_GETEDGEMODE) == EDGE_NONE, "vertical edge off");

	settings.highlightCurrentLine = NO;
	CHECK(!SciCall(ed, SCI_GETELEMENTISSET, SC_ELEMENT_CARET_LINE_BACK), "current line highlight off");
	settings.highlightCurrentLine = YES;
	CHECK(SciCall(ed, SCI_GETELEMENTISSET, SC_ELEMENT_CARET_LINE_BACK), "current line highlight on");

	SciCall(ed, SCI_ZOOMIN);
	Pump(0.1);
	CHECK(settings.zoom == 1 && SciCall(ed2, SCI_GETZOOM) == 1, "zoom is shared by every editor (%ld, %ld)", (long)settings.zoom,
	      (long)SciCall(ed2, SCI_GETZOOM));
	settings.zoom = 0;
	CHECK(SciCall(ed, SCI_GETZOOM) == 0, "zoom reset");

	CHECK(first.editorController.window.tab.accessoryView == nil, "no dot on the tab of a saved document");
	SciCall(ed, SCI_APPENDTEXT, 1, reinterpret_cast<sptr_t>("x"));
	Pump(0.1);
	CHECK(first.editorController.window.tab.accessoryView != nil, "unsaved document shows a dot on its tab");
	WindowShot(first.editorController.window, @"06-tabs");
	SciCall(ed, SCI_UNDO);
	Pump(0.1);
	CHECK(first.editorController.window.tab.accessoryView == nil, "dot goes away at the save point");

	settings.trimTrailingOnSave = YES;
	SciCall(ed, SCI_APPENDTEXT, 9, reinterpret_cast<sptr_t>("int z;  \t"));
	[first saveDocument: nil];
	Pump(0.6);
	NSString *saved = [NSString stringWithContentsOfURL: first.fileURL encoding: NSUTF8StringEncoding error: nil];
	CHECK([saved hasSuffix: @"}\nint z;"], "trailing whitespace trimmed on save");
	settings.trimTrailingOnSave = NO;

	PreferencesWindow *preferences = [PreferencesWindow shared];
	[preferences showWindow: nil];
	Pump(0.4);
	WindowShot(preferences.window, @"10-preferences");
	NSTabView *tabs = preferences.window.contentView.subviews.firstObject;
	if ([tabs isKindOfClass: [NSTabView class]]) {
		[tabs selectTabViewItemAtIndex: 1];
		Pump(0.3);
		WindowShot(preferences.window, @"11-preferences-editing");
		[tabs selectTabViewItemAtIndex: 2];
		Pump(0.3);
		WindowShot(preferences.window, @"12-preferences-appearance");
	}
	[preferences close];

	// Licenses and credits are one item away in Help.
	NSMenu *help = NSApp.helpMenu;
	CHECK([help indexOfItemWithTitle: @"License"] >= 0 && [help indexOfItemWithTitle: @"Acknowledgements"] >= 0,
	      "Help menu offers License and Acknowledgements");
	NSURL *acknowledgements = [[NSBundle mainBundle] URLForResource: @"Acknowledgements" withExtension: @"txt"];
	NSString *notices = acknowledgements ? [NSString stringWithContentsOfURL: acknowledgements encoding: NSUTF8StringEncoding error: nil] : nil;
	CHECK([notices containsString: @"Neil Hodgson"] && [notices containsString: @"SciTE"] &&
	      [notices containsString: @"GNU General Public License"], "third-party notices are bundled with the app");

	// Printing: the document as PDF.
	NSURL *pdf = [NSURL fileURLWithPath: [gOut stringByAppendingPathComponent: @"files/print.pdf"]];
	NSError *error = nil;
	NSPrintOperation *operation = [first printOperationWithSettings: @{NSPrintJobDisposition: NSPrintSaveJob, NSPrintJobSavingURL: pdf}
	                                                           error: &error];
	operation.showsPrintPanel = NO;
	operation.showsProgressPanel = NO;
	const BOOL printed = [operation runOperation];
	NSNumber *size = nil;
	[pdf getResourceValue: &size forKey: NSURLFileSizeKey error: nil];
	CHECK(printed && size.integerValue > 1000, "document prints to PDF (%ld bytes)", (long)size.integerValue);

	Close(second);
	Close(first);
}

static void TestSession() {
	LOG("== Session snapshot");
	CloseAll();
	SessionManager *session = [SessionManager shared];
	NSDocumentController *controller = [NSDocumentController sharedDocumentController];

	NSString *pathA = WriteFile(@"session-a.txt", Utf8("alpha\n"));
	NSString *pathC = WriteFile(@"session-c.py", Utf8("import os\nprint(os.name)\n"));
	Document *a = Open(pathA);
	SciCall(a.editorController.editor, SCI_APPENDTEXT, 2, reinterpret_cast<sptr_t>("X\n"));
	Document *b = NewDocument();
	Send(@selector(setLanguage:), b.editorController, 0, @"python");
	SetText(b, "unsaved \xC3\xA7 text\nsecond line\n");
	SciCall(b.editorController.editor, SCI_MARKERADD, 1, 20);
	NSString *untitledName = b.displayName;
	Document *c = Open(pathC);
	SciCall(c.editorController.editor, SCI_GOTOPOS, 12);
	[b.editorController.window makeKeyAndOrderFront: nil];
	Pump(0.3);
	CHECK(a.isDocumentEdited && b.isDocumentEdited && !c.isDocumentEdited, "two documents have unsaved changes");

	CHECK([session saveNow], "session written with the unsaved text");
	session.terminating = YES; // what quitting does: documents count as saved, backups stay
	CHECK(!a.isDocumentEdited && !b.isDocumentEdited, "quitting has nothing to ask about");
	CloseAll();
	session.terminating = NO;
	CHECK(controller.documents.count == 0, "all documents closed");

	const NSUInteger restored = [session restoreSession];
	Pump(0.5);
	CHECK(restored == 3 && controller.documents.count == 3, "three documents restored (%lu)", (unsigned long)restored);
	a = (Document *)[controller documentForURL: [NSURL fileURLWithPath: pathA]];
	c = (Document *)[controller documentForURL: [NSURL fileURLWithPath: pathC]];
	b = nil;
	for (Document *doc in controller.documents) {
		if (!doc.fileURL)
			b = doc;
	}
	CHECK(a && Text(a) == "alpha\nX\n" && a.isDocumentEdited, "file with unsaved changes: text restored and still unsaved");
	CHECK(b && Text(b) == "unsaved \xC3\xA7 text\nsecond line\n" && b.isDocumentEdited, "untitled document restored with its text");
	CHECK(b && [b.displayName isEqualToString: untitledName] && b.language->name == "python", "untitled document keeps its name and language (%s, %s)",
	      b.displayName.UTF8String, b ? b.language->name.c_str() : "");
	CHECK(b && (SciCall(b.editorController.editor, SCI_MARKERGET, 1) & (1 << 20)), "bookmark restored");
	CHECK(c && !c.isDocumentEdited && Text(c) == "import os\nprint(os.name)\n" && c.language->name == "python" &&
	      SciCall(c.editorController.editor, SCI_GETCURRENTPOS) == 12, "saved file reopened at the same caret position");
	NSWindow *window = a.editorController.window;
	CHECK(window.tabbedWindows.count == 3, "restored as tabs of one window (%lu)", (unsigned long)window.tabbedWindows.count);
	CHECK(window.tabGroup.selectedWindow == b.editorController.window, "the tab that was in front is selected again");
	NSArray<NSWindow *> *tabs = window.tabbedWindows;
	CHECK(tabs.count == 3 && tabs[0] == a.editorController.window && tabs[1] == b.editorController.window &&
	      tabs[2] == c.editorController.window, "tabs are in their old order");
	if (b)
		WindowShot(b.editorController.window, @"13-session-restored");

	// Scintilla's save point is the restored text, which is still not what is on disk.
	if (a) {
		ScintillaView *ed = a.editorController.editor;
		SciCall(ed, SCI_APPENDTEXT, 1, reinterpret_cast<sptr_t>("y"));
		SciCall(ed, SCI_UNDO);
		Pump(0.1);
		CHECK(a.isDocumentEdited, "undoing back to the restored text keeps the document unsaved");
		[a saveDocument: nil];
		Pump(0.6);
		NSString *onDisk = [NSString stringWithContentsOfFile: pathA encoding: NSUTF8StringEncoding error: nil];
		CHECK(!a.isDocumentEdited && [onDisk isEqualToString: @"alpha\nX\n"], "saving writes the restored text");
	}

	// The backup of a document goes away once it is saved or closed.
	[session saveNow];
	NSString *backups = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
		stringByAppendingPathComponent: [NSBundle mainBundle].bundleIdentifier] stringByAppendingPathComponent: @"backup"];
	NSUInteger count = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: backups error: nil].count;
	CHECK(count == 1, "only the untitled document still has a backup (%lu files)", (unsigned long)count);

	// A file that changed on disk while the app was closed, with unsaved edits in the session.
	CloseAll();
	Document *d = Open(pathA);
	SciCall(d.editorController.editor, SCI_APPENDTEXT, 4, reinterpret_cast<sptr_t>("mine"));
	Pump(0.1);
	[session saveNow];
	session.terminating = YES;
	CloseAll();
	session.terminating = NO;
	[Utf8("changed elsewhere\n") writeToFile: pathA atomically: YES];
	[[NSFileManager defaultManager] setAttributes: @{NSFileModificationDate: [NSDate dateWithTimeIntervalSinceNow: 60]}
	                                 ofItemAtPath: pathA error: nil];
	[session restoreSession];
	Pump(0.3);
	d = (Document *)[controller documentForURL: [NSURL fileURLWithPath: pathA]];
	CHECK(d && Text(d) == "alpha\nX\nmine" && d.isDocumentEdited, "unsaved edits win over the changed file: %s", d ? Text(d).c_str() : "");
	[d checkForExternalChange];
	NSWindow *dWindow = d.editorController.window;
	for (int i = 0; i < 30 && !dWindow.attachedSheet; ++i)
		Pump(0.1);
	CHECK(dWindow.attachedSheet != nil, "and the change made by the other program is pointed out");
	if (dWindow.attachedSheet) {
		[dWindow endSheet: dWindow.attachedSheet returnCode: NSAlertSecondButtonReturn];
		Pump(0.3);
	}

	// Turned off: nothing is kept.
	[AppSettings shared].rememberSession = NO;
	CHECK(![session saveNow], "with the option off, quitting asks as usual");
	count = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: backups error: nil].count;
	CHECK(count == 0, "no backups are kept (%lu files)", (unsigned long)count);
	CloseAll();
	CHECK([session restoreSession] == 0, "and nothing is restored");
	[AppSettings shared].rememberSession = YES;
	CloseAll();
}

// The real thing: quit through -[NSApplication terminate:] with unsaved documents open. It
// must not ask anything; `make test` then starts the app again (phase 2) to see them come back.
static void QuitWithUnsavedDocuments() {
	LOG("== Quitting with unsaved documents");
	CloseAll();
	Document *file = Open(WriteFile(@"relaunch.txt", Utf8("on disk\n")));
	SciCall(file.editorController.editor, SCI_APPENDTEXT, 8, reinterpret_cast<sptr_t>("not yet\n"));
	Document *untitled = NewDocument();
	SetText(untitled, "typed and never saved");
	WriteFile(@"relaunch-extra.txt", Utf8("opened from Finder at launch\n"));
	Pump(0.3);
	CHECK(file.isDocumentEdited && untitled.isDocumentEdited, "two unsaved documents before quitting");
	LOG("== %d passed, %d failed", gPasses, gFails);
	if (gFails) {
		fclose(gLog);
		exit(1);
	}
	// If quitting stops to ask, the app would sit there for ever: give up instead.
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
		LOG("FAIL: the app did not quit (it probably asked about the unsaved documents)");
		fclose(gLog);
		exit(1);
	});
	[NSApp terminate: nil];
}

// Phase 2: the app was started again, with a file to open as Finder would pass it.
static void RunRelaunchTests() {
	LOG("== Launching again after the quit");
	Pump(1.0);
	NSDocumentController *controller = [NSDocumentController sharedDocumentController];
	Document *file = nil, *untitled = nil, *extra = nil;
	for (Document *doc in controller.documents) {
		if (!doc.fileURL)
			untitled = doc;
		else if ([doc.fileURL.lastPathComponent isEqualToString: @"relaunch.txt"])
			file = doc;
		else if ([doc.fileURL.lastPathComponent isEqualToString: @"relaunch-extra.txt"])
			extra = doc;
	}
	CHECK(controller.documents.count == 3, "session documents plus the opened file, and no extra empty document (%lu)",
	      (unsigned long)controller.documents.count);
	CHECK(file && Text(file) == "on disk\nnot yet\n" && file.isDocumentEdited, "unsaved changes of the file are back");
	CHECK(untitled && Text(untitled) == "typed and never saved" && untitled.isDocumentEdited, "the never-saved document is back");
	CHECK(extra && Text(extra) == "opened from Finder at launch\n" && !extra.isDocumentEdited, "the file passed at launch is open");
	NSWindow *window = extra.editorController.window;
	CHECK(window.tabbedWindows.count == 3, "it joined the restored window as a tab (%lu tabs)", (unsigned long)window.tabbedWindows.count);
	CHECK(window.tabGroup.selectedWindow == window, "and it is the tab in front");
	NSString *onDisk = file ? [NSString stringWithContentsOfURL: file.fileURL encoding: NSUTF8StringEncoding error: nil] : nil;
	CHECK([onDisk isEqualToString: @"on disk\n"], "quitting did not write the unsaved changes to the file");
	if (window)
		WindowShot(window, @"14-relaunched");
	CloseAll();
	[[SessionManager shared] saveNow];
	LOG("== %d passed, %d failed", gPasses, gFails);
	fclose(gLog);
	exit(gFails ? 1 : 0);
}

static std::string FileText(NSString *path) {
	NSString *text = [NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: nil];
	return text ? ToStdString(text) : std::string("<missing>");
}

// iCloud Drive: a folder of the test stands for iCloud Drive › MacPad.
static void TestICloudDrive() {
	// Names of the copies kept for versions in conflict.
	NSSet<NSString *> *taken = [NSSet setWithArray: @[@"notes.txt", @"notes 2.txt", @"notes (iPhone).txt"]];
	BOOL (^exists)(NSString *) = ^BOOL(NSString *name) { return [taken containsObject: name]; };
	CHECK([UniqueFileName(@"todo.txt", exists) isEqualToString: @"todo.txt"], "a free name is kept");
	CHECK([UniqueFileName(@"notes.txt", exists) isEqualToString: @"notes 3.txt"], "a taken name gets a number (%s)",
	      UniqueFileName(@"notes.txt", exists).UTF8String);
	CHECK([ConflictCopyName(@"notes.txt", @"iPhone", exists) isEqualToString: @"notes (iPhone) 2.txt"],
	      "conflict copy named after the device (%s)", ConflictCopyName(@"notes.txt", @"iPhone", exists).UTF8String);
	CHECK([ConflictCopyName(@"Makefile", @"Mac/Pro: 2", exists) isEqualToString: @"Makefile (Mac-Pro- 2)"],
	      "no extension, and no / or : from the device name (%s)", ConflictCopyName(@"Makefile", @"Mac/Pro: 2", exists).UTF8String);
	CHECK([ConflictCopyName(@"a.txt", nil, exists) isEqualToString: @"a (other device).txt"], "a device without a name");

	NSString *folder = [gOut stringByAppendingPathComponent: @"icloud/MacPad"];
	[[NSFileManager defaultManager] createDirectoryAtPath: folder withIntermediateDirectories: YES attributes: nil error: nil];
	CloudDocuments *cloud = [CloudDocuments shared];
	CHECK(!cloud.active, "iCloud Drive is left alone by the self test until it asks");
	[AppSettings shared].syncWithICloud = YES;
	[cloud useFolderForTesting: [NSURL fileURLWithPath: folder isDirectory: YES]];
	CHECK(cloud.active, "iCloud Drive saving is on");

	// A new document becomes a file in the folder a moment after typing stops.
	Document *doc = NewDocument();
	NSString *path = [folder stringByAppendingPathComponent: [NSString stringWithFormat: @"new %ld.txt", (long)doc.untitledNumber]];
	SetText(doc, "first draft\n");
	Pump(1.0);
	CHECK(doc.hasUnsavedChanges && !doc.fileURL, "nothing is saved while typing goes on");
	Pump(1.8);
	CHECK([doc.fileURL.path isEqualToString: path], "new document saved in iCloud Drive as %s",
	      doc.fileURL.lastPathComponent.UTF8String ?: "(nothing)");
	CHECK(!doc.hasUnsavedChanges && FileText(path) == "first draft\n", "with its text, and shown as saved");

	// Later changes are saved by themselves, trailing spaces included (trimming is for saving by hand).
	[AppSettings shared].trimTrailingOnSave = YES;
	SetText(doc, "second draft   \n");
	Pump(2.8);
	[AppSettings shared].trimTrailingOnSave = NO;
	CHECK(FileText(path) == "second draft   \n" && !doc.hasUnsavedChanges, "a change is saved by itself (%s)", FileText(path).c_str());

	// Rename: the file moves, and a new extension picks the language.
	NSString *renamed = [folder stringByAppendingPathComponent: @"script.py"];
	[doc moveFileToURL: [NSURL fileURLWithPath: renamed]];
	Pump(0.5);
	NSFileManager *files = [NSFileManager defaultManager];
	CHECK([doc.fileURL.path isEqualToString: renamed] && [files fileExistsAtPath: renamed] && ![files fileExistsAtPath: path],
	      "Rename moves the file (%s)", doc.fileURL.lastPathComponent.UTF8String);
	CHECK(doc.language->name == "python", "renaming to .py makes it Python (%s)", doc.language->name.c_str());

	// A name in use is never replaced.
	NSString *other = [folder stringByAppendingPathComponent: @"other.txt"];
	[@"other\n" writeToFile: other atomically: YES encoding: NSUTF8StringEncoding error: nil];
	[doc moveFileToURL: [NSURL fileURLWithPath: other]];
	Pump(0.5);
	NSWindow *window = doc.windowForSheet;
	CHECK(window.attachedSheet != nil, "renaming over another file says why it cannot");
	if (window.attachedSheet)
		[window endSheet: window.attachedSheet];
	Pump(0.2);
	CHECK([doc.fileURL.path isEqualToString: renamed] && FileText(other) == "other\n", "and leaves both files alone");

	// Quitting saves at once what the pause did not.
	SetText(doc, "print('last words')\n");
	[cloud saveDocumentsNow];
	CHECK(FileText(renamed) == "print('last words')\n" && !doc.hasUnsavedChanges, "quitting saves documents in iCloud Drive first");
	Pump(2.8);

	// Files elsewhere keep the usual Save.
	NSString *outside = WriteFile(@"outside-icloud.txt", Utf8("outside\n"));
	Document *local = Open(outside);
	SetText(local, "changed\n");
	Pump(2.8);
	CHECK(local.hasUnsavedChanges && FileText(outside) == "outside\n", "a file outside iCloud Drive is not saved by itself");

	// Turned off in Settings: new documents stay untitled.
	[AppSettings shared].syncWithICloud = NO;
	CHECK(!cloud.active, "the setting turns it off");
	Document *untitled = NewDocument();
	SetText(untitled, "stays here\n");
	Pump(2.8);
	CHECK(untitled.fileURL == nil && untitled.hasUnsavedChanges, "with Sync off a new document stays untitled");

	Close(untitled);
	Close(local);
	Close(doc);
	[AppSettings shared].syncWithICloud = YES;
	[cloud useFolderForTesting: nil];
	CHECK(!cloud.active, "and the test leaves it off");
}

static void RunTests() {
	[NSApp activateIgnoringOtherApps: YES];
	Pump(0.5);
	// Close the untitled document opened at launch.
	CloseAll();

	@try {
		TestHighlightingAndThemes();
		TestLanguageDetection();
		TestEncodings();
		TestFindReplace();
		TestLineOperations();
		TestEditingCommands();
		TestTools();
		TestAutoCloseAndCompletion();
		TestMacro();
		TestFindAllAndFindInFiles();
		TestSettingsAndAppearance();
		TestDirtyAndReload();
		TestICloudDrive();
		TestSession();
	} @catch (NSException *exception) {
		gFails++;
		LOG("FAIL: exception %s: %s", exception.name.UTF8String, exception.reason.UTF8String);
	}
	QuitWithUnsavedDocuments();
	// Only reached when quitting was refused.
	LOG("FAIL: quitting was cancelled");
	fclose(gLog);
	exit(1);
}

__attribute__((constructor)) static void InstallSelfTest() {
	const char *out = getenv("MACPAD_SELFTEST");
	if (!out)
		return;
	gOut = [NSString stringWithUTF8String: out];
	[[NSFileManager defaultManager] createDirectoryAtPath: gOut withIntermediateDirectories: YES attributes: nil error: nil];
	const char *phase = getenv("MACPAD_SELFTEST_PHASE");
	const BOOL relaunch = phase && strcmp(phase, "2") == 0;
	gLog = fopen([gOut stringByAppendingPathComponent: @"log.txt"].UTF8String, relaunch ? "a" : "w");
	[[NSNotificationCenter defaultCenter] addObserverForName: NSApplicationDidFinishLaunchingNotification object: nil queue: nil
	                                              usingBlock: ^(NSNotification *notification) {
		// A run loop timer, not a main-queue block: the tests spin the run loop and
		// main-queue work (file watcher events) must still be able to run.
		[NSTimer scheduledTimerWithTimeInterval: 0.1 repeats: NO block: ^(NSTimer *timer) {
			if (relaunch)
				RunRelaunchTests();
			else
				RunTests();
		}];
	}];
}
