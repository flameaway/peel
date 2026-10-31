#import <UIKit/UIKit.h>

@class STKMediaSource;

NS_ASSUME_NONNULL_BEGIN

typedef void (^STKCreatorCompletion)(BOOL saved);

// Picks a photo, Live Photo, GIF or video and walks through making a sticker from it.
// Used (via STKCreator.dylib) by the emoji keyboard inside any app.
@interface STKCreatorFlow : NSObject

+ (void)presentPickerFromViewController:(UIViewController *)presenter completion:(nullable STKCreatorCompletion)completion;
// Loads a photo, Live Photo, GIF, video or cut-out (a transparent image) and goes straight to the preview.
+ (void)presentPreviewForItemProvider:(NSItemProvider *)provider fromViewController:(UIViewController *)presenter completion:(nullable STKCreatorCompletion)completion;
+ (void)presentPreviewForSource:(STKMediaSource *)source fromViewController:(UIViewController *)presenter completion:(nullable STKCreatorCompletion)completion;

@end

// C entry point the keyboard tweak looks up with dlsym, so it only loads the creator when needed.
extern void STKPresentStickerCreator(UIViewController *presenter, STKCreatorCompletion _Nullable completion);
// "Add Sticker" on a subject lifted from a photo: subject is the cut-out (as Copy gives it). When the photo is a Live
// Photo (a PHAsset or PHLivePhoto), the preview starts from its video instead, so the sticker is animated.
extern void STKPresentStickerCreatorForLiftedSubject(UIViewController *presenter, NSItemProvider *subject, id _Nullable livePhoto, STKCreatorCompletion _Nullable completion);

NS_ASSUME_NONNULL_END
