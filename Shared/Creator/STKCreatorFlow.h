#import <UIKit/UIKit.h>

@class STKMediaSource;

NS_ASSUME_NONNULL_BEGIN

typedef void (^STKCreatorCompletion)(BOOL saved);

// Picks a photo, Live Photo, GIF or video and walks through making a sticker from it.
// Used (via STKCreator.dylib) by the emoji keyboard inside any app.
@interface STKCreatorFlow : NSObject

+ (void)presentPickerFromViewController:(UIViewController *)presenter completion:(nullable STKCreatorCompletion)completion;
+ (void)presentPreviewForSource:(STKMediaSource *)source fromViewController:(UIViewController *)presenter completion:(nullable STKCreatorCompletion)completion;

@end

// C entry point the keyboard tweak looks up with dlsym, so it only loads the creator when needed.
extern void STKPresentStickerCreator(UIViewController *presenter, STKCreatorCompletion _Nullable completion);

NS_ASSUME_NONNULL_END
