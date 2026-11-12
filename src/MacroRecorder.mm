// Macro recording and playback.
// This file is part of MacPad (GPL v3 or later).
#import "MacroRecorder.h"

#include <string>
#include <vector>

#import "EditorWindowController.h"

namespace
{

struct MacroStep
{
	// Scintilla message...
	unsigned int message = 0;
	uptr_t wParam = 0;
	sptr_t lParam = 0;
	bool hasText = false;
	std::string text;
	// ...or a menu command of the editor window.
	SEL action = nullptr;
	NSInteger tag = 0;
	id representedObject = nil;
};

// Edit menu commands that Scintilla's Cocoa view performs without sending itself a message.
unsigned int MessageForStandardAction(SEL action)
{
	if (action == @selector(cut:))
		return SCI_CUT;
	if (action == @selector(copy:))
		return SCI_COPY;
	if (action == @selector(paste:))
		return SCI_PASTE;
	if (action == @selector(delete:) || action == @selector(clear:))
		return SCI_CLEAR;
	if (action == @selector(selectAll:))
		return SCI_SELECTALL;
	if (action == @selector(undo:))
		return SCI_UNDO;
	if (action == @selector(redo:))
		return SCI_REDO;
	return 0;
}

// Commands of EditorWindowController that make sense when replayed.
bool IsRecordableEditorAction(SEL action)
{
	static NSSet<NSString *> *names = [NSSet setWithArray: @[
		@"duplicateLine:", @"deleteLine:", @"moveLineUp:", @"moveLineDown:", @"joinLines:", @"splitLines:",
		@"insertBlankLineAbove:", @"insertBlankLineBelow:",
		@"sortLinesAscending:", @"sortLinesDescending:", @"sortLinesIgnoringCase:", @"sortLinesNumerically:",
		@"reverseLines:", @"removeDuplicateLines:", @"removeEmptyLines:",
		@"toggleLineComment:", @"toggleBlockComment:",
		@"toUpperCase:", @"toLowerCase:", @"toProperCase:", @"toSentenceCase:", @"invertCase:",
		@"trimTrailingSpace:", @"trimLeadingSpace:", @"trimLeadingAndTrailingSpace:", @"tabsToSpaces:", @"leadingSpacesToTabs:",
		@"setLineEnding:", @"insertDateTimeShort:", @"insertDateTimeLong:", @"insertDateTimeISO:",
		@"findNext:", @"findPrevious:", @"goToMatchingBrace:", @"selectToMatchingBrace:",
		@"toggleBookmark:", @"nextBookmark:", @"previousBookmark:", @"clearBookmarks:",
		@"selectNextOccurrence:", @"selectAllOccurrences:",
		@"base64Encode:", @"base64Decode:", @"urlEncode:", @"urlDecode:", @"formatJSON:", @"minifyJSON:",
		@"foldAll:", @"unfoldAll:", @"foldCurrentLevel:", @"unfoldCurrentLevel:",
	]];
	return [names containsObject: NSStringFromSelector(action)];
}

bool IsStringMessage(unsigned int message)
{
	return message == SCI_REPLACESEL || message == SCI_INSERTTEXT || message == SCI_SEARCHNEXT || message == SCI_SEARCHPREV;
}

bool IsCountedStringMessage(unsigned int message)
{
	return message == SCI_ADDTEXT || message == SCI_APPENDTEXT;
}

} // namespace

@implementation MacroRecorder
{
	std::vector<MacroStep> _steps;
	std::vector<MacroStep> _recordingSteps;
	__weak ScintillaView *_editor;
}

+ (instancetype) shared {
	static MacroRecorder *recorder;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		recorder = [[MacroRecorder alloc] init];
	});
	return recorder;
}

- (BOOL) hasMacro {
	return !_steps.empty();
}

- (NSUInteger) stepCount {
	return _steps.size();
}

- (void) startRecordingInEditor: (ScintillaView *) editor {
	if (_recording || _playing || !editor)
		return;
	_recordingSteps.clear();
	_editor = editor;
	_recording = YES;
	SciCall(editor, SCI_STARTRECORD);
}

- (void) stopRecording {
	if (!_recording)
		return;
	_recording = NO;
	ScintillaView *editor = _editor;
	if (editor)
		SciCall(editor, SCI_STOPRECORD);
	_editor = nil;
	// An empty recording keeps the previous macro.
	if (!_recordingSteps.empty())
		_steps.swap(_recordingSteps);
	_recordingSteps.clear();
}

- (void) recordMessage: (unsigned int) message wParam: (uptr_t) wParam lParam: (sptr_t) lParam {
	if (!_recording)
		return;
	MacroStep step;
	step.message = message;
	step.wParam = wParam;
	step.lParam = lParam;
	const char *text = reinterpret_cast<const char *>(lParam);
	if (IsStringMessage(message) && text) {
		step.hasText = true;
		step.text = text;
	} else if (IsCountedStringMessage(message) && text) {
		step.hasText = true;
		step.text.assign(text, wParam);
	}
	_recordingSteps.push_back(step);
}

- (BOOL) sendRecordedAction: (SEL) action to: (id) receiver from: (id) sender {
	if (!_recording)
		return NO;
	ScintillaView *editor = _editor;

	// Cut, Copy, Paste... performed by the view of the editor being recorded.
	if (const unsigned int message = MessageForStandardAction(action)) {
		if (![receiver isKindOfClass: [NSView class]] || !editor || ![(NSView *)receiver isDescendantOf: editor])
			return NO;
		MacroStep step;
		step.message = message;
		_recordingSteps.push_back(step);
		return NO; // the view still has to perform it
	}

	if (!IsRecordableEditorAction(action) || ![receiver isKindOfClass: [EditorWindowController class]] ||
	    ((EditorWindowController *)receiver).editor != editor)
		return NO;

	// The command is replayed as a whole, so the Scintilla messages it sends are not recorded.
	SciCall(editor, SCI_STOPRECORD);
	[NSApp sendAction: action to: receiver from: sender];
	if (_recording && _editor == editor)
		SciCall(editor, SCI_STARTRECORD);
	MacroStep step;
	step.action = action;
	if ([sender respondsToSelector: @selector(tag)])
		step.tag = [sender tag];
	if ([sender respondsToSelector: @selector(representedObject)])
		step.representedObject = [sender representedObject];
	_recordingSteps.push_back(step);
	return YES;
}

- (void) playOnceInController: (EditorWindowController *) controller {
	ScintillaView *editor = controller.editor;
	for (const MacroStep &step : _steps) {
		if (step.action) {
			if (![controller respondsToSelector: step.action])
				continue;
			NSMenuItem *item = [[NSMenuItem alloc] init];
			item.tag = step.tag;
			item.representedObject = step.representedObject;
			((void (*)(id, SEL, id))[controller methodForSelector: step.action])(controller, step.action, item);
		} else {
			SciCall(editor, step.message, step.wParam, step.hasText ? reinterpret_cast<sptr_t>(step.text.c_str()) : step.lParam);
		}
	}
}

- (void) playInController: (EditorWindowController *) controller times: (NSInteger) times {
	if (_recording || _playing || _steps.empty() || !controller)
		return;
	ScintillaView *editor = controller.editor;
	_playing = YES;
	SciCall(editor, SCI_BEGINUNDOACTION);
	if (times > 0) {
		for (NSInteger i = 0; i < times; ++i)
			[self playOnceInController: controller];
	} else {
		// Until the end of the file: stop on the last line, or as soon as a run changes nothing.
		for (NSInteger i = 0; i < 1000000; ++i) {
			const sptr_t caret = SciCall(editor, SCI_GETCURRENTPOS);
			const sptr_t length = SciCall(editor, SCI_GETLENGTH);
			[self playOnceInController: controller];
			const sptr_t newCaret = SciCall(editor, SCI_GETCURRENTPOS);
			const sptr_t lastLine = SciCall(editor, SCI_GETLINECOUNT) - 1;
			if (SciCall(editor, SCI_LINEFROMPOSITION, newCaret) >= lastLine)
				break;
			if (newCaret == caret && SciCall(editor, SCI_GETLENGTH) == length)
				break;
		}
	}
	SciCall(editor, SCI_ENDUNDOACTION);
	_playing = NO;
}

@end
