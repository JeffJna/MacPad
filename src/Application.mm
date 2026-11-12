// NSApplication subclass.
// This file is part of MacPad (GPL v3 or later).
#import "Application.h"

#import "CloudDocuments.h"
#import "MacroRecorder.h"
#import "SessionManager.h"

@implementation MacPadApplication
{
	BOOL _forwardingRecordedAction;
}

// Quit menu item, Dock menu, log out and restart all end up here.
- (void) terminate: (id) sender {
	// Documents in iCloud Drive are saved first, so that the other devices get the last changes.
	[[CloudDocuments shared] saveDocumentsNow];
	SessionManager *session = [SessionManager shared];
	// With every unsaved document stored in the session there is nothing to ask about:
	// the documents report themselves as saved and come back at the next launch.
	session.terminating = [session prepareForTermination];
	[super terminate: sender];
	session.terminating = NO; // only reached when quitting was cancelled
}

- (BOOL) sendAction: (SEL) action to: (id) target from: (id) sender {
	MacroRecorder *macro = [MacroRecorder shared];
	if (macro.recording && !_forwardingRecordedAction) {
		id receiver = [self targetForAction: action to: target from: sender];
		_forwardingRecordedAction = YES;
		const BOOL sent = receiver && [macro sendRecordedAction: action to: receiver from: sender];
		_forwardingRecordedAction = NO;
		if (sent)
			return YES;
	}
	return [super sendAction: action to: target from: sender];
}

@end
