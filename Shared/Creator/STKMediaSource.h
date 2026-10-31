#import <UIKit/UIKit.h>

@class PHAsset, PHLivePhoto;

NS_ASSUME_NONNULL_BEGIN

// What a sticker is made from: a still image, or a short animation (Live Photo, GIF or video) as evenly timed frames.
@interface STKMediaSource : NSObject

@property (nonatomic, readonly) UIImage *still;
// One frame per entry; empty for still images.
@property (nonatomic, readonly) NSArray<UIImage *> *frames;
// Frames are at the source's own frame rate (up to 60 fps).
@property (nonatomic, readonly) NSTimeInterval frameDuration;
@property (nonatomic, readonly, getter=isAnimated) BOOL animated;
// Already transparent (e.g. a subject copied from Photos), so offering background removal is pointless.
@property (nonatomic, readonly) BOOL alreadyCutOut;

+ (instancetype)sourceWithImage:(UIImage *)image alreadyCutOut:(BOOL)alreadyCutOut;
// GIF or animated PNG data becomes an animation; anything else a still.
+ (nullable instancetype)sourceWithImageData:(NSData *)data;
// Handles photos, Live Photos, GIFs and videos from the photo picker or a drop. Calls back on the main queue.
// A Live Photo from the photo library as an animation (its still if the video can't be read). Calls back on the main queue.
+ (void)loadLivePhotoAsset:(PHAsset *)asset completion:(void (^)(STKMediaSource *_Nullable source, NSError *_Nullable error))completion;
// The same for a Live Photo object, such as one shown in a PHLivePhotoView. Calls back on the main queue.
+ (void)loadLivePhoto:(PHLivePhoto *)livePhoto completion:(void (^)(STKMediaSource *_Nullable source, NSError *_Nullable error))completion;
+ (void)loadFromItemProvider:(NSItemProvider *)provider completion:(void (^)(STKMediaSource *_Nullable source, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
