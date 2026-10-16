#import <UIKit/UIKit.h>

@class STKBrushStroke;

NS_ASSUME_NONNULL_BEGIN

// Touches up a cut-out with a brush: Erase removes what background removal left behind, Restore paints the original
// photo back in where it cut away too much. Pinch to zoom; drag with two fingers to move around.
@interface STKCutoutEditorViewController : UIViewController

// image is the current cut-out and original the same crop before background removal; crop is normalized to the
// uncropped source, which is what stroke coordinates are relative to.
- (instancetype)initWithImage:(UIImage *)image original:(UIImage *)original crop:(CGRect)crop strokes:(NSArray<STKBrushStroke *> *)strokes;

// Shown under the canvas, e.g. that edits apply to every frame of an animation.
@property (nonatomic, copy, nullable) NSString *hint;
@property (nonatomic, copy, nullable) void (^onDone)(NSArray<STKBrushStroke *> *strokes);

@end

NS_ASSUME_NONNULL_END
