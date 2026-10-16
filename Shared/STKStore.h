#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const STKAppGroupIdentifier;
// Darwin notification posted whenever the sticker library changes.
extern NSString *const STKLibraryChangedNotification;
// Hidden folder inside the sticker directory for cached thumbnails, named "<sticker name>@<size>.png".
extern NSString *const STKThumbnailCacheDirectoryName;

// Stickers are stored as PNG, GIF or HEICS files in a directory every process can reach (see STKLibraryPath).
@interface STKStore : NSObject

+ (instancetype)sharedStore;

@property (nonatomic, readonly) NSURL *directoryURL;

// Newest first.
- (NSArray<NSURL *> *)stickerURLs;
- (nullable NSURL *)addStickerPNGData:(NSData *)data error:(NSError **)error;
// fileExtension is "png" (static or animated), "gif" or "heics".
- (nullable NSURL *)addStickerData:(NSData *)data fileExtension:(NSString *)fileExtension error:(NSError **)error;
// Also deletes its cached thumbnails.
- (BOOL)removeStickerAtURL:(NSURL *)url error:(NSError **)error;
// Moves stickers saved by version 1.0 out of the app group container. Only the app can do this.
- (void)migrateFromAppGroup;

@end

NS_ASSUME_NONNULL_END
