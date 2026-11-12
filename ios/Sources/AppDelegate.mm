// Application delegate.
// This file is part of MacPad (GPL v3 or later).
#import "AppDelegate.h"

#import "Common.h"

#include "LanguageCatalog.h"
#include "Theme.h"

@implementation AppDelegate

- (BOOL) application: (UIApplication *) application willFinishLaunchingWithOptions: (NSDictionary *) launchOptions {
	NSString *resources = [NSBundle mainBundle].resourcePath;
	LanguageCatalog::Shared().Load(ToStdString([resources stringByAppendingPathComponent: @"languages.json"]));
	StyleMap::Shared().Load(ToStdString([resources stringByAppendingPathComponent: @"stylemap.json"]));
	return YES;
}

- (UISceneConfiguration *) application: (UIApplication *) application
configurationForConnectingSceneSession: (UISceneSession *) session
                               options: (UISceneConnectionOptions *) options {
	return [[UISceneConfiguration alloc] initWithName: @"Default" sessionRole: session.role];
}

@end
