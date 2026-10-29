#import "STKStore.h"

NSString *const STKLibraryChangedNotification = @"com.josh.stickers/changed";
NSString *const STKThumbnailCacheDirectoryName = @".thumbs";
// File names of rearranged stickers in order, hidden so the sticker listing skips it.
static NSString *const kOrderFileName = @".order.plist";

#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX ""
#endif

// Dopamine lets every process read and write inside the jailbreak root, so stickers stored here are
// visible to the keyboard tweak running inside Messages and other apps.
// App group containers are not: sandboxed apps like Messages can't read them.
static NSString *STKLibraryPath(void) {
#if TARGET_OS_SIMULATOR
	NSString *override = NSProcessInfo.processInfo.environment[@"STK_LIBRARY_PATH"];
	if (override.length) {
		return override;
	}
#endif
	return @THEOS_PACKAGE_INSTALL_PREFIX "/var/mobile/Library/Stickers";
}

@implementation STKStore

+ (instancetype)sharedStore {
	static STKStore *store;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		store = [self new];
	});
	return store;
}

- (instancetype)init {
	if ((self = [super init])) {
		_directoryURL = [NSURL fileURLWithPath:STKLibraryPath() isDirectory:YES];
		[NSFileManager.defaultManager createDirectoryAtURL:_directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
	}
	return self;
}

- (NSArray<NSURL *> *)stickerURLs {
	NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directoryURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
	NSPredicate *png = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
		return [@[@"png", @"gif", @"heics"] containsObject:url.pathExtension.lowercaseString];
	}];
	NSArray<NSString *> *order = [NSArray arrayWithContentsOfURL:[self.directoryURL URLByAppendingPathComponent:kOrderFileName]] ?: @[];
	NSMutableDictionary<NSString *, NSNumber *> *positions = [NSMutableDictionary dictionaryWithCapacity:order.count];
	for (NSUInteger i = 0; i < order.count; i++) {
		positions[order[i]] = @(i);
	}
	return [[contents filteredArrayUsingPredicate:png] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
		NSNumber *first = positions[a.lastPathComponent], *second = positions[b.lastPathComponent];
		if (first && second) {
			return [first compare:second];
		}
		if (first || second) {
			// Stickers that were never arranged are newer than the saved order, so they go in front.
			return first ? NSOrderedDescending : NSOrderedAscending;
		}
		// File names start with a zero-padded timestamp, so a reverse name sort is newest first.
		return [b.lastPathComponent compare:a.lastPathComponent];
	}];
}

- (void)setStickerOrder:(NSArray<NSURL *> *)urls {
	[[urls valueForKey:@"lastPathComponent"] writeToURL:[self.directoryURL URLByAppendingPathComponent:kOrderFileName] atomically:YES];
	[self postChanged];
}

- (NSURL *)addStickerPNGData:(NSData *)data error:(NSError **)error {
	return [self addStickerData:data fileExtension:@"png" error:error];
}

- (NSURL *)addStickerData:(NSData *)data fileExtension:(NSString *)fileExtension error:(NSError **)error {
	unsigned long long millis = (unsigned long long)(NSDate.date.timeIntervalSince1970 * 1000);
	NSString *name = [NSString stringWithFormat:@"%015llu-%@.%@", millis, NSUUID.UUID.UUIDString, fileExtension];
	NSURL *url = [self.directoryURL URLByAppendingPathComponent:name];
	if (![data writeToURL:url options:NSDataWritingAtomic error:error]) {
		return nil;
	}
	[self postChanged];
	return url;
}

- (BOOL)removeStickerAtURL:(NSURL *)url error:(NSError **)error {
	BOOL removed = [NSFileManager.defaultManager removeItemAtURL:url error:error];
	if (removed) {
		NSURL *thumbnails = [self.directoryURL URLByAppendingPathComponent:STKThumbnailCacheDirectoryName isDirectory:YES];
		NSString *prefix = [url.lastPathComponent.stringByDeletingPathExtension stringByAppendingString:@"@"];
		for (NSURL *file in [NSFileManager.defaultManager contentsOfDirectoryAtURL:thumbnails includingPropertiesForKeys:nil options:0 error:nil]) {
			if ([file.lastPathComponent hasPrefix:prefix]) {
				[NSFileManager.defaultManager removeItemAtURL:file error:nil];
			}
		}
		[self postChanged];
	}
	return removed;
}

- (void)postChanged {
	CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)STKLibraryChangedNotification, NULL, NULL, true);
}

@end
