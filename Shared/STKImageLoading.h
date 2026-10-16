#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Loads a sticker file (static or animated PNG, GIF or HEICS) as a UIImage no larger than maxSide pixels.
// Animated files come back as an animated UIImage that UIImageView plays automatically, thinned to at most 30 frames
// so a grid of thumbnails doesn't hold thousands of full frames.
// HEICS stickers are slow to decode, so this keeps a small animated PNG copy of each size it's asked for in
// STKThumbnailCacheDirectoryName. Can be slow the first time; call it off the main thread.
UIImage *_Nullable STKLoadStickerImage(NSURL *url, CGFloat maxSide);

// Roughly how many bytes a loaded sticker image takes in memory, for NSCache costs.
NSUInteger STKImageCost(UIImage *image);

// The sticker as something other apps can paste: PNG and GIF files as they are; HEICS (which few apps can play)
// converted to a GIF. Sets typeIdentifier to the data's type.
NSData *_Nullable STKPasteableStickerData(NSURL *url, NSString *_Nullable *_Nonnull typeIdentifier);

// The sticker as pasteboard items for Telegram, which sends pasted HEICS as an animated sticker and a single PNG as a
// sticker, but anything with a GIF on the pasteboard as a GIF. Animated stickers become HEICS; stills are PNG, also
// under Apple's Memoji sticker type so they're sent as stickers even without transparency.
NSArray<NSDictionary<NSString *, id> *> *_Nullable STKTelegramPasteboardItems(NSURL *url);

NS_ASSUME_NONNULL_END
