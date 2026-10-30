#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "STKStickerPanel.h"
#import "STKMessagesBridge.h"

// Adds a Stickers section to the system emoji keyboard (iOS 16, iPhone and iPad layouts): a sticker button in front
// of the category bar swaps the emoji grid for the sticker grid; tapping any emoji category swaps it back.

@interface UIKeyboardEmojiCollectionInputView : UIView
@end

@interface UIKeyboardEmojiCategoryBar : UIView
@property (nonatomic, strong) UIView *scrubView;
// From UIKBKeyView: the key in the keyboard layout and where its contents are drawn in the keyplane. The category
// icons are spaced across the key's frame, while the selection circle and taps use the view's bounds.
@property (nonatomic, readonly) id key;
@property (nonatomic) CGRect drawFrame;
- (void)resetRenderedKeyState;
- (void)prepareForDisplay;
// The keyboard layout, which plays the haptic when a category is tapped.
- (id)hitTestResponder;
@end

@interface UIKeyboardLayoutStar : UIView
- (void)prepareSliderBehaviorFeedback;
- (void)provideSliderBehaviorFeedback;
- (void)finishSliderBehaviorFeedback;
@end

// The button takes a category's slot in front of the bar and gets the same selection circle. The iPad bar's
// categories are spaced wider apart, with a bigger circle.
typedef struct {
	CGFloat width, circle;
} STKButtonMetrics;

static STKButtonMetrics STKMetricsForBar(UIView *bar) {
	Class iPadBar = NSClassFromString(@"UIKeyboardEmojiCategoryBar_iPad");
	return iPadBar && [bar isKindOfClass:iPadBar] ? (STKButtonMetrics){50, 42} : (STKButtonMetrics){36, 30};
}
static const void *kPanelKey = &kPanelKey;
static const void *kButtonKey = &kButtonKey;
static const void *kAdjustedFrameKey = &kAdjustedFrameKey;

static UIKeyboardEmojiCollectionInputView *STKInputViewNear(UIView *view) {
	Class inputClass = NSClassFromString(@"UIKeyboardEmojiCollectionInputView");
	for (UIView *sibling in view.superview.subviews) {
		if ([sibling isKindOfClass:inputClass]) {
			return (UIKeyboardEmojiCollectionInputView *)sibling;
		}
	}
	return nil;
}

static UIKeyboardEmojiCategoryBar *STKCategoryBarNear(UIView *view) {
	// UIKeyboardEmojiCategoryBar_iPhone above the iPhone keyboard's bottom row, _iPad in the iPad keyboard's bottom row.
	Class barClass = NSClassFromString(@"UIKeyboardEmojiCategoryBar");
	for (UIView *sibling in view.superview.subviews) {
		if ([sibling isKindOfClass:barClass]) {
			return (UIKeyboardEmojiCategoryBar *)sibling;
		}
	}
	return nil;
}

static UIView *STKEmojiGrid(UIKeyboardEmojiCollectionInputView *inputView) {
	Class gridClass = NSClassFromString(@"UIKeyboardEmojiCollectionView");
	for (UIView *subview in inputView.subviews) {
		if ([subview isKindOfClass:gridClass]) {
			return subview;
		}
	}
	return nil;
}

static STKStickerPanel *STKPanel(UIKeyboardEmojiCollectionInputView *inputView) {
	return objc_getAssociatedObject(inputView, kPanelKey);
}

static void STKSetShowingStickers(UIKeyboardEmojiCollectionInputView *inputView, BOOL showing) {
	STKStickerPanel *panel = STKPanel(inputView);
	if (!panel || panel.hidden == !showing) {
		return;
	}
	if (showing) {
		[panel reload];
	}
	panel.hidden = !showing;
	STKEmojiGrid(inputView).hidden = showing;

	UIKeyboardEmojiCategoryBar *bar = STKCategoryBarNear(inputView);
	UIButton *button = objc_getAssociatedObject(bar, kButtonKey);
	button.selected = showing;
	if ([bar respondsToSelector:@selector(scrubView)]) {
		bar.scrubView.hidden = showing;
	}
}

@interface STKStickerButton : UIButton
@property (nonatomic, weak) UIView *categoryBar;
@end

@implementation STKStickerButton {
	UIView *_selectionCircle;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_selectionCircle = [UIView new];
		_selectionCircle.userInteractionEnabled = NO;
		_selectionCircle.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
			return traits.userInterfaceStyle == UIUserInterfaceStyleDark ? [UIColor colorWithWhite:1 alpha:0.18] : [UIColor colorWithWhite:0 alpha:0.1];
		}];
		_selectionCircle.hidden = YES;
		[self addSubview:_selectionCircle];
		[self setImage:STKStickerGlyph(22) forState:UIControlStateNormal];
		self.tintColor = UIColor.secondaryLabelColor;
		self.accessibilityLabel = @"Stickers";
		[self addTarget:self action:@selector(prepareFeedback) forControlEvents:UIControlEventTouchDown];
		[self addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
		[self addTarget:self action:@selector(finishFeedback) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	CGFloat side = MIN(STKMetricsForBar(self.categoryBar).circle, MIN(self.bounds.size.width, self.bounds.size.height));
	_selectionCircle.frame = CGRectMake((self.bounds.size.width - side) / 2, (self.bounds.size.height - side) / 2, side, side);
	_selectionCircle.layer.cornerRadius = side / 2;
	[self sendSubviewToBack:_selectionCircle];
}

- (void)setSelected:(BOOL)selected {
	[super setSelected:selected];
	_selectionCircle.hidden = !selected;
	self.tintColor = selected ? UIColor.labelColor : UIColor.secondaryLabelColor;
}

// The same haptic the category bar plays: it prepares on touch down, then ticks and finishes on touch up.
- (UIKeyboardLayoutStar *)feedbackLayout {
	UIKeyboardEmojiCategoryBar *bar = (UIKeyboardEmojiCategoryBar *)self.categoryBar;
	if (![bar respondsToSelector:@selector(hitTestResponder)]) {
		return nil;
	}
	UIKeyboardLayoutStar *layout = bar.hitTestResponder;
	return [layout respondsToSelector:@selector(prepareSliderBehaviorFeedback)] && [layout respondsToSelector:@selector(provideSliderBehaviorFeedback)] && [layout respondsToSelector:@selector(finishSliderBehaviorFeedback)] ? layout : nil;
}

- (void)prepareFeedback {
	[self.feedbackLayout prepareSliderBehaviorFeedback];
}

- (void)finishFeedback {
	[self.feedbackLayout finishSliderBehaviorFeedback];
}

- (void)toggle {
	UIKeyboardEmojiCollectionInputView *inputView = STKInputViewNear(self.categoryBar);
	[UIDevice.currentDevice playInputClick];
	UIKeyboardLayoutStar *layout = self.feedbackLayout;
	if (layout) {
		[layout provideSliderBehaviorFeedback];
		[layout finishSliderBehaviorFeedback];
	} else {
		[[UISelectionFeedbackGenerator new] selectionChanged];
	}
	STKSetShowingStickers(inputView, !self.selected);
}

@end

static void STKLayoutButton(UIKeyboardEmojiCategoryBar *bar) {
	if (!bar.superview) {
		return;
	}
	STKStickerButton *button = objc_getAssociatedObject(bar, kButtonKey);
	if (!button) {
		button = [STKStickerButton buttonWithType:UIButtonTypeCustom];
		button.categoryBar = bar;
		objc_setAssociatedObject(bar, kButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	if (button.superview != bar.superview) {
		[bar.superview addSubview:button];
	}
	CGRect frame = bar.frame;
	CGFloat width = STKMetricsForBar(bar).width;
	button.frame = CGRectMake(frame.origin.x - width, frame.origin.y, width, frame.size.height);
}

@interface UIKBTree : NSObject
@property (nonatomic) CGRect frame;
// What the renderer spaces the category icons across (its width over the number of categories).
@property (nonatomic) CGRect paddedFrame;
@end

// Narrows the bar's key in the layout to match the view, so the icons are drawn across the narrowed bar and line up
// with the selection circle and taps (instead of the last category being pushed off the end). Returns whether
// anything changed.
static BOOL STKSyncKeyGeometry(UIKeyboardEmojiCategoryBar *bar) {
	if (![bar respondsToSelector:@selector(key)] || ![bar respondsToSelector:@selector(setDrawFrame:)]) {
		return NO;
	}
	UIKBTree *key = bar.key;
	if (![key respondsToSelector:@selector(setFrame:)]) {
		return NO;
	}
	BOOL changed = NO;
	CGRect frame = bar.frame;
	if (!CGRectEqualToRect(key.frame, frame)) {
		if ([key respondsToSelector:@selector(paddedFrame)] && [key respondsToSelector:@selector(setPaddedFrame:)]) {
			// Moves and narrows the padded frame as much as the frame.
			CGRect old = key.frame, padded = key.paddedFrame;
			CGFloat left = CGRectGetMinX(frame) - CGRectGetMinX(old), right = CGRectGetMaxX(frame) - CGRectGetMaxX(old);
			key.paddedFrame = CGRectMake(padded.origin.x + left, padded.origin.y, padded.size.width - left + right, padded.size.height);
		}
		key.frame = frame;
		// The keyplane may hand the same key to a new bar view; this keeps that from being narrowed twice.
		objc_setAssociatedObject(key, kAdjustedFrameKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		changed = YES;
	}
	if (!CGRectEqualToRect(bar.drawFrame, frame)) {
		bar.drawFrame = frame;
		changed = YES;
	}
	return changed;
}

// Hooked on the shared superclass: neither the iPhone nor the iPad subclass overrides these.
%hook UIKeyboardEmojiCategoryBar

- (void)prepareForDisplay {
	if (objc_getAssociatedObject(self, kAdjustedFrameKey)) {
		STKSyncKeyGeometry(self);
	}
	%orig;
}

// Make room for the sticker button in front of the category icons.
- (void)setFrame:(CGRect)frame {
	NSValue *adjusted = objc_getAssociatedObject(self, kAdjustedFrameKey);
	if (!adjusted && [self respondsToSelector:@selector(key)]) {
		adjusted = objc_getAssociatedObject(self.key, kAdjustedFrameKey);
	}
	CGFloat width = STKMetricsForBar(self).width;
	if (!(adjusted && CGRectEqualToRect(adjusted.CGRectValue, frame)) && frame.size.width > width * 4) {
		frame.origin.x += width;
		frame.size.width -= width;
		objc_setAssociatedObject(self, kAdjustedFrameKey, [NSValue valueWithCGRect:frame], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	}
	%orig(frame);
	if (objc_getAssociatedObject(self, kAdjustedFrameKey) && STKSyncKeyGeometry(self) && [self respondsToSelector:@selector(resetRenderedKeyState)]) {
		[self resetRenderedKeyState];
		[self prepareForDisplay];
	}
	STKLayoutButton(self);
}

- (void)didMoveToSuperview {
	%orig;
	STKLayoutButton(self);
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
	%orig;
	STKSetShowingStickers(STKInputViewNear(self), NO);
}

%end

%hook UIKeyboardEmojiCollectionInputView

- (void)layoutSubviews {
	%orig;
	if (!STKCategoryBarNear(self)) {
		// A layout without a category bar has nowhere to host the button.
		static dispatch_once_t once;
		dispatch_once(&once, ^{
			NSLog(@"[EmojiStickers] no category bar next to %@; siblings %@", self, [self.superview.subviews valueForKey:@"class"]);
		});
		return;
	}
	STKStickerPanel *panel = STKPanel(self);
	if (!panel) {
		panel = [[STKStickerPanel alloc] initWithFrame:self.bounds];
		panel.hidden = YES;
		objc_setAssociatedObject(self, kPanelKey, panel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		[self addSubview:panel];
	}
	panel.frame = self.bounds;
	[self bringSubviewToFront:panel];
}

- (void)didMoveToWindow {
	%orig;
	if (!self.window) {
		STKSetShowingStickers(self, NO);
	}
}

- (void)emojiSearchTextFieldWillBecomeActive:(id)field {
	STKSetShowingStickers(self, NO);
	%orig;
}

%end

// Messages' sticker drag view, which its drawer and our panel both peel stickers into.
@interface CKBrowserDragStickerView : UIView
- (void)applyTransforms;
@end

%group Messages

%hook CKBrowserDragStickerView

// Dragging a sticker, a second finger grows it, but this setter clamps it to 1...2x. Same clamp, up to STKMaxDragScale.
- (void)setDragViewScale:(double)scale {
	Ivar ivar = class_getInstanceVariable(object_getClass(self), "_dragViewScale");
	if (!ivar || strcmp(ivar_getTypeEncoding(ivar), @encode(double)) != 0 || ![self respondsToSelector:@selector(applyTransforms)]) {
		%orig;
		return;
	}
	scale = MIN(MAX(scale, 1), STKMaxDragScale);
	double *storage = (double *)((uint8_t *)(__bridge void *)self + ivar_getOffset(ivar));
	if (*storage != scale) {
		*storage = scale;
		[self applyTransforms];
	}
}

%end

%end

%ctor {
	%init;
	if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MobileSMS"] && objc_getClass("CKBrowserDragStickerView")) {
		%init(Messages);
	}
}
