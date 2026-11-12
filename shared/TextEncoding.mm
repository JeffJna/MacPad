// File encodings: detection on load, conversion on save.
// This file is part of MacPad (GPL v3 or later).
#import "TextEncoding.h"

namespace
{

bool IsValidUTF8(const unsigned char *bytes, size_t length)
{
	size_t i = 0;
	while (i < length)
	{
		const unsigned char c = bytes[i];
		if (c < 0x80)
		{
			++i;
			continue;
		}
		size_t extra;
		unsigned int codePoint;
		if ((c & 0xE0) == 0xC0)
		{
			extra = 1;
			codePoint = c & 0x1F;
		}
		else if ((c & 0xF0) == 0xE0)
		{
			extra = 2;
			codePoint = c & 0x0F;
		}
		else if ((c & 0xF8) == 0xF0)
		{
			extra = 3;
			codePoint = c & 0x07;
		}
		else
		{
			return false;
		}
		if (i + extra >= length)
			return false; // truncated sequence
		for (size_t k = 1; k <= extra; ++k)
		{
			if ((bytes[i + k] & 0xC0) != 0x80)
				return false;
			codePoint = (codePoint << 6) | (bytes[i + k] & 0x3F);
		}
		static const unsigned int minimum[] = {0, 0x80, 0x800, 0x10000};
		if (codePoint < minimum[extra] || codePoint > 0x10FFFF || (codePoint >= 0xD800 && codePoint <= 0xDFFF))
			return false;
		i += extra + 1;
	}
	return true;
}

bool ConvertToUTF8(const void *bytes, size_t length, NSStringEncoding encoding, std::string &utf8)
{
	NSString *text = [[NSString alloc] initWithBytes: bytes length: length encoding: encoding];
	if (!text)
		return false;
	NSData *data = [text dataUsingEncoding: NSUTF8StringEncoding];
	utf8.assign(static_cast<const char *>(data.bytes), data.length);
	return true;
}

// Code pages that legacy files are usually written in. When the system detector names
// one of these it is trusted; anything rarer is double-checked against Windows-1252.
bool IsCommonLegacyEncoding(CFStringEncoding encoding)
{
	switch (encoding)
	{
		case kCFStringEncodingWindowsLatin1:
		case kCFStringEncodingWindowsLatin2:
		case kCFStringEncodingWindowsCyrillic:
		case kCFStringEncodingWindowsGreek:
		case kCFStringEncodingWindowsLatin5:
		case kCFStringEncodingWindowsHebrew:
		case kCFStringEncodingWindowsArabic:
		case kCFStringEncodingWindowsBalticRim:
		case kCFStringEncodingWindowsVietnamese:
		case kCFStringEncodingDOSJapanese:
		case kCFStringEncodingShiftJIS:
		case kCFStringEncodingEUC_JP:
		case kCFStringEncodingISO_2022_JP:
		case kCFStringEncodingGB_18030_2000:
		case kCFStringEncodingGBK_95:
		case kCFStringEncodingEUC_CN:
		case kCFStringEncodingBig5:
		case kCFStringEncodingBig5_HKSCS_1999:
		case kCFStringEncodingEUC_KR:
		case kCFStringEncodingDOSKorean:
		case kCFStringEncodingKOI8_R:
		case kCFStringEncodingKOI8_U:
		case kCFStringEncodingMacRoman:
			return true;
		default:
			return false;
	}
}

NSStringEncoding DetectWith(NSData *data, NSArray<NSNumber *> *suggested)
{
	NSMutableDictionary *options = [@{
		NSStringEncodingDetectionAllowLossyKey: @NO,
		NSStringEncodingDetectionDisallowedEncodingsKey: @[
			@(NSUTF8StringEncoding), @(NSUTF16StringEncoding), @(NSUTF16BigEndianStringEncoding),
			@(NSUTF16LittleEndianStringEncoding), @(NSUTF32StringEncoding), @(NSUTF32BigEndianStringEncoding),
			@(NSUTF32LittleEndianStringEncoding), @(NSNonLossyASCIIStringEncoding),
		],
	} mutableCopy];
	if (suggested.count)
		options[NSStringEncodingDetectionSuggestedEncodingsKey] = suggested;
	NSString *converted = nil;
	BOOL lossy = NO;
	return [NSString stringEncodingForData: data encodingOptions: options convertedString: &converted usedLossyConversion: &lossy];
}

// Text that is not valid UTF-8: guess its code page with the system's detector.
CFStringEncoding DetectLegacyEncoding(const unsigned char *bytes, size_t length)
{
	size_t nonASCII = 0;
	for (size_t i = 0; i < length && nonASCII < 16; ++i)
	{
		if (bytes[i] >= 0x80)
			++nonASCII;
	}
	NSData *data = [NSData dataWithBytesNoCopy: const_cast<unsigned char *>(bytes) length: length freeWhenDone: NO];
	NSNumber *western = @(NSWindowsCP1252StringEncoding);
	// A handful of accented letters says little about the language: assume Western.
	if (nonASCII >= 8)
	{
		const NSStringEncoding guess = DetectWith(data, nil);
		const CFStringEncoding encoding = guess ? CFStringConvertNSStringEncodingToEncoding(guess) : kCFStringEncodingInvalidId;
		if (encoding != kCFStringEncodingInvalidId && IsCommonLegacyEncoding(encoding))
			return encoding;
	}
	const NSStringEncoding guess = DetectWith(data, @[western]);
	const CFStringEncoding encoding = guess ? CFStringConvertNSStringEncodingToEncoding(guess) : kCFStringEncodingInvalidId;
	// Windows-1252 is the usual "ANSI" code page of western Windows systems.
	return encoding == kCFStringEncodingInvalidId ? kCFStringEncodingWindowsLatin1 : encoding;
}

NSError *EncodingError(NSString *message)
{
	return [NSError errorWithDomain: NSCocoaErrorDomain
	                           code: NSFileWriteInapplicableStringEncodingError
	                       userInfo: @{NSLocalizedDescriptionKey: message}];
}

} // namespace

NSString *FileEncoding::DisplayName() const
{
	switch (kind)
	{
		case UTF8:
			return @"UTF-8";
		case UTF8_BOM:
			return @"UTF-8-BOM";
		case UTF16LE_BOM:
			return @"UTF-16 LE BOM";
		case UTF16BE_BOM:
			return @"UTF-16 BE BOM";
		case Legacy:
		{
			CFStringRef iana = CFStringConvertEncodingToIANACharSetName(cfEncoding);
			if (iana)
				return [(__bridge NSString *)iana uppercaseString];
			return (__bridge NSString *)CFStringGetNameOfEncoding(cfEncoding) ?: @"ANSI";
		}
	}
	return @"UTF-8";
}

NSString *LineEndingDisplayName(LineEnding eol)
{
	switch (eol)
	{
		case LineEnding::CRLF:
			return @"Windows (CR LF)";
		case LineEnding::LF:
			return @"Unix (LF)";
		case LineEnding::CR:
			return @"Macintosh (CR)";
	}
	return @"Unix (LF)";
}

bool DecodeText(NSData *data, std::string &utf8, FileEncoding &encoding, const FileEncoding *forced)
{
	const unsigned char *bytes = static_cast<const unsigned char *>(data.bytes);
	const size_t length = data.length;

	auto startsWith = [&](std::initializer_list<unsigned char> bom) {
		if (length < bom.size())
			return false;
		size_t i = 0;
		for (unsigned char b : bom)
		{
			if (bytes[i++] != b)
				return false;
		}
		return true;
	};

	FileEncoding chosen;
	if (forced)
	{
		chosen = *forced;
	}
	else if (startsWith({0xEF, 0xBB, 0xBF}))
	{
		chosen = FileEncoding::Make(FileEncoding::UTF8_BOM);
	}
	else if (startsWith({0xFF, 0xFE}))
	{
		chosen = FileEncoding::Make(FileEncoding::UTF16LE_BOM);
	}
	else if (startsWith({0xFE, 0xFF}))
	{
		chosen = FileEncoding::Make(FileEncoding::UTF16BE_BOM);
	}
	else if (IsValidUTF8(bytes, length))
	{
		chosen = FileEncoding::Make(FileEncoding::UTF8);
	}
	else
	{
		chosen = FileEncoding::MakeLegacy(DetectLegacyEncoding(bytes, length));
	}

	bool ok = false;
	switch (chosen.kind)
	{
		case FileEncoding::UTF8:
		case FileEncoding::UTF8_BOM:
		{
			const size_t skip = startsWith({0xEF, 0xBB, 0xBF}) ? 3 : 0;
			utf8.assign(reinterpret_cast<const char *>(bytes) + skip, length - skip);
			ok = true;
			break;
		}
		case FileEncoding::UTF16LE_BOM:
		case FileEncoding::UTF16BE_BOM:
		{
			const bool little = chosen.kind == FileEncoding::UTF16LE_BOM;
			const bool hasBom = little ? startsWith({0xFF, 0xFE}) : startsWith({0xFE, 0xFF});
			const size_t skip = hasBom ? 2 : 0;
			ok = ConvertToUTF8(bytes + skip, length - skip,
			                   little ? NSUTF16LittleEndianStringEncoding : NSUTF16BigEndianStringEncoding, utf8);
			break;
		}
		case FileEncoding::Legacy:
			ok = ConvertToUTF8(bytes, length, CFStringConvertEncodingToNSStringEncoding(chosen.cfEncoding), utf8);
			break;
	}

	if (!ok)
	{
		// ISO-8859-1 maps every byte, so the content always survives a round trip.
		chosen = FileEncoding::MakeLegacy(kCFStringEncodingISOLatin1);
		ok = ConvertToUTF8(bytes, length, NSISOLatin1StringEncoding, utf8);
	}
	encoding = chosen;
	return ok;
}

NSData *EncodeText(const std::string &utf8, const FileEncoding &encoding, NSError **error)
{
	if (encoding.kind == FileEncoding::UTF8 || encoding.kind == FileEncoding::UTF8_BOM)
	{
		NSMutableData *data = [NSMutableData dataWithCapacity: utf8.size() + 3];
		if (encoding.kind == FileEncoding::UTF8_BOM)
		{
			static const unsigned char bom[] = {0xEF, 0xBB, 0xBF};
			[data appendBytes: bom length: sizeof(bom)];
		}
		[data appendBytes: utf8.data() length: utf8.size()];
		return data;
	}

	NSString *text = [[NSString alloc] initWithBytes: utf8.data() length: utf8.size() encoding: NSUTF8StringEncoding];
	if (!text)
	{
		if (error)
			*error = EncodingError(@"The document contains bytes that are not valid UTF-8 and cannot be converted.");
		return nil;
	}

	NSStringEncoding target;
	NSMutableData *data = [NSMutableData data];
	switch (encoding.kind)
	{
		case FileEncoding::UTF16LE_BOM:
		{
			static const unsigned char bom[] = {0xFF, 0xFE};
			[data appendBytes: bom length: sizeof(bom)];
			target = NSUTF16LittleEndianStringEncoding;
			break;
		}
		case FileEncoding::UTF16BE_BOM:
		{
			static const unsigned char bom[] = {0xFE, 0xFF};
			[data appendBytes: bom length: sizeof(bom)];
			target = NSUTF16BigEndianStringEncoding;
			break;
		}
		default:
			target = CFStringConvertEncodingToNSStringEncoding(encoding.cfEncoding);
			break;
	}

	NSData *body = [text dataUsingEncoding: target allowLossyConversion: NO];
	if (!body)
	{
		if (error)
			*error = EncodingError([NSString stringWithFormat:
				@"The document contains characters that cannot be saved as %@. "
				@"Use Encoding > Convert to UTF-8 and save again.", encoding.DisplayName()]);
		return nil;
	}
	[data appendData: body];
	return data;
}

LineEnding DetectLineEnding(const std::string &text, LineEnding fallback)
{
	for (size_t i = 0; i < text.size(); ++i)
	{
		if (text[i] == '\n')
			return LineEnding::LF;
		if (text[i] == '\r')
			return (i + 1 < text.size() && text[i + 1] == '\n') ? LineEnding::CRLF : LineEnding::CR;
	}
	return fallback;
}
