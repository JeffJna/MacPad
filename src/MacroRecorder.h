// Macro recording and playback (Macro menu): typing and caret movement come
// from Scintilla's own macro notifications, menu commands are recorded by their action.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

#import "SciUtil.h"

@class EditorWindowController;

@interface MacroRecorder : NSObject

+ (instancetype) shared;

@property (nonatomic, readonly) BOOL recording;
@property (nonatomic, readonly) BOOL playing;
@property (nonatomic, readonly) BOOL hasMacro;
@property (nonatomic, readonly) NSUInteger stepCount;

- (void) startRecordingInEditor: (ScintillaView *) editor;
- (void) stopRecording;

// From SCN_MACRORECORD.
- (void) recordMessage: (unsigned int) message wParam: (uptr_t) wParam lParam: (sptr_t) lParam;

// Sends a menu command, recording it when a macro is being recorded and the command is one
// that macros replay. Returns NO when the command is not handled here at all (send it normally).
- (BOOL) sendRecordedAction: (SEL) action to: (id) receiver from: (id) sender;

// Replays the macro `times` times, or until the caret reaches the last line when `times` is 0.
- (void) playInController: (EditorWindowController *) controller times: (NSInteger) times;

@end
