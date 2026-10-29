#import "STKStickerPanel.h"
#import "STKMessagesBridge.h"
#import "STKImageLoading.h"
#import "STKStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>
#import <objc/runtime.h>

#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX ""
#endif

static const CGFloat kDragStickerSide = 110;

UIImage *STKStickerGlyph(CGFloat side) {
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
	UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		CGFloat inset = side * 0.14, fold = side * 0.3, line = MAX(1.5, side * 0.085);
		CGRect r = CGRectInset(CGRectMake(0, 0, side, side), inset, inset);
		UIBezierPath *outline = [UIBezierPath bezierPath];
		[outline moveToPoint:CGPointMake(CGRectGetMinX(r) + fold * 0.6, CGRectGetMinY(r))];
		[outline addLineToPoint:CGPointMake(CGRectGetMaxX(r) - fold * 0.6, CGRectGetMinY(r))];
		[outline addQuadCurveToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r) + fold * 0.6) controlPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))];
		[outline addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - fold)];
		[outline addLineToPoint:CGPointMake(CGRectGetMaxX(r) - fold, CGRectGetMaxY(r))];
		[outline addLineToPoint:CGPointMake(CGRectGetMinX(r) + fold * 0.6, CGRectGetMaxY(r))];
		[outline addQuadCurveToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r) - fold * 0.6) controlPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))];
		[outline addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r) + fold * 0.6)];
		[outline addQuadCurveToPoint:CGPointMake(CGRectGetMinX(r) + fold * 0.6, CGRectGetMinY(r)) controlPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))];
		[outline closePath];
		outline.lineWidth = line;
		outline.lineJoinStyle = kCGLineJoinRound;
		[UIColor.blackColor setStroke];
		[outline stroke];
		// The peeled corner.
		UIBezierPath *corner = [UIBezierPath bezierPath];
		[corner moveToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - fold)];
		[corner addQuadCurveToPoint:CGPointMake(CGRectGetMaxX(r) - fold, CGRectGetMaxY(r)) controlPoint:CGPointMake(CGRectGetMaxX(r) - fold * 1.05, CGRectGetMaxY(r) - fold * 1.05)];
		[corner closePath];
		[UIColor.blackColor setFill];
		[corner fill];
	}];
	return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface UIKeyboardImpl : NSObject
+ (instancetype)activeInstance;
- (UIResponder *)delegate;
@end

// UIKit's own text views drop pasted images unless they allow rich text or have a paste delegate to handle them, so a
// paste: there does nothing.
static BOOL STKDropsPastedImages(UIResponder *responder) {
	for (Class textClass in @[UITextView.class, UITextField.class]) {
		if ([responder isKindOfClass:textClass] && [responder methodForSelector:@selector(paste:)] == [textClass instanceMethodForSelector:@selector(paste:)]) {
			UITextView *text = (UITextView *)responder;
			return !text.allowsEditingTextAttributes && !text.pasteDelegate;
		}
	}
	return NO;
}

// Whether the responder's paste: is the app's own code rather than UIKit's (or a system framework's). Apps like
// Instagram accept images in pasteItemProviders: (UIKit's, which drops them) but only handle them in their own paste:,
// which is what the Paste menu calls.
static BOOL STKHasAppPasteHandler(UIResponder *responder) {
	Dl_info info;
	IMP imp = [responder methodForSelector:@selector(paste:)];
	return imp && dladdr((const void *)imp, &info) && info.dli_fname && strstr(info.dli_fname, "/containers/Bundle/Application/");
}

// Pastes pasteboard items into the text field the keyboard is typing into. Returns NO if nothing there takes images;
// the items are left on the pasteboard either way.
static BOOL STKPasteItems(NSArray<NSDictionary<NSString *, id> *> *items) {
	// The system keyboard runs inside the app, so this is the app pasting its own pasteboard content: no paste prompt.
	[UIPasteboard.generalPasteboard setItems:items options:@{}];
	NSString *typeIdentifier = items.firstObject.allKeys.firstObject;
	NSData *data = items.firstObject[typeIdentifier];

	// The keyboard's delegate is the field being typed in, even when it isn't in the key window (where a nil-targeted
	// paste: would go).
	Class keyboardClass = NSClassFromString(@"UIKeyboardImpl");
	UIResponder *field = [keyboardClass respondsToSelector:@selector(activeInstance)] ? [[keyboardClass activeInstance] delegate] : nil;
	if (![field isKindOfClass:UIResponder.class]) {
		return [UIApplication.sharedApplication sendAction:@selector(paste:) to:nil from:nil forEvent:nil];
	}
	NSArray<NSItemProvider *> *providers = @[[[NSItemProvider alloc] initWithItem:data typeIdentifier:typeIdentifier]];
	// Logged so it's possible to see why an app ignores pasted stickers (oslog | grep EmojiStickers).
	NSMutableArray<NSString *> *chain = [NSMutableArray array];
	for (UIResponder *responder = field; responder; responder = responder.nextResponder) {
		[chain addObject:NSStringFromClass(responder.class)];
		if (STKHasAppPasteHandler(responder) && [responder canPerformAction:@selector(paste:) withSender:nil]) {
			NSLog(@"[EmojiStickers] %@ %@: app's own paste: on %@", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, [chain componentsJoinedByString:@" > "]);
			[responder paste:nil];
			return YES;
		}
		// Views that declare what they accept (UIPasteConfigurationSupporting) take the image directly.
		if (responder.pasteConfiguration && [responder canPasteItemProviders:providers]) {
			NSLog(@"[EmojiStickers] %@ %@: pasteItemProviders: on %@", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, [chain componentsJoinedByString:@" > "]);
			[responder pasteItemProviders:providers];
			return YES;
		}
		if ([responder canPerformAction:@selector(paste:) withSender:nil]) {
			BOOL drops = STKDropsPastedImages(responder);
			NSLog(@"[EmojiStickers] %@ %@: paste: on %@%@ (pasteConfiguration %@, pasteDelegate %@)", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, [chain componentsJoinedByString:@" > "], drops ? @" skipped, UIKit drops images there" : @"",
				responder.pasteConfiguration.acceptableTypeIdentifiers, [responder respondsToSelector:@selector(pasteDelegate)] ? [(UITextView *)responder pasteDelegate] : nil);
			if (drops) {
				return NO;
			}
			[responder paste:nil];
			return YES;
		}
	}
	NSLog(@"[EmojiStickers] %@ %@: nothing takes paste: in %@", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, [chain componentsJoinedByString:@" > "]);
	return NO;
}

// A drop of the sticker that never came from a drag, for handing it to an app's drop target.
@interface STKDropSession : NSObject <UIDropSession>
- (instancetype)initWithItemProvider:(NSItemProvider *)provider location:(CGPoint)location inView:(UIView *)view;
@end

@implementation STKDropSession {
	NSArray<UIDragItem *> *_items;
	CGPoint _location;
	__weak UIView *_view;
}

- (instancetype)initWithItemProvider:(NSItemProvider *)provider location:(CGPoint)location inView:(UIView *)view {
	if ((self = [super init])) {
		_items = @[[[UIDragItem alloc] initWithItemProvider:provider]];
		_location = location;
		_view = view;
	}
	return self;
}

- (NSArray<UIDragItem *> *)items {
	return _items;
}

- (CGPoint)locationInView:(UIView *)view {
	UIView *source = _view;
	return source && view ? [view convertPoint:_location fromView:source] : _location;
}

- (BOOL)allowsMoveOperation {
	return NO;
}

- (BOOL)isRestrictedToDraggingApplication {
	return NO;
}

- (BOOL)hasItemsConformingToTypeIdentifiers:(NSArray<NSString *> *)typeIdentifiers {
	NSLog(@"[EmojiStickers] drop session asked for types %@", typeIdentifiers);
	for (UIDragItem *item in _items) {
		if ([item.itemProvider hasItemConformingToTypeIdentifier:typeIdentifiers.firstObject] || [[item.itemProvider.registeredTypeIdentifiers filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *type, NSDictionary *bindings) {
			for (NSString *wanted in typeIdentifiers) {
				if ([[UTType typeWithIdentifier:type] conformsToType:[UTType typeWithIdentifier:wanted] ?: UTTypeData]) {
					return YES;
				}
			}
			return NO;
		}]] count]) {
			return YES;
		}
	}
	return NO;
}

- (BOOL)canLoadObjectsOfClass:(Class<NSItemProviderReading>)aClass {
	NSLog(@"[EmojiStickers] drop session asked if it can load %@", aClass);
	for (UIDragItem *item in _items) {
		if ([item.itemProvider canLoadObjectOfClass:aClass]) {
			return YES;
		}
	}
	return NO;
}

- (id<UIDragSession>)localDragSession {
	return nil;
}

- (UIDropSessionProgressIndicatorStyle)progressIndicatorStyle {
	return UIDropSessionProgressIndicatorStyleNone;
}

- (void)setProgressIndicatorStyle:(UIDropSessionProgressIndicatorStyle)style {
}

- (NSProgress *)progress {
	return [NSProgress discreteProgressWithTotalUnitCount:1];
}

- (NSProgress *)loadObjectsOfClass:(Class<NSItemProviderReading>)aClass completion:(void (^)(NSArray<__kindof id<NSItemProviderReading>> *objects))completion {
	NSLog(@"[EmojiStickers] drop session loading %@", aClass);
	NSProgress *progress = [NSProgress discreteProgressWithTotalUnitCount:_items.count];
	NSMutableArray *objects = [NSMutableArray array];
	dispatch_group_t group = dispatch_group_create();
	for (UIDragItem *item in _items) {
		if (![item.itemProvider canLoadObjectOfClass:aClass]) {
			continue;
		}
		dispatch_group_enter(group);
		[item.itemProvider loadObjectOfClass:aClass completionHandler:^(id<NSItemProviderReading> object, NSError *error) {
			@synchronized (objects) {
				if (object) {
					[objects addObject:object];
				}
			}
			progress.completedUnitCount++;
			dispatch_group_leave(group);
		}];
	}
	// UIKit calls back on the main queue.
	dispatch_group_notify(group, dispatch_get_main_queue(), ^{
		completion(objects);
	});
	return progress;
}

@end

// Whether the object's class is the app's own code rather than a system framework's.
static BOOL STKIsAppClass(id object) {
	const char *image = object ? class_getImageName(object_getClass(object)) : NULL;
	return image && strstr(image, "/containers/Bundle/Application/");
}

// Apps that take images dropped on a conversation but not pasted: Instagram's paste hands images to a handler its
// DMs don't set up, while its drop target sends them.
static BOOL STKPrefersDrop(void) {
	return [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.burbn.instagram"];
}

// Drops the sticker on the nearest drop target of the app's own around the text field being typed in, as if it was
// dragged there. Returns NO if there's none that takes it.
static BOOL STKDropItems(NSArray<NSDictionary<NSString *, id> *> *items) {
	Class keyboardClass = NSClassFromString(@"UIKeyboardImpl");
	id field = [keyboardClass respondsToSelector:@selector(activeInstance)] ? [[keyboardClass activeInstance] delegate] : nil;
	if (![field isKindOfClass:UIView.class]) {
		return NO;
	}
	NSString *typeIdentifier = items.firstObject.allKeys.firstObject;
	NSData *data = items.firstObject[typeIdentifier];
	if (!data) {
		return NO;
	}
	for (UIView *view = field; view; view = view.superview) {
		for (id<UIInteraction> interaction in view.interactions) {
			if ([interaction isKindOfClass:UIDropInteraction.class]) {
				NSLog(@"[EmojiStickers] (all) drop target %@ on %@", [(UIDropInteraction *)interaction delegate].class, view.class);
			}
		}
	}
	for (UIView *view = field; view; view = view.superview) {
		for (id<UIInteraction> interaction in view.interactions) {
			if (![interaction isKindOfClass:UIDropInteraction.class]) {
				continue;
			}
			UIDropInteraction *drop = (UIDropInteraction *)interaction;
			id<UIDropInteractionDelegate> delegate = drop.delegate;
			NSLog(@"[EmojiStickers] drop target %@ on %@ (app's own %d)", [delegate class], view.class, STKIsAppClass(delegate));
			if (!STKIsAppClass(delegate) || ![delegate respondsToSelector:@selector(dropInteraction:performDrop:)]) {
				continue;
			}
			NSItemProvider *provider = [[NSItemProvider alloc] initWithItem:data typeIdentifier:typeIdentifier];
			CGPoint center = CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds));
			STKDropSession *session = [[STKDropSession alloc] initWithItemProvider:provider location:center inView:view];
			if ([delegate respondsToSelector:@selector(dropInteraction:canHandleSession:)] && ![delegate dropInteraction:drop canHandleSession:session]) {
				NSLog(@"[EmojiStickers] %@ %@: %@ on %@ won't take the drop", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, delegate.class, view.class);
				continue;
			}
			if ([delegate respondsToSelector:@selector(dropInteraction:sessionDidEnter:)]) {
				[delegate dropInteraction:drop sessionDidEnter:session];
			}
			UIDropOperation operation = UIDropOperationCopy;
			if ([delegate respondsToSelector:@selector(dropInteraction:sessionDidUpdate:)]) {
				operation = [delegate dropInteraction:drop sessionDidUpdate:session].operation;
			}
			if (operation != UIDropOperationCopy && operation != UIDropOperationMove) {
				if ([delegate respondsToSelector:@selector(dropInteraction:sessionDidExit:)]) {
					[delegate dropInteraction:drop sessionDidExit:session];
				}
				NSLog(@"[EmojiStickers] %@ %@: %@ on %@ proposed operation %lu", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, delegate.class, view.class, (unsigned long)operation);
				continue;
			}
			NSLog(@"[EmojiStickers] %@ %@: dropping on %@ of %@", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, delegate.class, view.class);
			[delegate dropInteraction:drop performDrop:session];
			if ([delegate respondsToSelector:@selector(dropInteraction:concludeDrop:)]) {
				[delegate dropInteraction:drop concludeDrop:session];
			}
			if ([delegate respondsToSelector:@selector(dropInteraction:sessionDidEnd:)]) {
				[delegate dropInteraction:drop sessionDidEnd:session];
			}
			return YES;
		}
	}
	NSLog(@"[EmojiStickers] %@ %@: no drop target of the app's around %@", NSBundle.mainBundle.bundleIdentifier, typeIdentifier, [field class]);
	return NO;
}

// Inserts a sticker: in Messages as a real sticker in the message being written, elsewhere as an image, converting
// HEICS stickers to GIF off the main thread first. Calls back on the main queue with whether anything took it.
static void STKInsertSticker(NSURL *url, void (^completion)(BOOL inserted)) {
	if ([STKMessagesBridge stageStickerAtURL:url]) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(YES);
		});
		return;
	}
	BOOL telegram = [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"ph.telegra.Telegraph"];
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray<NSDictionary<NSString *, id> *> *items = nil;
		if (telegram) {
			items = STKTelegramPasteboardItems(url);
		}
		if (!items) {
			NSString *type = nil;
			NSData *data = STKPasteableStickerData(url, &type);
			items = data && type ? @[@{type: data}] : nil;
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(items && ((STKPrefersDrop() && STKDropItems(items)) || STKPasteItems(items)));
		});
	});
}

// Messages' own sticker drag view (ChatKit, iOS 16): the peel, shine and elastic follow its sticker drawer uses.
@interface CKBrowserDragStickerView : UIView
- (instancetype)initWithSourceRect:(CGRect)sourceRect dragImage:(id)dragImage;
- (void)setCanPeel:(BOOL)canPeel;
- (void)setPressed:(BOOL)pressed;
- (void)animatePeelWithCompletion:(void (^)(void))completion;
- (void)setInitialDragStartPosition:(CGPoint)position;
- (void)attachElasticEffectsForLocation:(CGPoint)location;
- (void)updateElasticEffectsForLocation:(CGPoint)location;
- (void)detachElasticEffects;
- (void)updateAnimationTimerObserving;
- (CGPoint)dragViewCenter;
- (CGSize)initialSize;
// The view is drawn at initialSize times both of these.
- (double)initialScale;
- (double)dragViewScale;
- (void)reversePeelAnimationToPoint:(CGPoint)point forPlacement:(BOOL)placement shouldShrink:(BOOL)shrink completionBlock:(void (^)(void))completion;
@end

// Frames and durations, which is what the drag view takes as its image.
@interface CKAnimatedImage : NSObject
- (instancetype)initWithImages:(NSArray<UIImage *> *)images durations:(NSArray<NSNumber *> *)durations;
@end

// Where an image of the given size shows in bounds with aspect-fit, so the peel starts exactly over the thumbnail.
static CGRect STKAspectFitRect(CGSize size, CGRect bounds) {
	if (size.width <= 0 || size.height <= 0) {
		return bounds;
	}
	CGFloat factor = MIN(bounds.size.width / size.width, bounds.size.height / size.height);
	CGSize fitted = CGSizeMake(size.width * factor, size.height * factor);
	return CGRectMake(CGRectGetMidX(bounds) - fitted.width / 2, CGRectGetMidY(bounds) - fitted.height / 2, fitted.width, fitted.height);
}

static BOOL STKNativePeelAvailable(void) {
	Class viewClass = NSClassFromString(@"CKBrowserDragStickerView");
	SEL selectors[] = {@selector(initWithSourceRect:dragImage:), @selector(setCanPeel:), @selector(setPressed:), @selector(animatePeelWithCompletion:),
		@selector(setInitialDragStartPosition:), @selector(attachElasticEffectsForLocation:), @selector(updateElasticEffectsForLocation:),
		@selector(detachElasticEffects), @selector(updateAnimationTimerObserving), @selector(dragViewCenter), @selector(initialSize),
		@selector(reversePeelAnimationToPoint:forPlacement:shouldShrink:completionBlock:)};
	for (size_t i = 0; viewClass && i < sizeof(selectors) / sizeof(*selectors); i++) {
		if (![viewClass instancesRespondToSelector:selectors[i]]) {
			return NO;
		}
	}
	return viewClass && [NSClassFromString(@"CKAnimatedImage") instancesRespondToSelector:@selector(initWithImages:durations:)];
}

// The sticker's silhouette as a template image: a line around its edge over a faint fill, like the spot a sticker
// leaves on its sheet once peeled off.
static UIImage *STKStickerOutline(UIImage *image, CGSize size) {
	image = image.images.firstObject ?: image;
	if (!image || size.width <= 0 || size.height <= 0) {
		return nil;
	}
	CGRect fit = STKAspectFitRect(image.size, CGRectMake(0, 0, size.width, size.height));
	CGFloat line = 2;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
	UIImage *outline = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		// The silhouette spread outward by the line width...
		for (int i = 0; i < 16; i++) {
			CGFloat angle = i * M_PI / 8;
			[image drawInRect:CGRectOffset(fit, cos(angle) * line, sin(angle) * line)];
		}
		[UIColor.blackColor setFill];
		UIRectFillUsingBlendMode(context.format.bounds, kCGBlendModeSourceIn);
		// ...mostly cut away by the silhouette itself, leaving the line and a faint fill inside it.
		[image drawInRect:fit blendMode:kCGBlendModeDestinationOut alpha:0.88];
	}];
	return [outline imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface STKPanelCell : UICollectionViewCell
@property (nonatomic, readonly) UIImageView *imageView;
// The sticker shown, so a thumbnail that finishes loading late lands in the right cell.
@property (nonatomic, copy) NSURL *url;
// While its sticker is being dragged, the cell shows only the sticker's outline.
@property (nonatomic, getter=isPeeled) BOOL peeled;
@end

@implementation STKPanelCell {
	UIImageView *_outlineView;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_outlineView = [[UIImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
		_outlineView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_outlineView.tintColor = UIColor.tertiaryLabelColor;
		_outlineView.alpha = 0;
		[self.contentView addSubview:_outlineView];
		_imageView = [[UIImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
		_imageView.contentMode = UIViewContentModeScaleAspectFit;
		_imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:_imageView];
	}
	return self;
}

- (void)prepareForReuse {
	[super prepareForReuse];
	self.peeled = NO;
}

- (void)setPeeled:(BOOL)peeled {
	_peeled = peeled;
	[_outlineView.layer removeAllAnimations];
	self.imageView.alpha = peeled ? 0 : 1;
	if (!peeled) {
		_outlineView.alpha = 0;
		_outlineView.image = nil;
		return;
	}
	_outlineView.image = STKStickerOutline(self.imageView.image, self.imageView.bounds.size);
	// Shows up as the sticker comes away.
	[UIView animateWithDuration:0.2 delay:0.05 options:0 animations:^{
		self->_outlineView.alpha = 1;
	} completion:nil];
}

- (void)setHighlighted:(BOOL)highlighted {
	[super setHighlighted:highlighted];
	[UIView animateWithDuration:0.12 animations:^{
		self.imageView.transform = highlighted ? CGAffineTransformMakeScale(0.9, 0.9) : CGAffineTransformIdentity;
	}];
}

@end

// The "+" tile that opens the sticker maker.
@interface STKAddCell : UICollectionViewCell
@end

@implementation STKAddCell

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		CAShapeLayer *border = [CAShapeLayer layer];
		border.fillColor = UIColor.clearColor.CGColor;
		border.lineWidth = 2;
		border.lineDashPattern = @[@6, @4];
		[self.contentView.layer addSublayer:border];
		UIImageView *plus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium]]];
		plus.tintColor = UIColor.secondaryLabelColor;
		plus.contentMode = UIViewContentModeCenter;
		plus.frame = self.contentView.bounds;
		plus.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:plus];
		self.accessibilityLabel = @"Make Sticker";
		self.isAccessibilityElement = YES;
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CAShapeLayer *border = (CAShapeLayer *)self.contentView.layer.sublayers.firstObject;
	border.frame = self.contentView.bounds;
	border.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.contentView.bounds, 8, 8) cornerRadius:14].CGPath;
	border.strokeColor = [UIColor.tertiaryLabelColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
}

- (void)setHighlighted:(BOOL)highlighted {
	[super setHighlighted:highlighted];
	self.contentView.alpha = highlighted ? 0.5 : 1;
}

@end

static UIViewController *STKTopViewController(void) {
	for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
		if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState != UISceneActivationStateForegroundActive) {
			continue;
		}
		for (UIWindow *window in ((UIWindowScene *)scene).windows) {
			if (!window.isKeyWindow) {
				continue;
			}
			UIViewController *controller = window.rootViewController;
			while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
				controller = controller.presentedViewController;
			}
			return controller;
		}
	}
	return nil;
}

typedef void (*STKPresentCreatorFunction)(UIViewController *, void (^)(BOOL));

static STKPresentCreatorFunction STKCreatorEntryPoint(void) {
	static STKPresentCreatorFunction present;
	if (!present) {
		const char *path = THEOS_PACKAGE_INSTALL_PREFIX "/Library/Application Support/Stickers/STKCreator.dylib";
#if TARGET_OS_SIMULATOR
		NSString *override = NSProcessInfo.processInfo.environment[@"STK_CREATOR_PATH"];
		path = override.length ? override.fileSystemRepresentation : path;
#endif
		void *handle = dlopen(path, RTLD_NOW);
		present = handle ? (STKPresentCreatorFunction)dlsym(handle, "STKPresentStickerCreator") : NULL;
		if (!present) {
			NSLog(@"[EmojiStickers] couldn't load the sticker maker: %s", dlerror());
		}
	}
	return present;
}

@interface STKStickerPanel () <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>
@end

@implementation STKStickerPanel {
	UICollectionView *_collectionView;
	UIView *_emptyView;
	NSArray<NSURL *> *_stickers;
	NSCache<NSURL *, UIImage *> *_thumbnails;
	NSOperationQueue *_loadQueue;
	NSMutableSet<NSURL *> *_loading;
	UIView *_toast;

	// Drag state.
	NSURL *_dragURL;
	UIImageView *_dragView;
	// In Messages: its native peeling sticker, in a container covering the window.
	CKBrowserDragStickerView *_peelView;
	UIView *_peelContainer;
	STKPanelCell *_dragSourceCell;
	CGPoint _dragTouchOffset;
	BOOL _dragOverBubble;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_thumbnails = [NSCache new];
		// The keyboard lives inside other apps, so keep animated thumbnails to a modest amount of memory.
		_thumbnails.totalCostLimit = 48 * 1024 * 1024;
		// Thumbnails load off the main thread: an uncached HEICS sticker takes most of a second to decode.
		_loadQueue = [NSOperationQueue new];
		_loadQueue.maxConcurrentOperationCount = 3;
		_loadQueue.qualityOfService = NSQualityOfServiceUserInitiated;
		_loading = [NSMutableSet set];

		UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
		layout.minimumInteritemSpacing = 4;
		layout.minimumLineSpacing = 4;
		layout.sectionInset = UIEdgeInsetsMake(8, 10, 8, 10);
		_collectionView = [[UICollectionView alloc] initWithFrame:self.bounds collectionViewLayout:layout];
		_collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		_collectionView.backgroundColor = UIColor.clearColor;
		_collectionView.dataSource = self;
		_collectionView.delegate = self;
		_collectionView.delaysContentTouches = NO;
		[_collectionView registerClass:STKPanelCell.class forCellWithReuseIdentifier:@"Sticker"];
		[_collectionView registerClass:STKAddCell.class forCellWithReuseIdentifier:@"Add"];
		[self addSubview:_collectionView];

		UILongPressGestureRecognizer *peel = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(peel:)];
		peel.minimumPressDuration = 0.25;
		peel.delegate = self;
		[_collectionView addGestureRecognizer:peel];

		UILabel *hint = [UILabel new];
		hint.text = @"Tap + to make a sticker from a photo, Live Photo or GIF";
		hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
		hint.textColor = UIColor.secondaryLabelColor;
		hint.numberOfLines = 0;
		hint.textAlignment = NSTextAlignmentCenter;
		hint.translatesAutoresizingMaskIntoConstraints = NO;
		_emptyView = hint;
		[self addSubview:hint];
		[NSLayoutConstraint activateConstraints:@[
			[hint.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:20],
			[hint.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:110],
			[hint.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
		]];
	}
	return self;
}

- (void)reload {
	_stickers = [STKStore.sharedStore stickerURLs];
	_emptyView.hidden = _stickers.count > 0;
	[_collectionView reloadData];
}

- (void)presentCreator {
	STKPresentCreatorFunction present = STKCreatorEntryPoint();
	UIViewController *presenter = STKTopViewController();
	if (!present || !presenter) {
		[self showToast:@"The sticker maker couldn't open here. Make one from Peel in the Messages app row."];
		return;
	}
	present(presenter, ^(BOOL saved) {
		if (saved) {
			[self reload];
		}
	});
}

// Item 0 is the "+" tile.
- (NSURL *)stickerAtIndexPath:(NSIndexPath *)indexPath {
	return indexPath.item > 0 && indexPath.item <= (NSInteger)_stickers.count ? _stickers[indexPath.item - 1] : nil;
}

#pragma mark - Collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
	return _stickers.count + 1;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
	NSURL *url = [self stickerAtIndexPath:indexPath];
	if (!url) {
		return [collectionView dequeueReusableCellWithReuseIdentifier:@"Add" forIndexPath:indexPath];
	}
	STKPanelCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Sticker" forIndexPath:indexPath];
	cell.url = url;
	cell.imageView.image = [_thumbnails objectForKey:url];
	if (!cell.imageView.image) {
		[self loadThumbnailForURL:url];
	}
	return cell;
}

- (void)loadThumbnailForURL:(NSURL *)url {
	if ([_loading containsObject:url]) {
		return;
	}
	[_loading addObject:url];
	[_loadQueue addOperationWithBlock:^{
		UIImage *image = STKLoadStickerImage(url, 240);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self->_loading removeObject:url];
			if (!image) {
				return;
			}
			[self->_thumbnails setObject:image forKey:url cost:STKImageCost(image)];
			for (STKPanelCell *cell in self->_collectionView.visibleCells) {
				if ([cell isKindOfClass:STKPanelCell.class] && [cell.url isEqual:url]) {
					cell.imageView.image = image;
				}
			}
		});
	}];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
	CGFloat available = collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right;
	NSInteger columns = MAX(4, (NSInteger)(available / 92));
	CGFloat side = floor((available - layout.minimumInteritemSpacing * (columns - 1)) / columns);
	return CGSizeMake(side, side);
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
	[collectionView deselectItemAtIndexPath:indexPath animated:NO];
	[UIDevice.currentDevice playInputClick];
	NSURL *url = [self stickerAtIndexPath:indexPath];
	if (url) {
		STKInsertSticker(url, ^(BOOL inserted) {
			if (!inserted) {
				[self showToast:@"Sticker copied. Touch and hold the text field and choose Paste."];
			}
		});
	} else {
		[self presentCreator];
	}
}

- (void)showToast:(NSString *)message {
	[_toast removeFromSuperview];
	UILabel *label = [UILabel new];
	label.text = message;
	label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	label.textColor = UIColor.labelColor;
	label.numberOfLines = 0;
	label.textAlignment = NSTextAlignmentCenter;
	label.translatesAutoresizingMaskIntoConstraints = NO;
	UIView *toast = [UIView new];
	toast.backgroundColor = UIColor.secondarySystemBackgroundColor;
	toast.layer.cornerRadius = 12;
	toast.layer.shadowColor = UIColor.blackColor.CGColor;
	toast.layer.shadowOpacity = 0.15;
	toast.layer.shadowRadius = 6;
	toast.layer.shadowOffset = CGSizeMake(0, 2);
	toast.userInteractionEnabled = NO;
	toast.translatesAutoresizingMaskIntoConstraints = NO;
	[toast addSubview:label];
	[self addSubview:toast];
	[NSLayoutConstraint activateConstraints:@[
		[label.topAnchor constraintEqualToAnchor:toast.topAnchor constant:10],
		[label.bottomAnchor constraintEqualToAnchor:toast.bottomAnchor constant:-10],
		[label.leadingAnchor constraintEqualToAnchor:toast.leadingAnchor constant:14],
		[label.trailingAnchor constraintEqualToAnchor:toast.trailingAnchor constant:-14],
		[toast.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
		[toast.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
		[toast.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-12],
	]];
	_toast = toast;
	toast.alpha = 0;
	[UIView animateWithDuration:0.2 animations:^{
		toast.alpha = 1;
	} completion:^(BOOL finished) {
		[UIView animateWithDuration:0.3 delay:3 options:0 animations:^{
			toast.alpha = 0;
		} completion:^(BOOL done) {
			[toast removeFromSuperview];
		}];
	}];
}

#pragma mark - Peel and drag

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
	return NO;
}

- (void)peel:(UILongPressGestureRecognizer *)gesture {
	UIWindow *window = self.window;
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan: {
			NSIndexPath *indexPath = [_collectionView indexPathForItemAtPoint:[gesture locationInView:_collectionView]];
			NSURL *url = indexPath ? [self stickerAtIndexPath:indexPath] : nil;
			STKPanelCell *cell = url ? (STKPanelCell *)[_collectionView cellForItemAtIndexPath:indexPath] : nil;
			if (!cell || !window) {
				gesture.enabled = NO;
				gesture.enabled = YES;
				return;
			}
			[self beginDragFromCell:cell url:url touch:[gesture locationInView:window]];
			break;
		}
		case UIGestureRecognizerStateChanged:
			[self moveDragTo:[gesture locationInView:window]];
			break;
		case UIGestureRecognizerStateEnded:
			[self endDragAt:[gesture locationInView:window] cancelled:NO];
			break;
		case UIGestureRecognizerStateCancelled:
		case UIGestureRecognizerStateFailed:
			[self endDragAt:[gesture locationInView:window] cancelled:YES];
			break;
		default:
			break;
	}
}

- (void)beginDragFromCell:(STKPanelCell *)cell url:(NSURL *)url touch:(CGPoint)touch {
	UIWindow *window = self.window;
	_dragURL = url;
	_dragSourceCell = cell;
	_dragOverBubble = NO;
	// Lift the sticker above the finger so it isn't hidden underneath it.
	_dragTouchOffset = CGPointMake(0, -kDragStickerSide * 0.45);
	if ([STKMessagesBridge isAvailable] && STKNativePeelAvailable() && [self beginNativePeelFromCell:cell touch:touch]) {
		return;
	}

	CGRect start = [cell.imageView convertRect:cell.imageView.bounds toView:window];
	// Peel off the thumbnail already on screen right away; loading a larger copy can take a while.
	_dragView = [[UIImageView alloc] initWithImage:cell.imageView.image];
	UIImageView *dragView = _dragView;
	if (cell.imageView.image.images.count <= 1) {
		// Sharpen stills once loaded. Animations keep the thumbnail, since swapping would restart them mid-drag.
		[_loadQueue addOperationWithBlock:^{
			UIImage *sharp = STKLoadStickerImage(url, kDragStickerSide * 3);
			dispatch_async(dispatch_get_main_queue(), ^{
				if (sharp && self->_dragView == dragView) {
					dragView.image = sharp;
				}
			});
		}];
	}
	_dragView.contentMode = UIViewContentModeScaleAspectFit;
	_dragView.bounds = CGRectMake(0, 0, kDragStickerSide, kDragStickerSide);
	_dragView.center = CGPointMake(CGRectGetMidX(start), CGRectGetMidY(start));
	_dragView.transform = CGAffineTransformMakeScale(start.size.width / kDragStickerSide, start.size.height / kDragStickerSide);
	_dragView.layer.shadowColor = UIColor.blackColor.CGColor;
	_dragView.layer.shadowOpacity = 0;
	_dragView.layer.shadowRadius = 8;
	_dragView.layer.shadowOffset = CGSizeMake(0, 6);
	_dragView.userInteractionEnabled = NO;
	[window addSubview:_dragView];
	cell.peeled = YES;

	CGPoint lifted = CGPointMake(touch.x + _dragTouchOffset.x, touch.y + _dragTouchOffset.y);
	[[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	[UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
		self->_dragView.center = lifted;
		self->_dragView.transform = CGAffineTransformMakeRotation(-0.06);
	} completion:nil];
	CABasicAnimation *shadow = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
	shadow.fromValue = @0;
	shadow.toValue = @0.3;
	shadow.duration = 0.2;
	_dragView.layer.shadowOpacity = 0.3;
	[_dragView.layer addAnimation:shadow forKey:@"lift"];
}

// Peels the sticker off the grid the way Messages' sticker drawer does. NO if the drag view couldn't be made.
- (BOOL)beginNativePeelFromCell:(STKPanelCell *)cell touch:(CGPoint)touch {
	UIWindow *window = self.window;
	UIImage *image = cell.imageView.image;
	NSArray<UIImage *> *thumbnails = image.images.count > 1 ? image.images : (image ? @[image] : nil);
	if (!thumbnails) {
		return NO;
	}
	// The drag view shows its image at the image's point size, so redraw the frames at the size to drag.
	CGSize side = STKAspectFitRect(image.size, CGRectMake(0, 0, kDragStickerSide, kDragStickerSide)).size;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:side format:[UIGraphicsImageRendererFormat formatForTraitCollection:self.traitCollection]];
	NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:thumbnails.count];
	for (UIImage *thumbnail in thumbnails) {
		[frames addObject:[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
			[thumbnail drawInRect:CGRectMake(0, 0, side.width, side.height)];
		}]];
	}
	NSNumber *duration = @(image.images.count > 1 ? image.duration / image.images.count : 0.1);
	NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:frames.count];
	for (NSUInteger i = 0; i < frames.count; i++) {
		[durations addObject:duration];
	}
	CKAnimatedImage *dragImage = [[NSClassFromString(@"CKAnimatedImage") alloc] initWithImages:frames durations:durations];
	CGRect start = [cell.imageView convertRect:STKAspectFitRect(image.size, cell.imageView.bounds) toView:window];
	CKBrowserDragStickerView *peelView = dragImage ? [[NSClassFromString(@"CKBrowserDragStickerView") alloc] initWithSourceRect:start dragImage:dragImage] : nil;
	if (!peelView) {
		return NO;
	}
	_peelContainer = [[UIView alloc] initWithFrame:window.bounds];
	_peelContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_peelContainer.userInteractionEnabled = NO;
	[window addSubview:_peelContainer];
	_peelView = peelView;
	[peelView setCanPeel:YES];
	[peelView setPressed:YES];
	[_peelContainer addSubview:peelView];
	cell.peeled = YES;

	CGPoint lifted = CGPointMake(touch.x + _dragTouchOffset.x, touch.y + _dragTouchOffset.y);
	[[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleLight] impactOccurred];
	[peelView animatePeelWithCompletion:nil];
	[peelView setInitialDragStartPosition:lifted];
	[peelView attachElasticEffectsForLocation:lifted];
	[peelView updateAnimationTimerObserving];
	return YES;
}

- (CGPoint)screenPointForWindowPoint:(CGPoint)point {
	UIWindow *window = self.window;
	return [window convertPoint:point toCoordinateSpace:window.screen.coordinateSpace];
}

- (void)moveDragTo:(CGPoint)touch {
	if (_peelView) {
		[_peelView updateElasticEffectsForLocation:CGPointMake(touch.x + _dragTouchOffset.x, touch.y + _dragTouchOffset.y)];
		BOOL overBubble = [STKMessagesBridge canPlaceStickerAtScreenPoint:[self screenPointForWindowPoint:[_peelView dragViewCenter]]];
		if (overBubble && !_dragOverBubble) {
			[[UISelectionFeedbackGenerator new] selectionChanged];
		}
		_dragOverBubble = overBubble;
		return;
	}
	if (!_dragView) {
		return;
	}
	_dragView.center = CGPointMake(touch.x + _dragTouchOffset.x, touch.y + _dragTouchOffset.y);
	BOOL overBubble = [STKMessagesBridge canPlaceStickerAtScreenPoint:[self screenPointForWindowPoint:_dragView.center]];
	if (overBubble != _dragOverBubble) {
		_dragOverBubble = overBubble;
		if (overBubble) {
			[[UISelectionFeedbackGenerator new] selectionChanged];
		}
		[UIView animateWithDuration:0.15 animations:^{
			CGFloat scale = overBubble ? 1.08 : 1;
			self->_dragView.transform = CGAffineTransformScale(CGAffineTransformMakeRotation(-0.06), scale, scale);
		}];
	}
}

- (void)endNativePeelAt:(CGPoint)touch cancelled:(BOOL)cancelled {
	CKBrowserDragStickerView *peelView = _peelView;
	UIView *container = _peelContainer;
	_peelView = nil;
	_peelContainer = nil;
	[peelView detachElasticEffects];
	CGPoint center = [peelView dragViewCenter];
	BOOL overKeyboard = CGRectContainsPoint([[self keyboardHostView] convertRect:[self keyboardHostView].bounds toView:self.window], center);
	// Stick it down at the size it was shown while dragging.
	CGSize size = [peelView initialSize];
	if ([peelView respondsToSelector:@selector(initialScale)] && [peelView respondsToSelector:@selector(dragViewScale)]) {
		CGFloat scale = [peelView initialScale] * [peelView dragViewScale];
		size = CGSizeMake(size.width * scale, size.height * scale);
	}
	BOOL placed = !cancelled && !overKeyboard && [STKMessagesBridge placeStickerAtURL:_dragURL screenPoint:[self screenPointForWindowPoint:center] size:size rotation:0];
	STKPanelCell *source = _dragSourceCell;
	if (placed) {
		[[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
		source.peeled = NO;
	}
	// Sticks it down where it was dropped, or settles it back into the grid.
	UIView *sourceImage = source.imageView;
	CGPoint home = source.window ? [sourceImage convertPoint:CGPointMake(CGRectGetMidX(sourceImage.bounds), CGRectGetMidY(sourceImage.bounds)) toView:container] : center;
	[peelView reversePeelAnimationToPoint:placed ? center : home forPlacement:placed shouldShrink:NO completionBlock:^{
		source.peeled = NO;
		[container removeFromSuperview];
	}];
}

// The view holding the whole keyboard; dropping back onto it always cancels.
- (UIView *)keyboardHostView {
	UIView *keyboard = self;
	while (keyboard.superview && ![NSStringFromClass(keyboard.class) isEqualToString:@"UIInputSetHostView"]) {
		keyboard = keyboard.superview;
	}
	return keyboard;
}

- (void)endDragAt:(CGPoint)touch cancelled:(BOOL)cancelled {
	if (_peelView) {
		[self endNativePeelAt:touch cancelled:cancelled];
		return;
	}
	UIImageView *dragView = _dragView;
	if (!dragView) {
		return;
	}
	_dragView = nil;
	CGPoint center = dragView.center;
	CGPoint screenPoint = [self screenPointForWindowPoint:center];
	UIView *keyboard = [self keyboardHostView];
	BOOL overKeyboard = CGRectContainsPoint([keyboard convertRect:keyboard.bounds toView:self.window], center);

	BOOL placed = NO;
	if (!cancelled && !overKeyboard) {
		if ([STKMessagesBridge isAvailable]) {
			placed = [STKMessagesBridge placeStickerAtURL:_dragURL screenPoint:screenPoint size:CGSizeMake(kDragStickerSide, kDragStickerSide) rotation:0];
		} else {
			placed = YES;
			STKInsertSticker(_dragURL, ^(BOOL inserted) {
				if (!inserted) {
					[self showToast:@"Sticker copied. Touch and hold the text field and choose Paste."];
				}
			});
		}
	}

	STKPanelCell *source = _dragSourceCell;
	if (placed) {
		[[UIImpactFeedbackGenerator.alloc initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
		source.peeled = NO;
		[UIView animateWithDuration:0.2 animations:^{
			dragView.transform = CGAffineTransformMakeScale(0.9, 0.9);
			dragView.alpha = 0;
		} completion:^(BOOL finished) {
			[dragView removeFromSuperview];
		}];
		return;
	}
	// Fly back into the grid.
	CGRect home = source.window ? [source.imageView convertRect:source.imageView.bounds toView:dragView.superview] : CGRectZero;
	[UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
		if (!CGRectIsEmpty(home)) {
			dragView.center = CGPointMake(CGRectGetMidX(home), CGRectGetMidY(home));
			dragView.transform = CGAffineTransformMakeScale(home.size.width / kDragStickerSide, home.size.height / kDragStickerSide);
		} else {
			dragView.alpha = 0;
		}
		dragView.layer.shadowOpacity = 0;
	} completion:^(BOOL finished) {
		source.peeled = NO;
		[dragView removeFromSuperview];
	}];
}

@end
