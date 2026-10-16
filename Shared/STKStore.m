#import "STKStore.h"

NSString *const STKAppGroupIdentifier = @"group.com.josh.stickers";
NSString *const STKLibraryChangedNotification = @"com.josh.stickers/changed";
NSString *const STKThumbnailCacheDirectoryName = @".thumbs";

#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX ""
#endif

// Dopamine lets every process read and write inside the jailbreak root, so stickers stored here are
// visible to the app, its iMessage extension, and the keyboard tweak running inside Messages and other apps.
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

- (void)migrateFromAppGroup {
	NSURL *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:STKAppGroupIdentifier];
	NSURL *old = [group URLByAppendingPathComponent:@"Stickers" isDirectory:YES];
	NSArray<NSURL *> *files = old ? [NSFileManager.defaultManager contentsOfDirectoryAtURL:old includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] : nil;
	BOOL moved = NO;
	for (NSURL *file in files) {
		NSURL *destination = [self.directoryURL URLByAppendingPathComponent:file.lastPathComponent];
		moved |= [NSFileManager.defaultManager moveItemAtURL:file toURL:destination error:nil];
	}
	if (moved) {
		[self postChanged];
	}
}

- (NSArray<NSURL *> *)stickerURLs {
	NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.directoryURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
	NSPredicate *png = [NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
		return [@[@"png", @"gif", @"heics"] containsObject:url.pathExtension.lowercaseString];
	}];
	// File names start with a zero-padded timestamp, so a reverse name sort is newest first.
	return [[contents filteredArrayUsingPredicate:png] sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
		return [b.lastPathComponent compare:a.lastPathComponent];
	}];
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
