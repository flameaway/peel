#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Darwin notification posted whenever the sticker library changes.
extern NSString *const STKLibraryChangedNotification;
// Hidden folder inside the sticker directory for cached thumbnails, named "<sticker name>@<size>.png".
extern NSString *const STKThumbnailCacheDirectoryName;

// Stickers are stored as PNG, GIF or HEICS files in a directory every process can reach (see STKLibraryPath).
@interface STKStore : NSObject

+ (instancetype)sharedStore;

@property (nonatomic, readonly) NSURL *directoryURL;

// In the order the user arranged them, with stickers added since then in front, newest first.
- (NSArray<NSURL *> *)stickerURLs;
// Saves the order stickerURLs returns from now on.
- (void)setStickerOrder:(NSArray<NSURL *> *)urls;
- (nullable NSURL *)addStickerPNGData:(NSData *)data error:(NSError **)error;
// fileExtension is "png" (static or animated), "gif" or "heics".
- (nullable NSURL *)addStickerData:(NSData *)data fileExtension:(NSString *)fileExtension error:(NSError **)error;
// Also deletes its cached thumbnails.
- (BOOL)removeStickerAtURL:(NSURL *)url error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
