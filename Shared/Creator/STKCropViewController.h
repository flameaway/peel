#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Crops the photo or video a sticker is made from: drag the corners or edges of the box, or drag inside it to move it.
// The crop is a rect normalized to the image's size.
@interface STKCropViewController : UIViewController

- (instancetype)initWithImage:(UIImage *)image crop:(CGRect)crop;

@property (nonatomic, copy, nullable) void (^onDone)(CGRect crop);

@end

NS_ASSUME_NONNULL_END
