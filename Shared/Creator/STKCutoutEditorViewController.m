#import "STKCutoutEditorViewController.h"
#import "STKPreviewViewController.h"
#import "STKStickerFactory.h"
#import <AVFoundation/AVFoundation.h>

static const CGFloat kPreviewMaxSide = 1200;

typedef NS_ENUM(NSInteger, STKBrushMode) {
	STKBrushModeErase,
	STKBrushModeRestore,
};

// Segment order of the tool picker, matching STKStrokeKind.
static NSString *const kToolTitles[] = {@"Brush", @"Lasso", @"Smart Lasso"};

// Editing redraws the whole image for every touch, so work on a screen-sized copy.
static UIImage *STKPreviewImage(UIImage *image) {
	CGSize size = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
	CGFloat factor = MIN(1.0, kPreviewMaxSide / MAX(size.width, size.height));
	if (factor >= 1 && image.scale == 1 && image.imageOrientation == UIImageOrientationUp) {
		return image;
	}
	size = CGSizeMake(MAX(1, round(size.width * factor)), MAX(1, round(size.height * factor)));
	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
	format.scale = 1;
	format.opaque = NO;
	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
	}];
}

@interface STKCutoutEditorViewController () <UIScrollViewDelegate>
@end

@implementation STKCutoutEditorViewController {
	UIImage *_basePreview;
	UIImage *_originalPreview;
	UIImage *_committed;
	CGRect _crop;
	NSMutableArray<STKBrushStroke *> *_strokes;
	STKBrushStroke *_current;
	NSMutableArray<NSValue *> *_currentPoints;
	UIBezierPath *_lassoPath;

	UIScrollView *_scrollView;
	UIView *_contentView;
	UIImageView *_ghostView;
	UIImageView *_resultView;
	CAShapeLayer *_brushLayer;
	CAShapeLayer *_lassoLayer;
	UIActivityIndicatorView *_findingSpinner;
	UILabel *_toastLabel;
	UISegmentedControl *_modeControl;
	UISegmentedControl *_toolControl;
	UISlider *_sizeSlider;
	UIButton *_undoButton;
	UIButton *_resetButton;
	UILabel *_hintLabel;
	CGSize _laidOutSize;
}

- (instancetype)initWithImage:(UIImage *)image original:(UIImage *)original crop:(CGRect)crop strokes:(NSArray<STKBrushStroke *> *)strokes {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_basePreview = STKPreviewImage(image);
		_originalPreview = STKPreviewImage(original);
		_crop = crop;
		_strokes = [strokes mutableCopy];
		_committed = [STKStickerFactory applyStrokes:_strokes toImage:_basePreview original:_originalPreview crop:_crop];
		self.title = @"Erase & Restore";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
	self.navigationItem.hidesBackButton = YES;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

	UIView *canvas = [UIView new];
	canvas.backgroundColor = [UIColor colorWithPatternImage:STKCheckerboardPattern()];
	canvas.layer.cornerRadius = 16;
	canvas.clipsToBounds = YES;
	canvas.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:canvas];

	_scrollView = [UIScrollView new];
	_scrollView.delegate = self;
	_scrollView.minimumZoomScale = 1;
	_scrollView.maximumZoomScale = 8;
	_scrollView.showsHorizontalScrollIndicator = NO;
	_scrollView.showsVerticalScrollIndicator = NO;
	_scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
	// One finger paints; two fingers pan and zoom.
	_scrollView.panGestureRecognizer.minimumNumberOfTouches = 2;
	_scrollView.frame = canvas.bounds;
	_scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	[canvas addSubview:_scrollView];

	_contentView = [UIView new];
	[_scrollView addSubview:_contentView];
	_ghostView = [[UIImageView alloc] initWithImage:_originalPreview];
	_ghostView.alpha = 0;
	_resultView = [[UIImageView alloc] initWithImage:_committed];
	for (UIImageView *view in @[_ghostView, _resultView]) {
		view.contentMode = UIViewContentModeScaleToFill;
		[_contentView addSubview:view];
	}
	_brushLayer = [CAShapeLayer layer];
	_brushLayer.fillColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
	_brushLayer.strokeColor = UIColor.whiteColor.CGColor;
	_brushLayer.shadowColor = UIColor.blackColor.CGColor;
	_brushLayer.shadowOpacity = 0.6;
	_brushLayer.shadowRadius = 1;
	_brushLayer.shadowOffset = CGSizeZero;
	_brushLayer.hidden = YES;
	[_contentView.layer addSublayer:_brushLayer];
	_lassoLayer = [CAShapeLayer layer];
	_lassoLayer.fillColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
	_lassoLayer.strokeColor = UIColor.whiteColor.CGColor;
	_lassoLayer.lineDashPattern = @[@6, @4];
	_lassoLayer.lineJoin = kCALineJoinRound;
	_lassoLayer.shadowColor = UIColor.blackColor.CGColor;
	_lassoLayer.shadowOpacity = 0.8;
	_lassoLayer.shadowRadius = 1;
	_lassoLayer.shadowOffset = CGSizeZero;
	_lassoLayer.hidden = YES;
	// Marching ants.
	CABasicAnimation *march = [CABasicAnimation animationWithKeyPath:@"lineDashPhase"];
	march.fromValue = @0;
	march.toValue = @10;
	march.duration = 0.5;
	march.repeatCount = HUGE_VALF;
	march.removedOnCompletion = NO;
	[_lassoLayer addAnimation:march forKey:@"march"];
	[_contentView.layer addSublayer:_lassoLayer];

	_findingSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	_findingSpinner.color = UIColor.whiteColor;
	_findingSpinner.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
	_findingSpinner.layer.cornerRadius = 12;
	_findingSpinner.hidesWhenStopped = YES;
	_findingSpinner.translatesAutoresizingMaskIntoConstraints = NO;
	[canvas addSubview:_findingSpinner];

	_toastLabel = [UILabel new];
	_toastLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	_toastLabel.textColor = UIColor.whiteColor;
	_toastLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
	_toastLabel.textAlignment = NSTextAlignmentCenter;
	_toastLabel.numberOfLines = 0;
	_toastLabel.layer.cornerRadius = 10;
	_toastLabel.clipsToBounds = YES;
	_toastLabel.alpha = 0;
	_toastLabel.translatesAutoresizingMaskIntoConstraints = NO;
	[canvas addSubview:_toastLabel];

	UIPanGestureRecognizer *paint = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(paint:)];
	paint.maximumNumberOfTouches = 1;
	[_contentView addGestureRecognizer:paint];
	[_contentView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dab:)]];

	_modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Erase", @"Restore"]];
	_modeControl.selectedSegmentIndex = STKBrushModeErase;
	[_modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];

	_toolControl = [[UISegmentedControl alloc] initWithItems:@[kToolTitles[0], kToolTitles[1], kToolTitles[2]]];
	_toolControl.selectedSegmentIndex = STKStrokeKindBrush;
	[_toolControl setEnabled:STKStickerFactory.isSubjectLiftingSupported forSegmentAtIndex:STKStrokeKindSmartLasso];
	[_toolControl addTarget:self action:@selector(toolChanged) forControlEvents:UIControlEventValueChanged];

	_sizeSlider = [UISlider new];
	_sizeSlider.minimumValue = 8;
	_sizeSlider.maximumValue = 80;
	_sizeSlider.value = 28;
	_sizeSlider.minimumValueImage = [UIImage systemImageNamed:@"circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:6]];
	_sizeSlider.maximumValueImage = [UIImage systemImageNamed:@"circle.fill" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20]];
	_sizeSlider.tintColor = UIColor.systemBlueColor;
	_sizeSlider.accessibilityLabel = @"Brush Size";

	_undoButton = [UIButton buttonWithConfiguration:[UIButtonConfiguration grayButtonConfiguration] primaryAction:[UIAction actionWithTitle:@"Undo" image:[UIImage systemImageNamed:@"arrow.uturn.backward"] identifier:nil handler:^(UIAction *action) {
		[self undo];
	}]];
	_resetButton = [UIButton buttonWithConfiguration:[UIButtonConfiguration grayButtonConfiguration] primaryAction:[UIAction actionWithTitle:@"Start Over" image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(UIAction *action) {
		[self startOver];
	}]];
	UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_undoButton, _resetButton]];
	buttons.distribution = UIStackViewDistributionFillEqually;
	buttons.spacing = 12;

	_hintLabel = [UILabel new];
	_hintLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	_hintLabel.textColor = UIColor.secondaryLabelColor;
	_hintLabel.numberOfLines = 0;
	_hintLabel.textAlignment = NSTextAlignmentCenter;

	UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[_toolControl, _modeControl, _sizeSlider, buttons, _hintLabel]];
	controls.axis = UILayoutConstraintAxisVertical;
	controls.spacing = 14;
	controls.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:controls];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[canvas.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
		[canvas.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
		[canvas.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
		[canvas.bottomAnchor constraintEqualToAnchor:controls.topAnchor constant:-20],
		[controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
		[controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
		[controls.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
		// Room for the longest hint, so switching tools doesn't resize the canvas.
		[_hintLabel.heightAnchor constraintGreaterThanOrEqualToConstant:ceil(_hintLabel.font.lineHeight * 3)],
		[_findingSpinner.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
		[_findingSpinner.centerYAnchor constraintEqualToAnchor:canvas.centerYAnchor],
		[_findingSpinner.widthAnchor constraintEqualToConstant:72],
		[_findingSpinner.heightAnchor constraintEqualToConstant:72],
		[_toastLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:canvas.leadingAnchor constant:16],
		[_toastLabel.trailingAnchor constraintLessThanOrEqualToAnchor:canvas.trailingAnchor constant:-16],
		[_toastLabel.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
		[_toastLabel.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor constant:-16],
	]];
	[self toolChanged];
	[self updateButtons];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	CGSize bounds = _scrollView.bounds.size;
	if (CGSizeEqualToSize(bounds, _laidOutSize) || bounds.width <= 0 || bounds.height <= 0) {
		return;
	}
	_laidOutSize = bounds;
	_scrollView.zoomScale = 1;
	CGRect fitted = AVMakeRectWithAspectRatioInsideRect(_basePreview.size, CGRectMake(0, 0, bounds.width - 24, bounds.height - 24));
	_contentView.frame = CGRectMake(0, 0, round(fitted.size.width), round(fitted.size.height));
	_ghostView.frame = _contentView.bounds;
	_resultView.frame = _contentView.bounds;
	_scrollView.contentSize = _contentView.frame.size;
	[self centerContent];
}

- (void)centerContent {
	CGSize bounds = _scrollView.bounds.size, content = _scrollView.contentSize;
	CGFloat x = MAX(0, (bounds.width - content.width) / 2), y = MAX(0, (bounds.height - content.height) / 2);
	_scrollView.contentInset = UIEdgeInsetsMake(y, x, y, x);
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
	return _contentView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
	[self centerContent];
}

#pragma mark - Painting

// Brush diameter in the content view's (unzoomed) points, so it stays the same size on screen at any zoom.
- (CGFloat)brushDiameter {
	return _sizeSlider.value / MAX(1, _scrollView.zoomScale);
}

- (NSValue *)normalizedPoint:(CGPoint)point {
	CGSize size = _contentView.bounds.size;
	CGFloat x = MAX(0, MIN(1, point.x / size.width)), y = MAX(0, MIN(1, point.y / size.height));
	return [NSValue valueWithCGPoint:CGPointMake(_crop.origin.x + x * _crop.size.width, _crop.origin.y + y * _crop.size.height)];
}

- (void)beginStrokeAt:(CGPoint)point {
	_current = [STKBrushStroke new];
	_current.restores = _modeControl.selectedSegmentIndex == STKBrushModeRestore;
	_current.width = [self brushDiameter] / _contentView.bounds.size.width * _crop.size.width;
	_currentPoints = [NSMutableArray arrayWithObject:[self normalizedPoint:point]];
}

- (void)extendStrokeTo:(CGPoint)point {
	[_currentPoints addObject:[self normalizedPoint:point]];
	_current.points = _currentPoints;
	_resultView.image = [STKStickerFactory applyStrokes:@[_current] toImage:_committed original:_originalPreview crop:_crop];
	CGFloat diameter = [self brushDiameter];
	[CATransaction begin];
	[CATransaction setDisableActions:YES];
	_brushLayer.hidden = NO;
	_brushLayer.lineWidth = 1.5 / MAX(1, _scrollView.zoomScale);
	_brushLayer.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(point.x - diameter / 2, point.y - diameter / 2, diameter, diameter)].CGPath;
	[CATransaction commit];
}

- (void)commitStroke {
	if (!_current) {
		return;
	}
	[_strokes addObject:_current];
	_committed = _resultView.image;
	_current = nil;
	_currentPoints = nil;
	_brushLayer.hidden = YES;
	[self updateButtons];
}

- (STKStrokeKind)tool {
	return (STKStrokeKind)_toolControl.selectedSegmentIndex;
}

- (void)paint:(UIPanGestureRecognizer *)gesture {
	CGPoint location = [gesture locationInView:_contentView];
	if ([self tool] != STKStrokeKindBrush) {
		[self lasso:gesture at:location];
		return;
	}
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan: {
			// Start where the finger first touched, not where the pan's movement threshold was crossed.
			CGPoint translation = [gesture translationInView:_contentView];
			[self beginStrokeAt:CGPointMake(location.x - translation.x, location.y - translation.y)];
			[self extendStrokeTo:location];
			break;
		}
		case UIGestureRecognizerStateChanged:
			[self extendStrokeTo:location];
			break;
		case UIGestureRecognizerStateEnded:
		case UIGestureRecognizerStateCancelled:
			[self commitStroke];
			break;
		default:
			break;
	}
}

- (void)dab:(UITapGestureRecognizer *)gesture {
	if ([self tool] != STKStrokeKindBrush) {
		return;
	}
	CGPoint location = [gesture locationInView:_contentView];
	[self beginStrokeAt:location];
	_current.points = _currentPoints;
	_resultView.image = [STKStickerFactory applyStrokes:@[_current] toImage:_committed original:_originalPreview crop:_crop];
	[self commitStroke];
}

#pragma mark - Lasso

- (void)lasso:(UIPanGestureRecognizer *)gesture at:(CGPoint)location {
	switch (gesture.state) {
		case UIGestureRecognizerStateBegan: {
			CGPoint translation = [gesture translationInView:_contentView];
			_current = [STKBrushStroke new];
			_current.kind = [self tool];
			_current.restores = _modeControl.selectedSegmentIndex == STKBrushModeRestore;
			_currentPoints = [NSMutableArray arrayWithObject:[self normalizedPoint:CGPointMake(location.x - translation.x, location.y - translation.y)]];
			_lassoPath = [UIBezierPath bezierPath];
			[_lassoPath moveToPoint:CGPointMake(location.x - translation.x, location.y - translation.y)];
		}
		// Fall through.
		case UIGestureRecognizerStateChanged:
			[_currentPoints addObject:[self normalizedPoint:location]];
			[_lassoPath addLineToPoint:location];
			[CATransaction begin];
			[CATransaction setDisableActions:YES];
			_lassoLayer.hidden = NO;
			_lassoLayer.lineWidth = 1.5 / MAX(1, _scrollView.zoomScale);
			_lassoLayer.path = _lassoPath.CGPath;
			[CATransaction commit];
			break;
		case UIGestureRecognizerStateEnded:
			[self finishLasso];
			break;
		case UIGestureRecognizerStateCancelled:
		case UIGestureRecognizerStateFailed:
			[self discardLasso];
			break;
		default:
			break;
	}
}

- (void)discardLasso {
	_current = nil;
	_currentPoints = nil;
	_lassoPath = nil;
	_lassoLayer.hidden = YES;
}

- (void)finishLasso {
	CGRect bounds = CGPathGetPathBoundingBox(_lassoPath.CGPath);
	if (_currentPoints.count < 3 || MAX(bounds.size.width, bounds.size.height) < 8) {
		[self discardLasso];
		return;
	}
	[_lassoPath closePath];
	_lassoLayer.path = _lassoPath.CGPath;
	_current.points = _currentPoints;
	if (_current.kind == STKStrokeKindLasso) {
		[self commitLasso];
		return;
	}
	STKBrushStroke *stroke = _current;
	self.view.userInteractionEnabled = NO;
	[_findingSpinner startAnimating];
	[STKStickerFactory findSelectionForStroke:stroke inImage:_originalPreview crop:_crop completion:^(BOOL found) {
		self.view.userInteractionEnabled = YES;
		[self->_findingSpinner stopAnimating];
		if (stroke != self->_current) {
			return;
		}
		if (!found && stroke.restores) {
			[self discardLasso];
			[self showToast:@"Couldn't find anything to add there. Try circling it more closely, or use Lasso to bring back the whole area."];
			return;
		}
		if (!found) {
			// Nothing stands out in there, so it's all background: erase the whole outline.
			stroke.kind = STKStrokeKindLasso;
		}
		[self commitLasso];
	}];
}

- (void)commitLasso {
	_resultView.image = [STKStickerFactory applyStrokes:@[_current] toImage:_committed original:_originalPreview crop:_crop];
	[self commitStroke];
	[self discardLasso];
}

- (void)showToast:(NSString *)text {
	_toastLabel.text = [NSString stringWithFormat:@"  %@  ", text];
	[NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
	[UIView animateWithDuration:0.2 animations:^{
		self->_toastLabel.alpha = 1;
	}];
	[self performSelector:@selector(hideToast) withObject:nil afterDelay:3.5];
}

- (void)hideToast {
	[UIView animateWithDuration:0.3 animations:^{
		self->_toastLabel.alpha = 0;
	}];
}

- (void)toolChanged {
	STKStrokeKind tool = [self tool];
	// Disabled rather than hidden, so the canvas (and its zoom) stays put.
	_sizeSlider.enabled = tool == STKStrokeKindBrush;
	NSString *text = tool == STKStrokeKindBrush ? @"Paint with one finger."
		: tool == STKStrokeKindLasso ? @"Draw around an area to erase or restore all of it."
		: @"Draw a loop around something. Restore adds the object inside, Erase removes it.";
	text = [text stringByAppendingString:@" Pinch to zoom; drag with two fingers to move."];
	_hintLabel.text = self.hint.length ? [text stringByAppendingFormat:@" %@", self.hint] : text;
}

- (void)modeChanged {
	// Show the original faintly while restoring, so it's clear what can be painted back.
	[UIView animateWithDuration:0.2 animations:^{
		self->_ghostView.alpha = self->_modeControl.selectedSegmentIndex == STKBrushModeRestore ? 0.35 : 0;
	}];
}

- (void)undo {
	if (!_strokes.count) {
		return;
	}
	[_strokes removeLastObject];
	[self redrawAll];
}

- (void)startOver {
	[_strokes removeAllObjects];
	[self redrawAll];
}

- (void)redrawAll {
	_committed = [STKStickerFactory applyStrokes:_strokes toImage:_basePreview original:_originalPreview crop:_crop];
	_resultView.image = _committed;
	[self updateButtons];
}

- (void)updateButtons {
	_undoButton.enabled = _strokes.count > 0;
	_resetButton.enabled = _strokes.count > 0;
}

- (void)cancel {
	[self.navigationController popViewControllerAnimated:YES];
}

- (void)done {
	void (^onDone)(NSArray<STKBrushStroke *> *) = self.onDone;
	if (onDone) {
		onDone([_strokes copy]);
	}
	[self.navigationController popViewControllerAnimated:YES];
}

@end
