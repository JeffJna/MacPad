// About MacPad.
// This file is part of MacPad (GPL v3 or later).
#import "AboutViewController.h"

@implementation AboutViewController

- (void) viewDidLoad {
	[super viewDidLoad];
	self.title = @"About MacPad";
	self.view.backgroundColor = [UIColor systemBackgroundColor];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem: UIBarButtonSystemItemDone
	                                                                                       target: self action: @selector(done)];
	UITextView *text = [[UITextView alloc] initWithFrame: self.view.bounds];
	text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	text.editable = NO;
	text.textContainerInset = UIEdgeInsetsMake(16, 12, 24, 12);
	[self.view addSubview: text];

	NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"";
	NSMutableAttributedString *content = [[NSMutableAttributedString alloc] init];
	auto append = [&](NSString *string, UIFont *font, UIColor *color) {
		[content appendAttributedString: [[NSAttributedString alloc] initWithString: string attributes: @{
			NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
	};
	append(@"MacPad\n", [UIFont systemFontOfSize: 28 weight: UIFontWeightBold], [UIColor labelColor]);
	append([NSString stringWithFormat: @"Version %@\n\n", version], [UIFont preferredFontForTextStyle: UIFontTextStyleSubheadline],
	       [UIColor secondaryLabelColor]);
	append(@"A text and code editor for iPhone, iPad and Mac.\n\nFree software under the GNU General Public License, "
	       @"version 3 or later, with ABSOLUTELY NO WARRANTY.\n\n",
	       [UIFont preferredFontForTextStyle: UIFontTextStyleBody], [UIColor labelColor]);
	UIFont *mono = [UIFont monospacedSystemFontOfSize: 11 weight: UIFontWeightRegular];
	for (NSString *name in @[@"Acknowledgements", @"LICENSE"]) {
		NSString *path = [[NSBundle mainBundle] pathForResource: name ofType: [name isEqualToString: @"LICENSE"] ? nil : @"txt"];
		NSString *body = path ? [NSString stringWithContentsOfFile: path encoding: NSUTF8StringEncoding error: nil] : nil;
		if (body.length)
			append([body stringByAppendingString: @"\n\n"], mono, [UIColor secondaryLabelColor]);
	}
	text.attributedText = content;
}

- (void) done {
	[self dismissViewControllerAnimated: YES completion: nil];
}

@end
