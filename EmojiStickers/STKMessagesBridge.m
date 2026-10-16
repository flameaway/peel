#import "STKMessagesBridge.h"
#import <ImageIO/ImageIO.h>

// Private ChatKit / IMSharedUtilities API (iOS 16), signatures checked against the iOS 16.4 binaries.
@interface CKBrowserDragControllerTarget : NSObject
+ (instancetype)targetWithScreenCoordinate:(CGPoint)screenCoordinate initialSize:(CGSize)initialSize scale:(double)scale meshScaleFactor:(double)meshScaleFactor rotation:(double)rotation associatedLayoutIntent:(NSInteger)layoutIntent;
@end

@interface CKChatController : UIViewController
- (NSIndexPath *)selectedBalloonForTarget:(CKBrowserDragControllerTarget *)target;
- (void)sendSticker:(id)sticker withDragTarget:(CKBrowserDragControllerTarget *)target;
@end

@interface IMSticker : NSObject
- (instancetype)initWithStickerID:(NSString *)stickerID stickerPackID:(NSString *)stickerPackID fileURL:(NSURL *)fileURL accessibilityLabel:(NSString *)accessibilityLabel moodCategory:(id)moodCategory stickerName:(NSString *)stickerName;
- (void)setBallonBundleID:(NSString *)bundleID;
@end

@interface IMBalloonPluginManager : NSObject
+ (instancetype)sharedInstance;
- (id)allPlugins;
@end

@interface IMBalloonPlugin : NSObject
- (NSString *)identifier;
@end

static NSString *const kStickersExtensionBundleID = @"com.josh.stickers.messages";
// Apple's own user-made stickers. Used only if our iMessage app isn't registered.
static NSString *const kFallbackPluginID = @"com.apple.messages.MSMessageExtensionBalloonPlugin:0000000000:com.apple.Stickers.UserGenerated.MessagesExtension";

// Receiving devices only show stickers that are attributed to an iMessage app, identified by its balloon plugin ID
// ("com.apple.messages.MSMessageExtensionBalloonPlugin:<team>:<bundle id>"), so send ours as coming from the
// Stickers iMessage app bundled with the tweak.
static NSString *STKStickerPluginID(void) {
	static NSString *pluginID;
	if (pluginID) {
		return pluginID;
	}
	id plugins = [[NSClassFromString(@"IMBalloonPluginManager") sharedInstance] allPlugins];
	if ([plugins isKindOfClass:NSDictionary.class]) {
		plugins = [plugins allValues];
	}
	for (IMBalloonPlugin *plugin in plugins) {
		NSString *identifier = [plugin respondsToSelector:@selector(identifier)] ? plugin.identifier : nil;
		if ([identifier hasSuffix:[@":" stringByAppendingString:kStickersExtensionBundleID]]) {
			pluginID = identifier;
			break;
		}
	}
	NSLog(@"[EmojiStickers] sticker plugin ID %@", pluginID ?: kFallbackPluginID);
	return pluginID ?: kFallbackPluginID;
}

static CKChatController *STKFindChatController(UIViewController *controller) {
	Class chatClass = NSClassFromString(@"CKChatController");
	if (!controller || !chatClass) {
		return nil;
	}
	if ([controller isKindOfClass:chatClass] && controller.viewIfLoaded.window) {
		return (CKChatController *)controller;
	}
	for (UIViewController *child in controller.childViewControllers) {
		CKChatController *found = STKFindChatController(child);
		if (found) {
			return found;
		}
	}
	return STKFindChatController(controller.presentedViewController);
}

static CKChatController *STKVisibleChatController(void) {
	if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"]) {
		return nil;
	}
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) {
			continue;
		}
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			CKChatController *chat = STKFindChatController(window.rootViewController);
			if (chat) {
				return chat;
			}
		}
	}
	return nil;
}

static CKBrowserDragControllerTarget *STKTarget(CKChatController *chat, CGPoint screenPoint, CGSize size, double scale, CGFloat rotation) {
	Class targetClass = NSClassFromString(@"CKBrowserDragControllerTarget");
	if (![targetClass respondsToSelector:@selector(targetWithScreenCoordinate:initialSize:scale:meshScaleFactor:rotation:associatedLayoutIntent:)]) {
		return nil;
	}
	// ChatKit compares the coordinate against balloon frames converted to the transcript's window.
	UIWindow *window = chat.view.window;
	CGPoint point = [window convertPoint:screenPoint fromCoordinateSpace:window.screen.coordinateSpace];
	return [targetClass targetWithScreenCoordinate:point initialSize:size scale:scale meshScaleFactor:1 rotation:rotation associatedLayoutIntent:0];
}

// Messages draws a placed sticker at its natural size (pixels / screen scale) times the target's scale.
static double STKScaleForSize(NSURL *url, CGSize size, UIScreen *screen) {
	// Read the pixel size from the header; decoding a frame of a HEICS sticker is slow.
	CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
	NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
	if (source) {
		CFRelease(source);
	}
	CGFloat pixels = MAX([properties[(__bridge NSString *)kCGImagePropertyPixelWidth] doubleValue], [properties[(__bridge NSString *)kCGImagePropertyPixelHeight] doubleValue]);
	CGFloat natural = pixels / (screen.scale ?: 3);
	return natural > 0 ? MAX(size.width, size.height) / natural : 1;
}

@implementation STKMessagesBridge

+ (BOOL)isAvailable {
	CKChatController *chat = STKVisibleChatController();
	return chat && [chat respondsToSelector:@selector(sendSticker:withDragTarget:)] && [chat respondsToSelector:@selector(selectedBalloonForTarget:)] && NSClassFromString(@"IMSticker");
}

+ (BOOL)canPlaceStickerAtScreenPoint:(CGPoint)point {
	if (![self isAvailable]) {
		return NO;
	}
	CKChatController *chat = STKVisibleChatController();
	CKBrowserDragControllerTarget *target = STKTarget(chat, point, CGSizeMake(100, 100), 1, 0);
	return target && [chat selectedBalloonForTarget:target] != nil;
}

+ (BOOL)placeStickerAtURL:(NSURL *)url screenPoint:(CGPoint)point size:(CGSize)size rotation:(CGFloat)rotation {
	if (![self isAvailable]) {
		return NO;
	}
	CKChatController *chat = STKVisibleChatController();
	CKBrowserDragControllerTarget *target = STKTarget(chat, point, size, STKScaleForSize(url, size, chat.view.window.screen), rotation);
	// sendSticker:withDragTarget: indexes the chat items with this result without checking it, so never call it off a bubble.
	if (!target || ![chat selectedBalloonForTarget:target]) {
		return NO;
	}
	NSString *pluginID = STKStickerPluginID();
	IMSticker *sticker = [[NSClassFromString(@"IMSticker") alloc] initWithStickerID:url.lastPathComponent stickerPackID:pluginID fileURL:url accessibilityLabel:@"Sticker" moodCategory:nil stickerName:nil];
	if (!sticker) {
		return NO;
	}
	if ([sticker respondsToSelector:@selector(setBallonBundleID:)]) {
		[sticker setBallonBundleID:pluginID];
	}
	[chat sendSticker:sticker withDragTarget:target];
	return YES;
}

@end
