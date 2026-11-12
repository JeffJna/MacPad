// Window scene.
// This file is part of MacPad (GPL v3 or later).
#import "SceneDelegate.h"

#import "DocumentBrowserViewController.h"
#import "EditorViewController.h"

@implementation SceneDelegate
{
	DocumentBrowserViewController *_browser;
}

- (void) scene: (UIScene *) scene willConnectToSession: (UISceneSession *) session options: (UISceneConnectionOptions *) options {
	if (![scene isKindOfClass: [UIWindowScene class]])
		return;
	_browser = [[DocumentBrowserViewController alloc] init];
	self.window = [[UIWindow alloc] initWithWindowScene: (UIWindowScene *)scene];
	self.window.rootViewController = _browser;
	[self.window makeKeyAndVisible];

	NSURL *opened = options.URLContexts.anyObject.URL;
	// `-open <path>` on the command line (simctl launch) opens a file directly, for testing.
	NSString *path = [[NSUserDefaults standardUserDefaults] volatileDomainForName: NSArgumentDomain][@"open"];
	dispatch_async(dispatch_get_main_queue(), ^{
		if ([path isKindOfClass: [NSString class]] && path.length)
			[self->_browser presentDocumentAtURL: [NSURL fileURLWithPath: path]];
		else if (opened)
			[self openURL: opened];
		else
			[self->_browser reopenLastDocument];
	});
}

- (void) scene: (UIScene *) scene openURLContexts: (NSSet<UIOpenURLContext *> *) contexts {
	NSURL *url = contexts.anyObject.URL;
	if (url)
		[self openURL: url];
}

// A file shared from another app (or "Open in MacPad" in Files).
- (void) openURL: (NSURL *) url {
	if (!url.isFileURL)
		return;
	[_browser revealDocumentAtURL: url importIfNeeded: YES completion: ^(NSURL *revealed, NSError *error) {
		if (revealed)
			[self->_browser presentDocumentAtURL: revealed];
	}];
}

- (void) sceneDidEnterBackground: (UIScene *) scene {
	[_browser.currentEditor saveNow];
}

@end
