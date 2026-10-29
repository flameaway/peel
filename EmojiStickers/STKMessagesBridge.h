#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The balloon plugin our stickers are sent as coming from: Apple's stickers made from photos, so iOS 17 and later can
// save them.
extern NSString *const STKStickerPluginID;

// Places stickers on message bubbles and in the message being written through Messages' own (private, iOS 16) ChatKit
// code paths: -[CKChatController sendSticker:withDragTarget:], the call its sticker drawer makes on drop, and
// -[CKChatInputController startEditingPayload:] with a sticker payload, what the drawer does on tap.
@interface STKMessagesBridge : NSObject

// YES when running in Messages with a conversation on screen.
+ (BOOL)isAvailable;
// YES if there is a message bubble under the point (in screen coordinates).
+ (BOOL)canPlaceStickerAtScreenPoint:(CGPoint)point;
// Sends the sticker stuck to the bubble under the point. size is the sticker's on-screen size in points.
+ (BOOL)placeStickerAtURL:(NSURL *)url screenPoint:(CGPoint)point size:(CGSize)size rotation:(CGFloat)rotation;
// Adds the sticker to the message being written, as Messages' sticker drawer does on tap, so it's sent as a sticker
// (shown on its own, without a bubble) rather than as a photo.
+ (BOOL)stageStickerAtURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
