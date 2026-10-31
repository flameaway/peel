#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The sticker grid shown in place of the emoji grid. Tap a sticker to insert it; touch and hold to peel it
// off and drag it, with a second finger to resize (up to STKMaxDragScale) and turn it. In Messages, dropping it on
// a bubble sticks it there; elsewhere a drop inserts it. Held and let go without dragging, it offers Rearrange
// (drag stickers around the grid, then tap the checkmark) and Delete.
@interface STKStickerPanel : UIView

- (void)reload;

@end

// How far a second finger can grow a sticker being dragged in Messages (its own drag view stops at 2).
extern const CGFloat STKMaxDragScale;

// A drawn "peeling sticker" glyph for the emoji category bar, sized like the category icons.
UIImage *STKStickerGlyph(CGFloat side);

// Looks up a function in STKCreator.dylib (the sticker maker), loading it the first time.
void *_Nullable STKCreatorSymbol(const char *name);

NS_ASSUME_NONNULL_END
