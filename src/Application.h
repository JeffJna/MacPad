// NSApplication subclass: quits without asking when the session keeps unsaved text, and
// lets the macro recorder see menu commands.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <Cocoa/Cocoa.h>

@interface MacPadApplication : NSApplication
@end
