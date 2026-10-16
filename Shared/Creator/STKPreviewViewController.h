#import <UIKit/UIKit.h>

@class STKMediaSource;

NS_ASSUME_NONNULL_BEGIN

// Shows the sticker made from a photo, Live Photo, GIF or video, with background, animation and outline options,
// and saves it to the library.
@interface STKPreviewViewController : UIViewController

- (instancetype)initWithSource:(STKMediaSource *)source;

@property (nonatomic, copy, nullable) void (^onFinish)(BOOL saved);

@end

// A transparency checkerboard tile for canvas backgrounds.
UIImage *STKCheckerboardPattern(void);

NS_ASSUME_NONNULL_END
