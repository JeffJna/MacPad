// Versions of a file in iCloud Drive that were saved on two devices at once.
// This file is part of MacPad (GPL v3 or later).
#import "FileConflicts.h"

NSString *UniqueFileName(NSString *fileName, BOOL (^exists)(NSString *))
{
	if (!exists(fileName))
		return fileName;
	NSString *extension = fileName.pathExtension;
	NSString *base = extension.length ? fileName.stringByDeletingPathExtension : fileName;
	for (NSUInteger number = 2;; ++number) {
		NSString *candidate = [NSString stringWithFormat: @"%@ %lu", base, (unsigned long)number];
		if (extension.length)
			candidate = [candidate stringByAppendingPathExtension: extension];
		if (!exists(candidate))
			return candidate;
	}
}

NSString *ConflictCopyName(NSString *fileName, NSString *device, BOOL (^exists)(NSString *))
{
	NSString *label = device.length ? device : @"other device";
	// The name of a device can hold characters that a file name cannot.
	label = [[label componentsSeparatedByCharactersInSet: [NSCharacterSet characterSetWithCharactersInString: @"/:"]]
	         componentsJoinedByString: @"-"];
	NSString *extension = fileName.pathExtension;
	NSString *base = extension.length ? fileName.stringByDeletingPathExtension : fileName;
	NSString *name = [NSString stringWithFormat: @"%@ (%@)", base, label];
	if (extension.length)
		name = [name stringByAppendingPathExtension: extension];
	return UniqueFileName(name, exists);
}

// Copies `version` of the file named `fileName` into `folder`; nil when that fails.
static NSURL *CopyVersion(NSFileVersion *version, NSString *fileName, NSURL *folder)
{
	NSFileManager *manager = [[NSFileManager alloc] init];
	NSString *name = ConflictCopyName(fileName, version.localizedNameOfSavingComputer, ^BOOL(NSString *candidate) {
		return [manager fileExistsAtPath: [folder.path stringByAppendingPathComponent: candidate]];
	});
	NSURL *target = [folder URLByAppendingPathComponent: name isDirectory: NO];
	__block BOOL copied = NO;
	NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter: nil];
	[coordinator coordinateWritingItemAtURL: target options: NSFileCoordinatorWritingForReplacing error: nil
	                             byAccessor: ^(NSURL *writeURL) {
		copied = [manager copyItemAtURL: version.URL toURL: writeURL error: nil];
	}];
	return copied ? target : nil;
}

NSArray<NSURL *> *KeepVersionsInConflict(NSURL *url, NSURL *fallbackFolder)
{
	NSArray<NSFileVersion *> *conflicts = [NSFileVersion unresolvedConflictVersionsOfItemAtURL: url];
	if (!conflicts.count)
		return @[];
	NSMutableArray<NSURL *> *copies = [NSMutableArray array];
	BOOL everyVersionKept = YES;
	for (NSFileVersion *version in conflicts) {
		NSURL *copy = CopyVersion(version, url.lastPathComponent, url.URLByDeletingLastPathComponent);
		if (!copy && fallbackFolder) {
			[[NSFileManager defaultManager] createDirectoryAtURL: fallbackFolder withIntermediateDirectories: YES attributes: nil error: nil];
			copy = CopyVersion(version, url.lastPathComponent, fallbackFolder);
		}
		if (!copy) {
			everyVersionKept = NO; // left in conflict: the next look tries again
			continue;
		}
		[copies addObject: copy];
		version.resolved = YES;
	}
	// Only once every version has a copy: this deletes them from the version store.
	if (everyVersionKept)
		[NSFileVersion removeOtherVersionsOfItemAtURL: url error: nil];
	return copies;
}
