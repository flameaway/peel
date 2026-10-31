#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import "STKStickerPanel.h"

// Adds "Add Sticker" next to Copy and Share on the menu that comes up when you touch and hold the subject of a photo
// (iOS 16's subject lifting, in Photos, Messages, Safari, Quick Look and any app using VisionKit's image analysis).
// It hands the same cut-out Copy would put on the pasteboard to the sticker maker's preview, or, for a Live Photo, the
// Live Photo itself so the sticker comes out animated.

// VisionKitCore's view over the photo that lifts the subject and shows the menu. It only allows copy: and _share:.
@interface VKCImageSubjectHighlightView : UIView
// The cut-out, as Copy and Share use it.
- (NSItemProvider *)createItemProvider;
@end

// The app's side of the image analysis interaction on the photo. In Photos it's the photo's tile, which knows the asset.
@interface NSObject (STKImageAnalysisHost)
- (BOOL)isShowingLivePhotoForImageAnalysisInteraction:(id)interaction;
- (id)assetViewModel;
- (id)asset;
- (NSUInteger)mediaSubtypes;
- (id)livePhoto;
@end

typedef void (*STKPresentCreatorForLiftedSubjectFunction)(UIViewController *, NSItemProvider *, id, void (^)(BOOL));

// PHAssetMediaSubtypePhotoLive, without linking Photos into every app.
static const NSUInteger kLivePhotoSubtype = 1 << 3;

// The Live Photo the subject was lifted from, if the app is showing the photo as one: a PHAsset in Photos, or a
// PHLivePhoto in apps that show it in a PHLivePhotoView. Nil for stills, and for Live Photos with Live turned off.
static id STKLivePhotoForSubjectView(UIView *view) {
	Class assetClass = NSClassFromString(@"PHAsset"), livePhotoClass = NSClassFromString(@"PHLivePhoto");
	for (UIView *ancestor = view.superview; ancestor; ancestor = ancestor.superview) {
		for (id<UIInteraction> interaction in ancestor.interactions) {
			if (![NSStringFromClass(interaction.class) containsString:@"ImageAnalysisInteraction"] || ![interaction respondsToSelector:@selector(delegate)]) {
				continue;
			}
			NSObject *host = [(id)interaction delegate];
			if ([host respondsToSelector:@selector(isShowingLivePhotoForImageAnalysisInteraction:)] && ![host isShowingLivePhotoForImageAnalysisInteraction:interaction]) {
				return nil;
			}
			if ([host respondsToSelector:@selector(assetViewModel)]) {
				NSObject *model = host.assetViewModel;
				id asset = [model respondsToSelector:@selector(asset)] ? model.asset : nil;
				if (assetClass && [asset isKindOfClass:assetClass] && ([asset mediaSubtypes] & kLivePhotoSubtype)) {
					return asset;
				}
			}
		}
		if (livePhotoClass && [ancestor respondsToSelector:@selector(livePhoto)]) {
			id livePhoto = [(NSObject *)ancestor livePhoto];
			if ([livePhoto isKindOfClass:livePhotoClass]) {
				return livePhoto;
			}
		}
	}
	return nil;
}

// The menu's own name for the command, so the edit menu can tell it apart from ones the app adds.
static UIMenuIdentifier const kAddStickerMenu = @"com.flame.stickers.add-sticker";

static UIViewController *STKPresenterForView(UIView *view) {
	UIViewController *controller = view.window.rootViewController;
	while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
		controller = controller.presentedViewController;
	}
	return controller;
}

%group SubjectLift

%hook VKCImageSubjectHighlightView

// The menu is UIMenuController's (shown with showMenuFromView:rect:), which on iOS 16 builds its Copy and Share
// from the responder chain's context menu. Add Sticker goes between them; menuItems would put it after Share.
- (void)buildMenuWithBuilder:(id<UIMenuBuilder>)builder {
	%orig;
	if (builder.system != UIMenuSystem.contextSystem || [builder menuForIdentifier:kAddStickerMenu]) {
		return;
	}
	UICommand *add = [UICommand commandWithTitle:@"Add Sticker" image:nil action:@selector(stk_addSticker:) propertyList:nil];
	UIMenu *menu = [UIMenu menuWithTitle:@"" image:nil identifier:kAddStickerMenu options:UIMenuOptionsDisplayInline children:@[add]];
	if ([builder menuForIdentifier:UIMenuShare]) {
		[builder insertSiblingMenu:menu beforeMenuForIdentifier:UIMenuShare];
	} else if ([builder menuForIdentifier:UIMenuStandardEdit]) {
		[builder insertSiblingMenu:menu afterMenuForIdentifier:UIMenuStandardEdit];
	} else {
		[builder insertChildMenu:menu atEndOfMenuForIdentifier:UIMenuRoot];
	}
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
	if (action == @selector(stk_addSticker:)) {
		return [self respondsToSelector:@selector(createItemProvider)];
	}
	return %orig;
}

%new
- (void)stk_addSticker:(id)sender {
	NSItemProvider *provider = [self createItemProvider];
	STKPresentCreatorForLiftedSubjectFunction present = (STKPresentCreatorForLiftedSubjectFunction)STKCreatorSymbol("STKPresentStickerCreatorForLiftedSubject");
	UIViewController *presenter = STKPresenterForView(self);
	if (!provider || !present || !presenter) {
		NSLog(@"[EmojiStickers] Add Sticker: provider %@, sticker maker %p, presenter %@", provider, present, presenter);
		return;
	}
	present(presenter, provider, STKLivePhotoForSubjectView(self), nil);
}

%end

%end

static void STKHookSubjectLift(void) {
	static dispatch_once_t once;
	if (objc_getClass("VKCImageSubjectHighlightView")) {
		dispatch_once(&once, ^{
			%init(SubjectLift);
		});
	}
}

// Apps load VisionKitCore when they first analyze an image, usually well after launch.
static void STKImageAdded(const struct mach_header *header, intptr_t slide) {
	Dl_info info;
	if (dladdr(header, &info) && info.dli_fname && strstr(info.dli_fname, "/VisionKitCore.framework/")) {
		dispatch_async(dispatch_get_main_queue(), ^{
			STKHookSubjectLift();
		});
	}
}

%ctor {
	if (objc_getClass("VKCImageSubjectHighlightView")) {
		STKHookSubjectLift();
	} else {
		_dyld_register_func_for_add_image(STKImageAdded);
	}
}
