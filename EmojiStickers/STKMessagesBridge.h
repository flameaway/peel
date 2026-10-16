#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Places stickers on message bubbles through Messages' own (private, iOS 16) ChatKit code path:
// -[CKChatController sendSticker:withDragTarget:], the same call its sticker drawer makes on drop.
@interface STKMessagesBridge : NSObject

// YES when running in Messages with a conversation on screen.
+ (BOOL)isAvailable;
// YES if there is a message bubble under the point (in screen coordinates).
+ (BOOL)canPlaceStickerAtScreenPoint:(CGPoint)point;
// Sends the sticker stuck to the bubble under the point. size is the sticker's on-screen size in points.
+ (BOOL)placeStickerAtURL:(NSURL *)url screenPoint:(CGPoint)point size:(CGSize)size rotation:(CGFloat)rotation;

@end

NS_ASSUME_NONNULL_END
