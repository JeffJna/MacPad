// Small helpers shared by the iOS app.
// This file is part of MacPad (GPL v3 or later).
#pragma once

#import <UIKit/UIKit.h>

#include <string>

static inline NSString *ToNSString(const std::string &text)
{
	NSString *result = [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSUTF8StringEncoding];
	return result ?: [[NSString alloc] initWithBytes: text.data() length: text.size() encoding: NSISOLatin1StringEncoding] ?: @"";
}

static inline std::string ToStdString(NSString *text)
{
	NSData *data = [text dataUsingEncoding: NSUTF8StringEncoding allowLossyConversion: YES];
	return std::string(static_cast<const char *>(data.bytes), data.length);
}

// Theme colours are 0xRRGGBB.
static inline UIColor *ColorFromRGB(unsigned rgb)
{
	return [UIColor colorWithRed: ((rgb >> 16) & 0xFF) / 255.0 green: ((rgb >> 8) & 0xFF) / 255.0 blue: (rgb & 0xFF) / 255.0 alpha: 1];
}
