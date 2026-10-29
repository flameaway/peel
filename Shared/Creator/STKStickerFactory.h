#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// A finished sticker: the file to store plus an image (animated if needed) for previews.
@interface STKRenderedSticker : NSObject
@property (nonatomic, readonly) NSData *data;
// "png" for stills; "heics" for animations (HEVC with alpha, like iOS 17's live stickers), or "png"/"gif" where
// HEICS can't be written.
@property (nonatomic, readonly) NSString *fileExtension;
@property (nonatomic, readonly) UIImage *preview;
@property (nonatomic, readonly, getter=isAnimated) BOOL animated;
@end

typedef NS_ENUM(NSInteger, STKStrokeKind) {
	STKStrokeKindBrush,
	// A closed outline: everything inside it.
	STKStrokeKindLasso,
	// A closed outline: the object found inside it (by background removal run on just that area).
	STKStrokeKindSmartLasso,
	// The whole image: what's kept is erased and what's erased comes back. Has no points.
	STKStrokeKindInvert,
	// The whole image: restoring brings back all of the original, erasing clears everything. Has no points.
	STKStrokeKindWhole,
};

// One erase or restore edit, in coordinates normalized to the uncropped source image (0...1 on each axis), so the
// same edit applies to a full-resolution still, a video frame, or a downscaled preview.
@interface STKBrushStroke : NSObject
@property (nonatomic) STKStrokeKind kind;
@property (nonatomic) BOOL restores;
// Brush diameter as a fraction of the uncropped source image's width.
@property (nonatomic) CGFloat width;
// The brush's path, or the lasso's outline.
@property (nonatomic, copy) NSArray<NSValue *> *points;
// Smart lasso: the area searched for an object (normalized to the source) and what was found there in the frame it
// was drawn on, white where selected. Other frames of an animation get their own from +prepareStrokes:forFrames:crop:.
@property (nonatomic) CGRect selectionRect;
@property (nonatomic, nullable) UIImage *selectionMask;
@end

@interface STKStickerFactory : NSObject

// Background removal uses the private VisionKitCore engine behind "Copy Subject" in Photos (iOS 16, A12 or newer).
+ (BOOL)isSubjectLiftingSupported;
// Calls back on the main queue with a transparent cut-out of the main subject.
+ (void)liftSubjectFromImage:(UIImage *)image completion:(void (^)(UIImage *_Nullable subject, NSError *_Nullable error))completion;
// Lifts every frame, a few at a time. A frame with no subject reuses the nearest lifted frame, so the result lines up with the
// input frame for frame; fails if most frames have none.
+ (void)liftSubjectFromFrames:(NSArray<UIImage *> *)frames progress:(nullable void (^)(NSUInteger done, NSUInteger total))progress completion:(void (^)(NSArray<UIImage *> *_Nullable subjects, NSError *_Nullable error))completion;

// The part of the image inside a rect normalized to its size, drawn upright at scale 1 and capped at 2048 pixels.
+ (UIImage *)image:(UIImage *)image croppedToNormalizedRect:(CGRect)crop;

// Applies strokes to a frame cropped to crop (normalized): erasing clears pixels, restoring brings back the
// matching pixels of original (the same frame before background removal). Safe off the main thread.
+ (UIImage *)applyStrokes:(NSArray<STKBrushStroke *> *)strokes toImage:(UIImage *)image original:(UIImage *)original crop:(CGRect)crop;

// Finds the object inside a smart lasso in original (a frame cropped to crop) and keeps it as the stroke's selection.
// Calls back on the main queue with whether anything was found. Erasing prefers objects the outline goes all the way
// around, so circling something next to the subject removes that and not the bit of subject the circle clips.
+ (void)findSelectionForStroke:(STKBrushStroke *)stroke inImage:(UIImage *)original crop:(CGRect)crop completion:(void (^)(BOOL found))completion;
// Finds every smart lasso's object again in each frame of an animation, so the selection follows a moving subject.
// Blocks until done, so call it off the main thread.
+ (void)prepareStrokes:(NSArray<STKBrushStroke *> *)strokes forFrames:(NSArray<UIImage *> *)originals crop:(CGRect)crop;

// Trims transparent edges, optionally adds a white die-cut outline, fits the result in a square canvas and encodes it
// as PNG (one frame) or HEICS at the full frame rate, shrinking until it fits Messages' 500 KB sticker limit. Without
// HEICS, falls back to animated PNG then GIF with fewer frames. Safe off the main thread.
+ (STKRenderedSticker *)renderFrames:(NSArray<UIImage *> *)frames frameDuration:(NSTimeInterval)frameDuration outline:(BOOL)outline;

@end

NS_ASSUME_NONNULL_END
