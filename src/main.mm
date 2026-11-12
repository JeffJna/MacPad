// Entry point of MacPad (GPL v3 or later).
#import <Cocoa/Cocoa.h>

#import "AppDelegate.h"
#import "Application.h"

int main(int argc, const char *argv[])
{
	@autoreleasepool {
		static AppDelegate *delegate; // NSApplication only keeps a weak reference
		delegate = [[AppDelegate alloc] init];
		[MacPadApplication sharedApplication].delegate = delegate;
		return NSApplicationMain(argc, argv);
	}
}
