#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The sticker grid shown in place of the emoji grid. Tap a sticker to insert it; touch and hold to peel it
// off and drag it. In Messages, dropping it on a bubble sticks it there; elsewhere a drop inserts it.
@interface STKStickerPanel : UIView

- (void)reload;

@end

// A drawn "peeling sticker" glyph for the emoji category bar, sized like the category icons.
UIImage *STKStickerGlyph(CGFloat side);

NS_ASSUME_NONNULL_END
