// The iOS editor.
// This file is part of MacPad (GPL v3 or later).
#import "EditorViewController.h"

#include <algorithm>
#include <memory>
#include <vector>

#import "AboutViewController.h"
#import "Common.h"
#import "EditorSettings.h"
#import "EditorTextView.h"
#import "TextDocument.h"

#include "Highlighter.h"
#include "LanguageCatalog.h"
#include "TextEncoding.h"
#include "TextTools.h"
#include "Theme.h"

namespace
{

// Larger texts are shown without colours: re-colouring them while typing would lag.
const NSUInteger kMaxHighlightLength = 2 * 1024 * 1024;
const unsigned char kUnstyled = 0xFF;

bool IsWordCharacter(unichar c)
{
	return [[NSCharacterSet alphanumericCharacterSet] characterIsMember: c] || c == '_';
}

bool IsCloser(unichar c)
{
	return c == ')' || c == ']' || c == '}';
}

NSString *LineEndingShortName(LineEnding eol)
{
	switch (eol)
	{
		case LineEnding::CRLF: return @"CRLF";
		case LineEnding::CR: return @"CR";
		case LineEnding::LF: return @"LF";
	}
	return @"LF";
}

// The text as UTF-8, and for every UTF-16 unit the byte where its character starts.
std::string UTF8WithOffsets(NSString *text, std::vector<uint32_t> &byteOfUnit)
{
	const NSUInteger length = text.length;
	byteOfUnit.resize(length);
	std::string utf8;
	utf8.reserve(length + length / 4);
	std::vector<unichar> units(length);
	[text getCharacters: units.data() range: NSMakeRange(0, length)];
	for (NSUInteger i = 0; i < length; ++i) {
		const unichar c = units[i];
		byteOfUnit[i] = static_cast<uint32_t>(utf8.size());
		uint32_t code = c;
		if (c >= 0xD800 && c <= 0xDBFF && i + 1 < length && units[i + 1] >= 0xDC00 && units[i + 1] <= 0xDFFF) {
			code = 0x10000 + ((c - 0xD800) << 10) + (units[i + 1] - 0xDC00);
			byteOfUnit[++i] = static_cast<uint32_t>(utf8.size());
		} else if (c >= 0xD800 && c <= 0xDFFF) {
			code = 0xFFFD; // a lone surrogate
		}
		if (code < 0x80) {
			utf8 += static_cast<char>(code);
		} else if (code < 0x800) {
			utf8 += static_cast<char>(0xC0 | (code >> 6));
			utf8 += static_cast<char>(0x80 | (code & 0x3F));
		} else if (code < 0x10000) {
			utf8 += static_cast<char>(0xE0 | (code >> 12));
			utf8 += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
			utf8 += static_cast<char>(0x80 | (code & 0x3F));
		} else {
			utf8 += static_cast<char>(0xF0 | (code >> 18));
			utf8 += static_cast<char>(0x80 | ((code >> 12) & 0x3F));
			utf8 += static_cast<char>(0x80 | ((code >> 6) & 0x3F));
			utf8 += static_cast<char>(0x80 | (code & 0x3F));
		}
	}
	return utf8;
}

} // namespace

@interface EditorViewController () <UITextViewDelegate, NSTextStorageDelegate>
@end

@implementation EditorViewController
{
	TextDocument *_document;
	EditorTextView *_textView;
	std::shared_ptr<Theme> _theme;
	// Style applied to each UTF-16 unit of the text, kUnstyled where an edit made it unknown.
	std::vector<unsigned char> _appliedStyles;
	NSMutableDictionary<NSNumber *, NSDictionary *> *_styleAttributes;
	NSDictionary *_baseAttributes;
	UIFont *_regularFont;
	UIFont *_boldFont;
	UIFont *_italicFont;
	UIFont *_boldItalicFont;
	UILabel *_titleLabel;
	UILabel *_statusLabel;
	BOOL _programmaticEdit;
}

- (instancetype) initWithDocument: (TextDocument *) document {
	self = [super initWithNibName: nil bundle: nil];
	if (self) {
		_document = document;
		_styleAttributes = [NSMutableDictionary dictionary];
	}
	return self;
}

- (void) dealloc {
	[[NSNotificationCenter defaultCenter] removeObserver: self];
}

#pragma mark - View

- (void) viewDidLoad {
	[super viewDidLoad];

	_textView = [EditorTextView editorTextView];
	_textView.translatesAutoresizingMaskIntoConstraints = NO;
	_textView.delegate = self;
	_textView.textStorage.delegate = self;
	// Code, not prose: no corrections, capitals, smart quotes or dashes.
	_textView.autocorrectionType = UITextAutocorrectionTypeNo;
	_textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
	_textView.spellCheckingType = UITextSpellCheckingTypeNo;
	_textView.smartQuotesType = UITextSmartQuotesTypeNo;
	_textView.smartDashesType = UITextSmartDashesTypeNo;
	_textView.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
	_textView.dataDetectorTypes = UIDataDetectorTypeNone;
	_textView.alwaysBounceVertical = YES;
	_textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
	_textView.textContainerInset = UIEdgeInsetsMake(8, 0, 24, 8);
	_textView.findInteractionEnabled = YES;
	_textView.inputAccessoryView = [self accessoryBar];
	[self.view addSubview: _textView];
	// Without a keyboard the text runs to the bottom edge; the text view keeps clear of the home indicator itself.
	if (@available(iOS 17.0, *))
		self.view.keyboardLayoutGuide.usesBottomSafeArea = NO;
	[NSLayoutConstraint activateConstraints: @[
		[_textView.topAnchor constraintEqualToAnchor: self.view.safeAreaLayoutGuide.topAnchor],
		[_textView.leadingAnchor constraintEqualToAnchor: self.view.leadingAnchor],
		[_textView.trailingAnchor constraintEqualToAnchor: self.view.trailingAnchor],
		[_textView.bottomAnchor constraintEqualToAnchor: self.view.keyboardLayoutGuide.topAnchor],
	]];

	[self buildNavigationItems];
	[self applySettings];
	[self loadDocumentText];

	__weak EditorViewController *weakSelf = self;
	_document.reloadHandler = ^{
		[weakSelf loadDocumentText];
	};
	_document.saveErrorHandler = ^(NSError *error) {
		[weakSelf showSaveError: error];
	};
	[[NSNotificationCenter defaultCenter] addObserver: self selector: @selector(settingsDidChange:)
	                                             name: EditorSettingsDidChangeNotification object: nil];
}

- (void) viewDidAppear: (BOOL) animated {
	[super viewDidAppear: animated];
	[self restorePosition];
}

- (void) viewWillDisappear: (BOOL) animated {
	[super viewWillDisappear: animated];
	[self rememberPosition];
}

- (void) traitCollectionDidChange: (UITraitCollection *) previous {
	[super traitCollectionDidChange: previous];
	if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection: previous])
		[self applySettings];
}

- (void) buildNavigationItems {
	_titleLabel = [[UILabel alloc] init];
	_titleLabel.font = [UIFont preferredFontForTextStyle: UIFontTextStyleHeadline];
	_titleLabel.textAlignment = NSTextAlignmentCenter;
	_titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
	_statusLabel = [[UILabel alloc] init];
	_statusLabel.font = [UIFont monospacedDigitSystemFontOfSize: 11 weight: UIFontWeightRegular];
	_statusLabel.textColor = [UIColor secondaryLabelColor];
	_statusLabel.textAlignment = NSTextAlignmentCenter;
	_statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
	UIStackView *title = [[UIStackView alloc] initWithArrangedSubviews: @[_titleLabel, _statusLabel]];
	title.axis = UILayoutConstraintAxisVertical;
	title.alignment = UIStackViewAlignmentCenter;
	self.navigationItem.titleView = title;

	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle: @"Files" style: UIBarButtonItemStylePlain
	                                                                        target: self action: @selector(closeDocument)];
	UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage: [UIImage systemImageNamed: @"ellipsis.circle"] menu: nil];
	__weak EditorViewController *weakSelf = self;
	more.menu = [UIMenu menuWithChildren: @[[UIDeferredMenuElement elementWithUncachedProvider: ^(void (^completion)(NSArray<UIMenuElement *> *)) {
		completion([weakSelf menuElements] ?: @[]);
	}]]];
	more.accessibilityLabel = @"More";
	UIBarButtonItem *find = [[UIBarButtonItem alloc] initWithImage: [UIImage systemImageNamed: @"magnifyingglass"] style: UIBarButtonItemStylePlain
	                                                        target: self action: @selector(showFind)];
	find.accessibilityLabel = @"Find";
	self.navigationItem.rightBarButtonItems = @[more, find];
}

#pragma mark - Document text

- (void) loadDocumentText {
	const NSRange selection = _textView.selectedRange;
	_programmaticEdit = YES;
	_textView.text = _document.text;
	_programmaticEdit = NO;
	NSTextStorage *storage = _textView.textStorage;
	[storage setAttributes: _baseAttributes range: NSMakeRange(0, storage.length)];
	_appliedStyles.assign(storage.length, kUnstyled);
	const NSUInteger length = storage.length;
	_textView.selectedRange = NSMakeRange(std::min(selection.location, length), 0);
	[_textView textDidChange];
	[self highlightNow];
	[self updateStatus];
}

- (void) textChanged {
	[_document textDidChange: _textView.textStorage.string];
	[_textView textDidChange];
	[self scheduleHighlight];
	[self updateStatus];
}

// Keeps the per-unit styles lined up with the text after any edit (typing, paste, undo).
- (void) textStorage: (NSTextStorage *) textStorage
  didProcessEditing: (NSTextStorageEditActions) editedMask
              range: (NSRange) editedRange
     changeInLength: (NSInteger) delta {
	if (!(editedMask & NSTextStorageEditedCharacters))
		return;
	const NSInteger oldLength = static_cast<NSInteger>(editedRange.length) - delta;
	if (editedRange.location <= _appliedStyles.size() && oldLength >= 0 &&
	    editedRange.location + static_cast<NSUInteger>(oldLength) <= _appliedStyles.size()) {
		auto start = _appliedStyles.begin() + static_cast<long>(editedRange.location);
		_appliedStyles.erase(start, start + oldLength);
		_appliedStyles.insert(_appliedStyles.begin() + static_cast<long>(editedRange.location), editedRange.length, kUnstyled);
	}
	if (_appliedStyles.size() != textStorage.length)
		_appliedStyles.assign(textStorage.length, kUnstyled);
	if (!_programmaticEdit) {
		[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(textChanged) object: nil];
		[self performSelector: @selector(textChanged) withObject: nil afterDelay: 0];
	}
}

- (void) saveNow {
	[_document textDidChange: _textView.textStorage.string];
	[_document autosaveWithCompletionHandler: nil];
}

- (void) closeDocument {
	[self rememberPosition];
	[_document textDidChange: _textView.textStorage.string];
	__weak EditorViewController *weakSelf = self;
	[_document closeWithCompletionHandler: ^(BOOL success) {
		EditorViewController *strongSelf = weakSelf;
		[strongSelf dismissViewControllerAnimated: YES completion: nil];
		if (strongSelf.closeHandler)
			strongSelf.closeHandler();
	}];
}

- (void) showSaveError: (NSError *) error {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"The file could not be saved"
	                                                               message: error.localizedDescription
	                                                        preferredStyle: UIAlertControllerStyleAlert];
	if (_document.encoding.kind != FileEncoding::UTF8) {
		[alert addAction: [UIAlertAction actionWithTitle: @"Save as UTF-8" style: UIAlertActionStyleDefault handler: ^(UIAlertAction *action) {
			self->_document.encoding = FileEncoding::Make(FileEncoding::UTF8);
			[self saveNow];
			[self updateStatus];
		}]];
	}
	[alert addAction: [UIAlertAction actionWithTitle: @"OK" style: UIAlertActionStyleCancel handler: nil]];
	[self presentViewController: alert animated: YES completion: nil];
}

// The caret position of each file is remembered between visits.
- (NSString *) positionKey {
	return [@"position:" stringByAppendingString: _document.fileURL.path ?: @""];
}

- (void) rememberPosition {
	[[NSUserDefaults standardUserDefaults] setInteger: static_cast<NSInteger>(_textView.selectedRange.location) forKey: [self positionKey]];
}

- (void) restorePosition {
	const NSUInteger location = static_cast<NSUInteger>(std::max<NSInteger>(0, [[NSUserDefaults standardUserDefaults] integerForKey: [self positionKey]]));
	if (location == 0 || location > _textView.textStorage.length)
		return;
	_textView.selectedRange = NSMakeRange(location, 0);
	[_textView scrollRangeToVisible: _textView.selectedRange];
}

#pragma mark - Settings and theme

- (void) settingsDidChange: (NSNotification *) notification {
	[self applySettings];
}

- (void) applySettings {
	EditorSettings *settings = [EditorSettings shared];
	const BOOL automatic = [settings.themeName isEqualToString: kAutomaticTheme];
	BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
	if (automatic) {
		self.navigationController.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
		dark = self.navigationController.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ||
		       (!self.navigationController && dark);
	}
	_theme = [settings themeForDarkAppearance: dark];
	if (!automatic)
		self.navigationController.overrideUserInterfaceStyle = _theme->IsDark() ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;

	const CGFloat size = settings.fontSize;
	_regularFont = [UIFont monospacedSystemFontOfSize: size weight: UIFontWeightRegular];
	_boldFont = [UIFont monospacedSystemFontOfSize: size weight: UIFontWeightSemibold];
	UIFontDescriptor *italic = [_regularFont.fontDescriptor fontDescriptorWithSymbolicTraits: UIFontDescriptorTraitItalic];
	_italicFont = italic ? [UIFont fontWithDescriptor: italic size: size] : _regularFont;
	UIFontDescriptor *boldItalic = [_boldFont.fontDescriptor fontDescriptorWithSymbolicTraits: UIFontDescriptorTraitItalic | UIFontDescriptorTraitBold];
	_boldItalicFont = boldItalic ? [UIFont fontWithDescriptor: boldItalic size: size] : _boldFont;

	UIColor *background = ColorFromRGB(_theme->Background());
	UIColor *foreground = ColorFromRGB(_theme->Foreground());
	NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
	const CGFloat space = [@" " sizeWithAttributes: @{NSFontAttributeName: _regularFont}].width;
	paragraph.defaultTabInterval = space * settings.tabWidth;
	paragraph.tabStops = @[];
	paragraph.lineBreakMode = settings.wrapLines ? NSLineBreakByWordWrapping : NSLineBreakByClipping;
	_baseAttributes = @{NSFontAttributeName: _regularFont, NSForegroundColorAttributeName: foreground,
	                    NSParagraphStyleAttributeName: paragraph};
	[_styleAttributes removeAllObjects];

	self.view.backgroundColor = background;
	_textView.backgroundColor = background;
	_textView.font = _regularFont;
	_textView.tintColor = ColorFromRGB(_theme->Color("caret", _theme->Foreground()));
	_textView.keyboardAppearance = _theme->IsDark() ? UIKeyboardAppearanceDark : UIKeyboardAppearanceLight;
	_textView.typingAttributes = _baseAttributes;
	_textView.showsLineNumbers = settings.showLineNumbers;
	_textView.gutterColor = ColorFromRGB(_theme->Color("gutter", _theme->Background()));
	_textView.lineNumberColor = ColorFromRGB(_theme->Color("lineNumber", 0x909090));
	_textView.currentLineNumberColor = foreground;

	// Long lines either wrap or scroll sideways.
	NSTextContainer *container = _textView.textContainer;
	container.widthTracksTextView = settings.wrapLines;
	if (!settings.wrapLines)
		container.size = CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
	_textView.showsHorizontalScrollIndicator = !settings.wrapLines;

	NSTextStorage *storage = _textView.textStorage;
	[storage setAttributes: _baseAttributes range: NSMakeRange(0, storage.length)];
	_appliedStyles.assign(storage.length, kUnstyled);
	[self highlightNow];
	[_textView setNeedsLayout];
}

#pragma mark - Highlighting

- (void) scheduleHighlight {
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(highlightNow) object: nil];
	[self performSelector: @selector(highlightNow) withObject: nil afterDelay: 0.12];
}

- (NSDictionary *) attributesForStyle: (unsigned char) style roles: (const std::vector<StyleRole> *) roles {
	NSNumber *key = @(style);
	NSDictionary *cached = _styleAttributes[key];
	if (cached)
		return cached;
	const StyleRole role = roles && style < roles->size() ? (*roles)[style] : StyleRole::Default;
	NSDictionary *attributes = _baseAttributes;
	if (role != StyleRole::Default) {
		const ThemeStyle &spec = _theme->Style(role);
		UIFont *font = spec.bold ? (spec.italic ? _boldItalicFont : _boldFont) : (spec.italic ? _italicFont : _regularFont);
		NSMutableDictionary *styled = [_baseAttributes mutableCopy];
		styled[NSFontAttributeName] = font;
		styled[NSForegroundColorAttributeName] = ColorFromRGB(spec.color);
		if (spec.underline)
			styled[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
		if (spec.hasBackground)
			styled[NSBackgroundColorAttributeName] = ColorFromRGB(spec.background);
		attributes = styled;
	}
	_styleAttributes[key] = attributes;
	return attributes;
}

// Runs the lexer over the whole text and changes the attributes of the parts whose style changed.
- (void) highlightNow {
	[NSObject cancelPreviousPerformRequestsWithTarget: self selector: @selector(highlightNow) object: nil];
	if (!_theme || !_textView)
		return;
	NSTextStorage *storage = _textView.textStorage;
	NSString *text = storage.string;
	const NSUInteger length = text.length;
	if (_appliedStyles.size() != length)
		_appliedStyles.assign(length, kUnstyled);

	const Language &language = *_document.language;
	std::vector<unsigned char> unitStyles(length, 0);
	const std::vector<StyleRole> *roles = StyleMap::Shared().RolesForLexer(language.lexer);
	if (length && length <= kMaxHighlightLength && language.lexer != "null") {
		std::vector<uint32_t> byteOfUnit;
		const std::string utf8 = UTF8WithOffsets(text, byteOfUnit);
		const std::vector<unsigned char> styles = StyleText(utf8, language);
		for (NSUInteger i = 0; i < length; ++i)
			unitStyles[i] = byteOfUnit[i] < styles.size() ? styles[byteOfUnit[i]] : 0;
	}

	_programmaticEdit = YES;
	[storage beginEditing];
	NSUInteger i = 0;
	while (i < length) {
		if (unitStyles[i] == _appliedStyles[i]) {
			++i;
			continue;
		}
		const unsigned char style = unitStyles[i];
		NSUInteger end = i + 1;
		while (end < length && unitStyles[end] == style && unitStyles[end] != _appliedStyles[end])
			++end;
		[storage setAttributes: [self attributesForStyle: style roles: roles] range: NSMakeRange(i, end - i)];
		i = end;
	}
	[storage endEditing];
	_programmaticEdit = NO;
	_appliedStyles.swap(unitStyles);
}

#pragma mark - Status

- (void) updateStatus {
	// The full file name: an editor should not hide extensions.
	_titleLabel.text = _document.fileURL.lastPathComponent ?: _document.localizedName ?: @"Untitled";
	const NSRange selection = _textView.selectedRange;
	const NSUInteger line = [_textView lineForLocation: selection.location];
	const NSUInteger column = selection.location - [_textView locationOfLine: line];
	NSMutableString *status = [NSMutableString stringWithFormat: @"Ln %lu, Col %lu", (unsigned long)line + 1, (unsigned long)column + 1];
	if (selection.length)
		[status appendFormat: @" (%lu sel)", (unsigned long)selection.length];
	[status appendFormat: @" · %@ · %@ · %@", ToNSString(_document.language->menuName), _document.encoding.DisplayName(),
	                      LineEndingShortName(_document.lineEnding)];
	_statusLabel.text = status;
	[self.navigationItem.titleView setNeedsLayout];
}

- (void) textViewDidChangeSelection: (UITextView *) textView {
	[self updateStatus];
	[_textView setNeedsLayout]; // the current line number is drawn in bold
}

#pragma mark - Typing: indentation and pairs

- (NSString *) indentUnit {
	EditorSettings *settings = [EditorSettings shared];
	return settings.useSpaces ? [@"" stringByPaddingToLength: static_cast<NSUInteger>(settings.tabWidth) withString: @" " startingAtIndex: 0] : @"\t";
}

// Replaces text through UITextInput, so that the change can be undone.
- (void) replaceRange: (NSRange) range withText: (NSString *) text selecting: (NSRange) selection {
	UITextPosition *start = [_textView positionFromPosition: _textView.beginningOfDocument offset: static_cast<NSInteger>(range.location)];
	UITextPosition *end = [_textView positionFromPosition: start offset: static_cast<NSInteger>(range.length)];
	if (!start || !end)
		return;
	_programmaticEdit = YES;
	[_textView replaceRange: [_textView textRangeFromPosition: start toPosition: end] withText: text];
	_programmaticEdit = NO;
	const NSUInteger length = _textView.textStorage.length;
	_textView.selectedRange = NSMakeRange(std::min(selection.location, length), std::min(selection.length, length - std::min(selection.location, length)));
	[self textChanged];
}

- (BOOL) textView: (UITextView *) textView shouldChangeTextInRange: (NSRange) range replacementText: (NSString *) text {
	if (_programmaticEdit)
		return YES;
	EditorSettings *settings = [EditorSettings shared];
	NSString *all = textView.textStorage.string;
	const BOOL code = _document.language->name != "normal";
	const unichar next = range.location + range.length < all.length ? [all characterAtIndex: range.location + range.length] : 0;
	const unichar previous = range.location > 0 ? [all characterAtIndex: range.location - 1] : 0;

	// Return keeps the indentation of the line, one level more after an opening bracket or ':'.
	if ([text isEqualToString: @"\n"] && settings.autoIndent) {
		const NSRange lineRange = [all lineRangeForRange: NSMakeRange(range.location, 0)];
		NSString *before = [all substringWithRange: NSMakeRange(lineRange.location, range.location - lineRange.location)];
		NSUInteger indentLength = 0;
		while (indentLength < before.length && ([before characterAtIndex: indentLength] == ' ' || [before characterAtIndex: indentLength] == '\t'))
			++indentLength;
		NSString *indent = [before substringToIndex: indentLength];
		NSString *trimmed = [before stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
		const unichar last = trimmed.length ? [trimmed characterAtIndex: trimmed.length - 1] : 0;
		const BOOL opens = code && (last == '{' || last == '[' || last == '(' || (last == ':' && _document.language->name == "python"));
		NSString *inner = opens ? [indent stringByAppendingString: [self indentUnit]] : indent;
		NSString *insertion = [@"\n" stringByAppendingString: inner];
		NSUInteger caret = range.location + insertion.length;
		// Between a pair of brackets: the closing one goes on its own line.
		if (opens && range.length == 0 && IsCloser(next) && range.location > 0)
			insertion = [insertion stringByAppendingFormat: @"\n%@", indent];
		[self replaceRange: range withText: insertion selecting: NSMakeRange(caret, 0)];
		return NO;
	}

	if (!settings.autoClose || !code || text.length != 1 || range.length != 0)
		return YES;
	const unichar typed = [text characterAtIndex: 0];
	const BOOL quote = typed == '"' || typed == '\'' || typed == '`';
	// Typing a closer that is already there steps over it.
	if ((IsCloser(typed) || quote) && next == typed) {
		textView.selectedRange = NSMakeRange(range.location + 1, 0);
		return NO;
	}
	const BOOL freeAfter = next == 0 || [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember: next] || IsCloser(next) ||
	                       next == ',' || next == ';';
	NSString *closer = nil;
	if (typed == '(')
		closer = @")";
	else if (typed == '[')
		closer = @"]";
	else if (typed == '{')
		closer = @"}";
	else if (quote && !IsWordCharacter(previous))
		closer = text;
	if (!closer || !freeAfter)
		return YES;
	[self replaceRange: range withText: [text stringByAppendingString: closer] selecting: NSMakeRange(range.location + 1, 0)];
	return NO;
}

#pragma mark - Extra keys

- (UIView *) accessoryBar {
	UIInputView *bar = [[UIInputView alloc] initWithFrame: CGRectMake(0, 0, 320, 46) inputViewStyle: UIInputViewStyleKeyboard];
	bar.allowsSelfSizing = YES;
	UIScrollView *scroll = [[UIScrollView alloc] init];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	scroll.showsHorizontalScrollIndicator = NO;
	[bar addSubview: scroll];
	UIStackView *stack = [[UIStackView alloc] init];
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	stack.axis = UILayoutConstraintAxisHorizontal;
	stack.spacing = 6;
	[scroll addSubview: stack];
	[NSLayoutConstraint activateConstraints: @[
		[scroll.leadingAnchor constraintEqualToAnchor: bar.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor: bar.trailingAnchor],
		[scroll.topAnchor constraintEqualToAnchor: bar.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor: bar.bottomAnchor],
		[scroll.heightAnchor constraintEqualToConstant: 46],
		[stack.leadingAnchor constraintEqualToAnchor: scroll.contentLayoutGuide.leadingAnchor constant: 6],
		[stack.trailingAnchor constraintEqualToAnchor: scroll.contentLayoutGuide.trailingAnchor constant: -6],
		[stack.topAnchor constraintEqualToAnchor: scroll.contentLayoutGuide.topAnchor constant: 6],
		[stack.bottomAnchor constraintEqualToAnchor: scroll.contentLayoutGuide.bottomAnchor constant: -6],
		[stack.heightAnchor constraintEqualToAnchor: scroll.frameLayoutGuide.heightAnchor constant: -12],
	]];

	auto addButton = [&](NSString *title, NSString *symbol, NSString *label, SEL action, NSString *insert) {
		UIButtonConfiguration *configuration = [UIButtonConfiguration grayButtonConfiguration];
		configuration.contentInsets = NSDirectionalEdgeInsetsMake(4, 10, 4, 10);
		if (symbol)
			configuration.image = [UIImage systemImageNamed: symbol];
		else
			configuration.attributedTitle = [[NSAttributedString alloc] initWithString: title attributes: @{
				NSFontAttributeName: [UIFont monospacedSystemFontOfSize: 17 weight: UIFontWeightRegular]}];
		UIButton *button = [UIButton buttonWithConfiguration: configuration primaryAction: nil];
		button.accessibilityLabel = label ?: title;
		if (insert) {
			button.accessibilityIdentifier = insert;
			[button addTarget: self action: @selector(insertKey:) forControlEvents: UIControlEventTouchUpInside];
		} else {
			[button addTarget: self action: action forControlEvents: UIControlEventTouchUpInside];
		}
		[button.widthAnchor constraintGreaterThanOrEqualToConstant: 38].active = YES;
		[stack addArrangedSubview: button];
	};
	addButton(nil, @"arrow.right.to.line", @"Tab", @selector(insertTab), nil);
	addButton(nil, @"arrow.left", @"Left", @selector(moveLeft), nil);
	addButton(nil, @"arrow.right", @"Right", @selector(moveRight), nil);
	for (NSString *key in @[@"{", @"}", @"(", @")", @"[", @"]", @"<", @">", @"\"", @"'", @"=", @";", @":", @"/", @"\\", @"|",
	                        @"&", @"#", @"$", @"_", @"-", @"+", @"*", @"%", @"!", @"?", @"`", @"~", @"^", @"@"])
		addButton(key, nil, nil, nil, key);
	addButton(nil, @"arrow.uturn.backward", @"Undo", @selector(undo), nil);
	addButton(nil, @"arrow.uturn.forward", @"Redo", @selector(redo), nil);
	addButton(nil, @"keyboard.chevron.compact.down", @"Hide Keyboard", @selector(hideKeyboard), nil);
	return bar;
}

- (void) insertKey: (UIButton *) sender {
	[_textView insertText: sender.accessibilityIdentifier];
}

- (void) insertTab {
	[_textView insertText: [self indentUnit]];
}

- (void) moveLeft {
	const NSRange selection = _textView.selectedRange;
	if (selection.length)
		_textView.selectedRange = NSMakeRange(selection.location, 0);
	else if (selection.location > 0)
		_textView.selectedRange = [_textView.textStorage.string rangeOfComposedCharacterSequenceAtIndex: selection.location - 1].location == NSNotFound
			? NSMakeRange(selection.location - 1, 0)
			: NSMakeRange([_textView.textStorage.string rangeOfComposedCharacterSequenceAtIndex: selection.location - 1].location, 0);
}

- (void) moveRight {
	const NSRange selection = _textView.selectedRange;
	NSString *text = _textView.textStorage.string;
	if (selection.length)
		_textView.selectedRange = NSMakeRange(NSMaxRange(selection), 0);
	else if (selection.location < text.length)
		_textView.selectedRange = NSMakeRange(NSMaxRange([text rangeOfComposedCharacterSequenceAtIndex: selection.location]), 0);
}

- (void) undo {
	[_textView.undoManager undo];
}

- (void) redo {
	[_textView.undoManager redo];
}

- (void) hideKeyboard {
	[_textView resignFirstResponder];
}

#pragma mark - Keyboard shortcuts (hardware keyboards)

- (NSArray<UIKeyCommand *> *) keyCommands {
	const UIKeyModifierFlags cmd = UIKeyModifierCommand;
	return @[
		[UIKeyCommand commandWithTitle: @"Find" image: nil action: @selector(showFind) input: @"f" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Replace" image: nil action: @selector(showReplace) input: @"f" modifierFlags: cmd | UIKeyModifierAlternate propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Go to Line" image: nil action: @selector(goToLine) input: @"l" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Toggle Comment" image: nil action: @selector(toggleComment) input: @"/" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Duplicate Line" image: nil action: @selector(duplicateLine) input: @"d" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Save" image: nil action: @selector(saveNow) input: @"s" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Bigger" image: nil action: @selector(biggerText) input: @"=" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Smaller" image: nil action: @selector(smallerText) input: @"-" modifierFlags: cmd propertyList: nil],
		[UIKeyCommand commandWithTitle: @"Close" image: nil action: @selector(closeDocument) input: @"w" modifierFlags: cmd propertyList: nil],
	];
}

#pragma mark - Find and Go to Line

- (void) showFind {
	[_textView.findInteraction presentFindNavigatorShowingReplace: NO];
}

- (void) showReplace {
	[_textView.findInteraction presentFindNavigatorShowingReplace: YES];
}

- (void) goToLine {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle: @"Go to Line"
	                                                               message: [NSString stringWithFormat: @"1 – %lu", (unsigned long)[_textView lineCount]]
	                                                        preferredStyle: UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler: ^(UITextField *field) {
		field.keyboardType = UIKeyboardTypeNumberPad;
		field.placeholder = @"Line";
	}];
	[alert addAction: [UIAlertAction actionWithTitle: @"Cancel" style: UIAlertActionStyleCancel handler: nil]];
	[alert addAction: [UIAlertAction actionWithTitle: @"Go" style: UIAlertActionStyleDefault handler: ^(UIAlertAction *action) {
		const NSInteger line = alert.textFields.firstObject.text.integerValue;
		const NSUInteger index = static_cast<NSUInteger>(std::clamp<NSInteger>(line, 1, static_cast<NSInteger>([self->_textView lineCount])) - 1);
		self->_textView.selectedRange = NSMakeRange([self->_textView locationOfLine: index], 0);
		[self->_textView scrollRangeToVisible: self->_textView.selectedRange];
		[self->_textView becomeFirstResponder];
	}]];
	[self presentViewController: alert animated: YES completion: nil];
}

#pragma mark - Line based commands

// The full lines covered by the selection, without the final line break. Without a
// selection: the whole text when `whole` is set, otherwise the caret's line.
- (NSRange) selectedLinesWholeTextIfEmpty: (BOOL) whole {
	NSString *text = _textView.textStorage.string;
	const NSRange selection = _textView.selectedRange;
	NSRange lines = selection.length == 0 && whole ? NSMakeRange(0, text.length) : [text lineRangeForRange: selection];
	if (lines.length && [text characterAtIndex: NSMaxRange(lines) - 1] == '\n')
		--lines.length;
	return lines;
}

- (void) applyLineOperation: (LineOperation) operation {
	const NSRange lines = [self selectedLinesWholeTextIfEmpty: YES];
	const BOOL hadSelection = _textView.selectedRange.length > 0;
	std::vector<std::string> list = SplitLines(ToStdString([_textView.textStorage.string substringWithRange: lines]));
	ApplyLineOperation(list, operation, static_cast<int>([EditorSettings shared].tabWidth));
	NSString *result = ToNSString(JoinLines(list, "\n"));
	if ([result isEqualToString: [_textView.textStorage.string substringWithRange: lines]])
		return;
	[self replaceRange: lines withText: result
	         selecting: hadSelection ? NSMakeRange(lines.location, result.length) : NSMakeRange(std::min(_textView.selectedRange.location, lines.location + result.length), 0)];
}

- (void) toggleComment {
	const Language *language = _document.language;
	NSString *text = _textView.textStorage.string;
	if (language->commentLine.empty()) {
		NSString *open = ToNSString(language->commentStart);
		NSString *close = ToNSString(language->commentEnd);
		if (!open.length || !close.length)
			return;
		NSRange range = _textView.selectedRange;
		if (!range.length)
			range = [self selectedLinesWholeTextIfEmpty: NO];
		NSString *chunk = [text substringWithRange: range];
		NSString *result;
		if ([chunk hasPrefix: open] && [chunk hasSuffix: close] && chunk.length >= open.length + close.length) {
			result = [chunk substringWithRange: NSMakeRange(open.length, chunk.length - open.length - close.length)];
			result = [result stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
		} else {
			result = [NSString stringWithFormat: @"%@ %@ %@", open, chunk, close];
		}
		[self replaceRange: range withText: result selecting: NSMakeRange(range.location, result.length)];
		return;
	}

	NSString *token = ToNSString(language->commentLine);
	const NSRange range = [self selectedLinesWholeTextIfEmpty: NO];
	NSMutableArray<NSString *> *lines = [[[text substringWithRange: range] componentsSeparatedByString: @"\n"] mutableCopy];
	NSCharacterSet *blank = [NSCharacterSet whitespaceCharacterSet];
	BOOL allCommented = YES;
	BOOL anyLine = NO;
	for (NSString *line in lines) {
		NSString *trimmed = [line stringByTrimmingCharactersInSet: blank];
		if (!trimmed.length)
			continue;
		anyLine = YES;
		if (![trimmed hasPrefix: token])
			allCommented = NO;
	}
	allCommented = allCommented && anyLine;
	for (NSUInteger i = 0; i < lines.count; ++i) {
		NSString *line = lines[i];
		const NSRange content = [line rangeOfCharacterFromSet: [blank invertedSet]];
		if (content.location == NSNotFound) {
			if (anyLine)
				continue;
			lines[i] = [line stringByAppendingFormat: @"%@ ", token];
			continue;
		}
		NSString *indent = [line substringToIndex: content.location];
		NSString *rest = [line substringFromIndex: content.location];
		if (allCommented) {
			rest = [rest substringFromIndex: token.length];
			if ([rest hasPrefix: @" "])
				rest = [rest substringFromIndex: 1];
			lines[i] = [indent stringByAppendingString: rest];
		} else {
			lines[i] = [NSString stringWithFormat: @"%@%@ %@", indent, token, rest];
		}
	}
	NSString *result = [lines componentsJoinedByString: @"\n"];
	const BOOL hadSelection = _textView.selectedRange.length > 0;
	[self replaceRange: range withText: result
	         selecting: hadSelection ? NSMakeRange(range.location, result.length) : NSMakeRange(range.location + result.length, 0)];
}

- (void) duplicateLine {
	const NSRange lines = [self selectedLinesWholeTextIfEmpty: NO];
	NSString *chunk = [_textView.textStorage.string substringWithRange: lines];
	[self replaceRange: NSMakeRange(NSMaxRange(lines), 0) withText: [@"\n" stringByAppendingString: chunk]
	         selecting: NSMakeRange(NSMaxRange(lines) + 1 + (_textView.selectedRange.location - lines.location), 0)];
}

- (void) deleteLine {
	NSString *text = _textView.textStorage.string;
	const NSRange lines = [text lineRangeForRange: _textView.selectedRange];
	[self replaceRange: lines withText: @"" selecting: NSMakeRange(lines.location, 0)];
}

// Replaces the selection, or the whole text without one, with `transform` of it.
- (void) transformSelectionOrText: (BOOL (^)(const std::string &text, std::string &result, NSString **error)) transform
                            title: (NSString *) title {
	NSRange range = _textView.selectedRange;
	const BOOL hadSelection = range.length > 0;
	if (!hadSelection)
		range = NSMakeRange(0, _textView.textStorage.length);
	const std::string text = ToStdString([_textView.textStorage.string substringWithRange: range]);
	std::string result;
	NSString *error = nil;
	if (!transform(text, result, &error)) {
		[self showMessage: error ?: @"The text could not be converted." title: title];
		return;
	}
	NSString *replacement = ToNSString(result);
	[self replaceRange: range withText: replacement
	         selecting: hadSelection ? NSMakeRange(range.location, replacement.length) : NSMakeRange(0, 0)];
}

- (void) convertCase: (CaseStyle) style {
	if (!_textView.selectedRange.length) {
		[self showMessage: @"Select the text to convert first." title: @"Convert Case"];
		return;
	}
	[self transformSelectionOrText: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		result = ConvertCase(text, style);
		return YES;
	} title: @"Convert Case"];
}

- (void) changeCaseUsing: (NSString *(^)(NSString *)) change {
	const NSRange range = _textView.selectedRange;
	if (!range.length) {
		[self showMessage: @"Select the text to convert first." title: @"Convert Case"];
		return;
	}
	NSString *result = change([_textView.textStorage.string substringWithRange: range]);
	[self replaceRange: range withText: result selecting: NSMakeRange(range.location, result.length)];
}

- (void) insertDate {
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [NSLocale localeWithLocaleIdentifier: @"en_US_POSIX"];
	formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
	[_textView insertText: [formatter stringFromDate: [NSDate date]]];
}

#pragma mark - Tools

- (void) showMessage: (NSString *) message title: (NSString *) title {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle: title message: message preferredStyle: UIAlertControllerStyleAlert];
	[alert addAction: [UIAlertAction actionWithTitle: @"OK" style: UIAlertActionStyleCancel handler: nil]];
	[self presentViewController: alert animated: YES completion: nil];
}

- (void) showHash: (HashAlgorithm) algorithm name: (NSString *) name {
	const NSRange selection = _textView.selectedRange;
	NSString *text = selection.length ? [_textView.textStorage.string substringWithRange: selection] : _textView.textStorage.string;
	NSString *digest = ToNSString(HashHex(ToStdString(text), algorithm));
	UIAlertController *alert = [UIAlertController alertControllerWithTitle: [NSString stringWithFormat: @"%@ of %@", name,
	                                                                         selection.length ? @"the selection" : @"the text"]
	                                                               message: digest
	                                                        preferredStyle: UIAlertControllerStyleAlert];
	[alert addAction: [UIAlertAction actionWithTitle: @"Copy" style: UIAlertActionStyleDefault handler: ^(UIAlertAction *action) {
		[UIPasteboard generalPasteboard].string = digest;
	}]];
	[alert addAction: [UIAlertAction actionWithTitle: @"Close" style: UIAlertActionStyleCancel handler: nil]];
	[self presentViewController: alert animated: YES completion: nil];
}

- (void) formatJSONMinified: (BOOL) minify {
	const std::string indent = ToStdString([self indentUnit]);
	[self transformSelectionOrText: ^BOOL(const std::string &text, std::string &result, NSString **error) {
		std::string message;
		if (FormatJSON(text, minify, indent, "\n", result, message))
			return YES;
		*error = ToNSString(message);
		return NO;
	} title: minify ? @"Minify JSON" : @"Format JSON"];
}

#pragma mark - Language, encoding, line endings

- (void) setLanguage: (const Language *) language {
	_document.language = language;
	_document.languageChosenByUser = YES;
	[_styleAttributes removeAllObjects];
	_appliedStyles.assign(_textView.textStorage.length, kUnstyled);
	[self highlightNow];
	[self updateStatus];
}

- (void) convertToEncoding: (FileEncoding) encoding {
	if (_document.encoding == encoding)
		return;
	_document.encoding = encoding;
	[self saveNow];
	[self updateStatus];
}

- (void) reopenWithEncoding: (FileEncoding) encoding {
	[_document reinterpretWithEncoding: encoding];
	[self loadDocumentText];
}

- (void) setLineEnding: (LineEnding) eol {
	_document.lineEnding = eol;
	[self updateStatus];
}

#pragma mark - Share, print, about

- (void) share {
	[self saveNow];
	NSURL *url = _document.fileURL;
	if (!url)
		return;
	UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems: @[url] applicationActivities: nil];
	activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
	[self presentViewController: activity animated: YES completion: nil];
}

- (void) print {
	UIPrintInteractionController *printer = [UIPrintInteractionController sharedPrintController];
	UIPrintInfo *info = [UIPrintInfo printInfo];
	info.jobName = _document.localizedName ?: @"MacPad";
	info.outputType = UIPrintInfoOutputGeneral;
	printer.printInfo = info;
	UISimpleTextPrintFormatter *formatter = [[UISimpleTextPrintFormatter alloc] initWithAttributedText: _textView.attributedText];
	formatter.perPageContentInsets = UIEdgeInsetsMake(36, 36, 36, 36);
	printer.printFormatter = formatter;
	[printer presentAnimated: YES completionHandler: nil];
}

- (void) showAbout {
	UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController: [[AboutViewController alloc] init]];
	[self presentViewController: navigation animated: YES completion: nil];
}

- (void) biggerText {
	[EditorSettings shared].fontSize = [EditorSettings shared].fontSize + 1;
}

- (void) smallerText {
	[EditorSettings shared].fontSize = [EditorSettings shared].fontSize - 1;
}

#pragma mark - Menu

- (UIAction *) action: (NSString *) title image: (NSString *) symbol handler: (void (^)(void)) handler {
	return [UIAction actionWithTitle: title image: symbol ? [UIImage systemImageNamed: symbol] : nil identifier: nil
	                         handler: ^(UIAction *action) { handler(); }];
}

- (UIAction *) toggle: (NSString *) title on: (BOOL) on handler: (void (^)(void)) handler {
	UIAction *action = [self action: title image: nil handler: handler];
	action.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
	return action;
}

- (NSArray<UIMenuElement *> *) menuElements {
	__weak EditorViewController *weakSelf = self;
	EditorSettings *settings = [EditorSettings shared];

	UIMenu *search = [UIMenu menuWithTitle: @"" image: nil identifier: nil options: UIMenuOptionsDisplayInline children: @[
		[self action: @"Find" image: @"magnifyingglass" handler: ^{ [weakSelf showFind]; }],
		[self action: @"Find and Replace" image: @"arrow.left.arrow.right" handler: ^{ [weakSelf showReplace]; }],
		[self action: @"Go to Line…" image: @"number" handler: ^{ [weakSelf goToLine]; }],
	]];

	UIMenu *lines = [UIMenu menuWithTitle: @"Lines" image: [UIImage systemImageNamed: @"list.bullet"] identifier: nil options: 0 children: @[
		[self action: @"Toggle Comment" image: nil handler: ^{ [weakSelf toggleComment]; }],
		[self action: @"Duplicate Line" image: nil handler: ^{ [weakSelf duplicateLine]; }],
		[self action: @"Delete Line" image: nil handler: ^{ [weakSelf deleteLine]; }],
		[self action: @"Sort A → Z" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::SortAscending]; }],
		[self action: @"Sort Z → A" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::SortDescending]; }],
		[self action: @"Sort Ignoring Case" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::SortIgnoringCase]; }],
		[self action: @"Sort as Numbers" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::SortNumerically]; }],
		[self action: @"Reverse Order" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::Reverse]; }],
		[self action: @"Remove Duplicate Lines" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::RemoveDuplicates]; }],
		[self action: @"Remove Empty Lines" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::RemoveEmpty]; }],
		[self action: @"Trim Trailing Spaces" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::TrimTrailing]; }],
		[self action: @"Trim Leading Spaces" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::TrimLeading]; }],
		[self action: @"Tabs to Spaces" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::TabsToSpaces]; }],
		[self action: @"Leading Spaces to Tabs" image: nil handler: ^{ [weakSelf applyLineOperation: LineOperation::LeadingSpacesToTabs]; }],
	]];

	UIMenu *caseMenu = [UIMenu menuWithTitle: @"Convert Case" image: [UIImage systemImageNamed: @"textformat"] identifier: nil options: 0 children: @[
		[self action: @"UPPERCASE" image: nil handler: ^{ [weakSelf changeCaseUsing: ^NSString *(NSString *s) { return s.localizedUppercaseString; }]; }],
		[self action: @"lowercase" image: nil handler: ^{ [weakSelf changeCaseUsing: ^NSString *(NSString *s) { return s.localizedLowercaseString; }]; }],
		[self action: @"Proper Case" image: nil handler: ^{ [weakSelf convertCase: CaseStyle::Proper]; }],
		[self action: @"Sentence case" image: nil handler: ^{ [weakSelf convertCase: CaseStyle::Sentence]; }],
		[self action: @"iNVERT cASE" image: nil handler: ^{ [weakSelf convertCase: CaseStyle::Invert]; }],
	]];

	UIMenu *tools = [UIMenu menuWithTitle: @"Tools" image: [UIImage systemImageNamed: @"wrench.and.screwdriver"] identifier: nil options: 0 children: @[
		[UIMenu menuWithTitle: @"Checksum" image: nil identifier: nil options: 0 children: @[
			[self action: @"MD5" image: nil handler: ^{ [weakSelf showHash: HashAlgorithm::MD5 name: @"MD5"]; }],
			[self action: @"SHA-1" image: nil handler: ^{ [weakSelf showHash: HashAlgorithm::SHA1 name: @"SHA-1"]; }],
			[self action: @"SHA-256" image: nil handler: ^{ [weakSelf showHash: HashAlgorithm::SHA256 name: @"SHA-256"]; }],
			[self action: @"SHA-512" image: nil handler: ^{ [weakSelf showHash: HashAlgorithm::SHA512 name: @"SHA-512"]; }],
		]],
		[self action: @"Base64 Encode" image: nil handler: ^{
			[weakSelf transformSelectionOrText: ^BOOL(const std::string &t, std::string &r, NSString **e) { r = Base64Encode(t); return YES; } title: @"Base64"];
		}],
		[self action: @"Base64 Decode" image: nil handler: ^{
			[weakSelf transformSelectionOrText: ^BOOL(const std::string &t, std::string &r, NSString **e) {
				if (Base64Decode(t, r))
					return YES;
				*e = @"The text is not valid Base64.";
				return NO;
			} title: @"Base64"];
		}],
		[self action: @"URL Encode" image: nil handler: ^{
			[weakSelf transformSelectionOrText: ^BOOL(const std::string &t, std::string &r, NSString **e) { r = URLEncode(t); return YES; } title: @"URL"];
		}],
		[self action: @"URL Decode" image: nil handler: ^{
			[weakSelf transformSelectionOrText: ^BOOL(const std::string &t, std::string &r, NSString **e) {
				if (URLDecode(t, r))
					return YES;
				*e = @"The text contains a “%” that is not followed by two hexadecimal digits.";
				return NO;
			} title: @"URL"];
		}],
		[self action: @"Format JSON" image: nil handler: ^{ [weakSelf formatJSONMinified: NO]; }],
		[self action: @"Minify JSON" image: nil handler: ^{ [weakSelf formatJSONMinified: YES]; }],
		[self action: @"Insert Date and Time" image: nil handler: ^{ [weakSelf insertDate]; }],
	]];

	UIMenu *edit = [UIMenu menuWithTitle: @"" image: nil identifier: nil options: UIMenuOptionsDisplayInline children: @[lines, caseMenu, tools]];

	// Language: Normal Text, then one submenu per initial letter.
	const Language *current = _document.language;
	NSMutableArray<UIMenuElement *> *languageItems = [NSMutableArray array];
	NSMutableDictionary<NSString *, NSMutableArray<UIMenuElement *> *> *byLetter = [NSMutableDictionary dictionary];
	NSMutableArray<NSString *> *letters = [NSMutableArray array];
	for (const Language &language : LanguageCatalog::Shared().All()) {
		if (language.hidden)
			continue;
		const Language *pointer = &language;
		UIAction *action = [self toggle: ToNSString(language.menuName) on: pointer == current handler: ^{ [weakSelf setLanguage: pointer]; }];
		if (language.name == "normal") {
			[languageItems addObject: action];
			continue;
		}
		NSString *letter = [ToNSString(language.menuName) substringToIndex: 1].uppercaseString;
		if (!byLetter[letter]) {
			byLetter[letter] = [NSMutableArray array];
			[letters addObject: letter];
		}
		[byLetter[letter] addObject: action];
	}
	[letters sortUsingSelector: @selector(compare:)];
	for (NSString *letter in letters)
		[languageItems addObject: [UIMenu menuWithTitle: letter children: byLetter[letter]]];
	UIMenu *language = [UIMenu menuWithTitle: [NSString stringWithFormat: @"Language: %@", ToNSString(current->menuName)]
	                                   image: [UIImage systemImageNamed: @"chevron.left.forwardslash.chevron.right"] identifier: nil options: 0
	                                children: languageItems];

	const FileEncoding encoding = _document.encoding;
	auto convert = [&](NSString *title, FileEncoding target) {
		return [self toggle: title on: encoding == target handler: ^{ [weakSelf convertToEncoding: target]; }];
	};
	auto reopen = [&](NSString *title, CFStringEncoding cf) {
		FileEncoding target = cf == kCFStringEncodingUTF8 ? FileEncoding::Make(FileEncoding::UTF8) : FileEncoding::MakeLegacy(cf);
		return [self action: title image: nil handler: ^{ [weakSelf reopenWithEncoding: target]; }];
	};
	UIMenu *encodingMenu = [UIMenu menuWithTitle: [NSString stringWithFormat: @"Encoding: %@", encoding.DisplayName()]
	                                       image: [UIImage systemImageNamed: @"character.book.closed"] identifier: nil options: 0 children: @[
		convert(@"UTF-8", FileEncoding::Make(FileEncoding::UTF8)),
		convert(@"UTF-8 with BOM", FileEncoding::Make(FileEncoding::UTF8_BOM)),
		convert(@"UTF-16 LE", FileEncoding::Make(FileEncoding::UTF16LE_BOM)),
		convert(@"UTF-16 BE", FileEncoding::Make(FileEncoding::UTF16BE_BOM)),
		convert(@"Windows-1252", FileEncoding::MakeLegacy(kCFStringEncodingWindowsLatin1)),
		[UIMenu menuWithTitle: @"Reopen with Encoding" children: @[
			reopen(@"UTF-8", kCFStringEncodingUTF8),
			reopen(@"Western (Windows-1252)", kCFStringEncodingWindowsLatin1),
			reopen(@"Western (ISO 8859-1)", kCFStringEncodingISOLatin1),
			reopen(@"Western (Mac OS Roman)", kCFStringEncodingMacRoman),
			reopen(@"Central European (Windows-1250)", kCFStringEncodingWindowsLatin2),
			reopen(@"Cyrillic (Windows-1251)", kCFStringEncodingWindowsCyrillic),
			reopen(@"Greek (Windows-1253)", kCFStringEncodingWindowsGreek),
			reopen(@"Turkish (Windows-1254)", kCFStringEncodingWindowsLatin5),
			reopen(@"Japanese (Shift-JIS)", kCFStringEncodingDOSJapanese),
			reopen(@"Chinese Simplified (GB 18030)", kCFStringEncodingGB_18030_2000),
			reopen(@"Chinese Traditional (Big5)", kCFStringEncodingBig5),
			reopen(@"Korean (EUC-KR)", kCFStringEncodingEUC_KR),
		]],
	]];

	const LineEnding eol = _document.lineEnding;
	UIMenu *lineEndings = [UIMenu menuWithTitle: [NSString stringWithFormat: @"Line Endings: %@", LineEndingShortName(eol)]
	                                      image: [UIImage systemImageNamed: @"return"] identifier: nil options: 0 children: @[
		[self toggle: @"Unix and macOS (LF)" on: eol == LineEnding::LF handler: ^{ [weakSelf setLineEnding: LineEnding::LF]; }],
		[self toggle: @"Windows (CR LF)" on: eol == LineEnding::CRLF handler: ^{ [weakSelf setLineEnding: LineEnding::CRLF]; }],
		[self toggle: @"Classic Mac (CR)" on: eol == LineEnding::CR handler: ^{ [weakSelf setLineEnding: LineEnding::CR]; }],
	]];

	UIMenu *document = [UIMenu menuWithTitle: @"" image: nil identifier: nil options: UIMenuOptionsDisplayInline
	                                children: @[language, encodingMenu, lineEndings]];

	NSMutableArray<UIMenuElement *> *themeItems = [NSMutableArray array];
	[themeItems addObject: [self toggle: @"Automatic (Light / Dark)" on: [settings.themeName isEqualToString: kAutomaticTheme]
	                            handler: ^{ [EditorSettings shared].themeName = kAutomaticTheme; }]];
	for (NSString *name in [settings availableThemes])
		[themeItems addObject: [self toggle: name on: [settings.themeName isEqualToString: name] handler: ^{ [EditorSettings shared].themeName = name; }]];
	NSMutableArray<UIMenuElement *> *tabItems = [NSMutableArray array];
	for (NSNumber *width in @[@2, @3, @4, @8])
		[tabItems addObject: [self toggle: [NSString stringWithFormat: @"%@", width] on: settings.tabWidth == width.integerValue
		                          handler: ^{ [EditorSettings shared].tabWidth = width.integerValue; }]];
	UIMenu *view = [UIMenu menuWithTitle: @"View and Settings" image: [UIImage systemImageNamed: @"slider.horizontal.3"] identifier: nil options: 0 children: @[
		[UIMenu menuWithTitle: @"Theme" image: [UIImage systemImageNamed: @"paintpalette"] identifier: nil options: 0 children: themeItems],
		[UIMenu menuWithTitle: @"" image: nil identifier: nil options: UIMenuOptionsDisplayInline children: @[
			[self action: @"Bigger Text" image: @"textformat.size.larger" handler: ^{ [weakSelf biggerText]; }],
			[self action: @"Smaller Text" image: @"textformat.size.smaller" handler: ^{ [weakSelf smallerText]; }],
		]],
		[self toggle: @"Line Numbers" on: settings.showLineNumbers handler: ^{ [EditorSettings shared].showLineNumbers = !settings.showLineNumbers; }],
		[self toggle: @"Wrap Long Lines" on: settings.wrapLines handler: ^{ [EditorSettings shared].wrapLines = !settings.wrapLines; }],
		[self toggle: @"Auto-Indent" on: settings.autoIndent handler: ^{ [EditorSettings shared].autoIndent = !settings.autoIndent; }],
		[self toggle: @"Close Brackets and Quotes" on: settings.autoClose handler: ^{ [EditorSettings shared].autoClose = !settings.autoClose; }],
		[self toggle: @"Tab Inserts Spaces" on: settings.useSpaces handler: ^{ [EditorSettings shared].useSpaces = !settings.useSpaces; }],
		[UIMenu menuWithTitle: @"Tab Width" children: tabItems],
	]];

	UIMenu *file = [UIMenu menuWithTitle: @"" image: nil identifier: nil options: UIMenuOptionsDisplayInline children: @[
		[self action: @"Share…" image: @"square.and.arrow.up" handler: ^{ [weakSelf share]; }],
		[self action: @"Print…" image: @"printer" handler: ^{ [weakSelf print]; }],
		[self action: @"About MacPad" image: @"info.circle" handler: ^{ [weakSelf showAbout]; }],
	]];

	return @[search, edit, document, view, file];
}

@end
