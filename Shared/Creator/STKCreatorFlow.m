#import "STKCreatorFlow.h"
#import "STKMediaSource.h"
#import "STKPreviewViewController.h"
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>

static const void *kFlowKey = &kFlowKey;

@interface STKCreatorFlow () <PHPickerViewControllerDelegate>
@property (nonatomic, weak) UIViewController *presenter;
@property (nonatomic, copy) STKCreatorCompletion completion;
@end

@implementation STKCreatorFlow

+ (void)presentPickerFromViewController:(UIViewController *)presenter completion:(STKCreatorCompletion)completion {
	PHPickerConfiguration *configuration = [PHPickerConfiguration new];
	configuration.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.livePhotosFilter, PHPickerFilter.videosFilter]];
	configuration.selectionLimit = 1;
	// Keep GIFs and Live Photos as they are instead of transcoding them to a compatible still.
	configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
	PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];

	STKCreatorFlow *flow = [self new];
	flow.presenter = presenter;
	flow.completion = completion;
	picker.delegate = flow;
	// The picker only holds its delegate weakly; tie the flow's lifetime to it.
	objc_setAssociatedObject(picker, kFlowKey, flow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	[presenter presentViewController:picker animated:YES completion:nil];
}

+ (void)presentPreviewForSource:(STKMediaSource *)source fromViewController:(UIViewController *)presenter completion:(STKCreatorCompletion)completion {
	STKPreviewViewController *preview = [[STKPreviewViewController alloc] initWithSource:source];
	preview.onFinish = completion;
	UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:preview];
	navigation.modalInPresentation = YES;
	[presenter presentViewController:navigation animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
	NSItemProvider *provider = results.firstObject.itemProvider;
	STKCreatorCompletion completion = self.completion;
	UIViewController *presenter = self.presenter;
	// Wait for the picker to finish dismissing; presenting the preview while it animates away is silently dropped.
	[picker dismissViewControllerAnimated:YES completion:^{
		if (!provider || !presenter) {
			if (completion) {
				completion(NO);
			}
			return;
		}
		[STKCreatorFlow presentPreviewForItemProvider:provider fromViewController:presenter completion:completion];
	}];
}

+ (void)presentPreviewForItemProvider:(NSItemProvider *)provider fromViewController:(UIViewController *)presenter completion:(STKCreatorCompletion)completion {
	[STKMediaSource loadFromItemProvider:provider completion:^(STKMediaSource *source, NSError *error) {
		if (!source) {
			UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Load Photo" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
			[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
			[presenter presentViewController:alert animated:YES completion:nil];
			if (completion) {
				completion(NO);
			}
			return;
		}
		[STKCreatorFlow presentPreviewForSource:source fromViewController:presenter completion:completion];
	}];
}

@end

__attribute__((visibility("default"))) void STKPresentStickerCreator(UIViewController *presenter, STKCreatorCompletion completion) {
	[STKCreatorFlow presentPickerFromViewController:presenter completion:completion];
}

__attribute__((visibility("default"))) void STKPresentStickerCreatorForLiftedSubject(UIViewController *presenter, NSItemProvider *subject, id livePhoto, STKCreatorCompletion completion) {
	void (^loaded)(STKMediaSource *, NSError *) = ^(STKMediaSource *source, NSError *error) {
		if (source.animated) {
			[STKCreatorFlow presentPreviewForSource:source fromViewController:presenter completion:completion];
		} else {
			NSLog(@"[EmojiStickers] Add Sticker: using the still cut-out, the Live Photo didn't load: %@", error);
			[STKCreatorFlow presentPreviewForItemProvider:subject fromViewController:presenter completion:completion];
		}
	};
	if ([livePhoto isKindOfClass:PHAsset.class]) {
		[STKMediaSource loadLivePhotoAsset:livePhoto completion:loaded];
	} else if ([livePhoto isKindOfClass:PHLivePhoto.class]) {
		[STKMediaSource loadLivePhoto:livePhoto completion:loaded];
	} else {
		[STKCreatorFlow presentPreviewForItemProvider:subject fromViewController:presenter completion:completion];
	}
}
