#import "STKCropViewController.h"
#import <AVFoundation/AVFoundation.h>

static const CGFloat kHandleReach = 28;
static const CGFloat kMinCropSide = 48;

typedef NS_OPTIONS(NSUInteger, STKCropEdge) {
	STKCropEdgeNone = 0,
	STKCropEdgeLeft = 1 << 0,
	STKCropEdgeRight = 1 << 1,
	STKCropEdgeTop = 1 << 2,
	STKCropEdgeBottom = 1 << 3,
	STKCropEdgeMove = 1 << 4,
};

// Dims everything outside the crop box and draws the box with corner handles and a rule-of-thirds grid.
@interface STKCropOverlayView : UIView
@property (nonatomic) CGRect imageRect;
@property (nonatomic) CGRect crop;
@end

@implementation STKCropOverlayView

- (CGRect)cropRectInView {
	CGRect image = self.imageRect;
	return CGRectMake(image.origin.x + self.crop.origin.x * image.size.width, image.origin.y + self.crop.origin.y * image.size.height,
		self.crop.size.width * image.size.width, self.crop.size.height * image.size.height);
}

- (void)setCrop:(CGRect)crop {
	_crop = crop;
	[self setNeedsDisplay];
}

- (void)setImageRect:(CGRect)imageRect {
	_imageRect = imageRect;
	[self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
	CGRect box = [self cropRectInView];
	UIBezierPath *dim = [UIBezierPath bezierPathWithRect:self.imageRect];
	[dim appendPath:[UIBezierPath bezierPathWithRect:box]];
	dim.usesEvenOddFillRule = YES;
	[[UIColor colorWithWhite:0 alpha:0.55] setFill];
	[dim fill];

	[[UIColor colorWithWhite:1 alpha:0.45] setStroke];
	UIBezierPath *grid = [UIBezierPath bezierPath];
	for (int line = 1; line < 3; line++) {
		CGFloat x = box.origin.x + box.size.width * line / 3, y = box.origin.y + box.size.height * line / 3;
		[grid moveToPoint:CGPointMake(x, CGRectGetMinY(box))];
		[grid addLineToPoint:CGPointMake(x, CGRectGetMaxY(box))];
		[grid moveToPoint:CGPointMake(CGRectGetMinX(box), y)];
		[grid addLineToPoint:CGPointMake(CGRectGetMaxX(box), y)];
	}
	grid.lineWidth = 0.5;
	[grid stroke];

	[UIColor.whiteColor setStroke];
	UIBezierPath *border = [UIBezierPath bezierPathWithRect:box];
	border.lineWidth = 1;
	[border stroke];

	CGFloat length = MIN(20, MIN(box.size.width, box.size.height) / 2);
	UIBezierPath *corners = [UIBezierPath bezierPath];
	CGRect inset = CGRectInset(box, -1.5, -1.5);
	for (int corner = 0; corner < 4; corner++) {
		CGFloat x = corner % 2 ? CGRectGetMaxX(inset) : CGRectGetMinX(inset);
		CGFloat y = corner / 2 ? CGRectGetMaxY(inset) : CGRectGetMinY(inset);
		CGFloat dx = corner % 2 ? -length : length, dy = corner / 2 ? -length : length;
		[corners moveToPoint:CGPointMake(x + dx, y)];
		[corners addLineToPoint:CGPointMake(x, y)];
		[corners addLineToPoint:CGPointMake(x, y + dy)];
	}
	corners.lineWidth = 3;
	[corners stroke];
}

@end

@implementation STKCropViewController {
	UIImage *_image;
	CGRect _crop;
	UIImageView *_imageView;
	STKCropOverlayView *_overlay;
	STKCropEdge _dragEdges;
	CGRect _dragStartCrop;
}

- (instancetype)initWithImage:(UIImage *)image crop:(CGRect)crop {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_image = image;
		_crop = CGRectIsEmpty(crop) ? CGRectMake(0, 0, 1, 1) : crop;
		self.title = @"Crop";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
	self.navigationItem.hidesBackButton = YES;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];

	_imageView = [[UIImageView alloc] initWithImage:_image];
	_imageView.contentMode = UIViewContentModeScaleAspectFit;
	_imageView.translatesAutoresizingMaskIntoConstraints = NO;
	// The photo's pixel size is its intrinsic size; let it shrink rather than squash the Reset button (as it did in
	// the taller iPad sheet).
	[_imageView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
	[_imageView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
	[self.view addSubview:_imageView];

	_overlay = [STKCropOverlayView new];
	_overlay.backgroundColor = UIColor.clearColor;
	_overlay.contentMode = UIViewContentModeRedraw;
	_overlay.crop = _crop;
	_overlay.translatesAutoresizingMaskIntoConstraints = NO;
	[_overlay addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
	[self.view addSubview:_overlay];

	UIButton *reset = [UIButton buttonWithConfiguration:[UIButtonConfiguration grayButtonConfiguration] primaryAction:[UIAction actionWithTitle:@"Reset" image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(UIAction *action) {
		[self setCrop:CGRectMake(0, 0, 1, 1)];
	}]];
	reset.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:reset];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[_imageView.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
		[_imageView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
		[_imageView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
		[_imageView.bottomAnchor constraintEqualToAnchor:reset.topAnchor constant:-24],
		[_overlay.topAnchor constraintEqualToAnchor:_imageView.topAnchor constant:-kHandleReach],
		[_overlay.bottomAnchor constraintEqualToAnchor:_imageView.bottomAnchor constant:kHandleReach],
		[_overlay.leadingAnchor constraintEqualToAnchor:_imageView.leadingAnchor constant:-kHandleReach],
		[_overlay.trailingAnchor constraintEqualToAnchor:_imageView.trailingAnchor constant:kHandleReach],
		[reset.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
		[reset.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
	]];
}

- (void)viewDidLayoutSubviews {
	[super viewDidLayoutSubviews];
	// The overlay extends past the image so handles on the image's edges are easy to grab.
	CGRect fitted = AVMakeRectWithAspectRatioInsideRect(_image.size, _imageView.bounds);
	_overlay.imageRect = CGRectOffset(fitted, kHandleReach, kHandleReach);
}

- (void)setCrop:(CGRect)crop {
	_crop = crop;
	_overlay.crop = crop;
}

- (void)pan:(UIPanGestureRecognizer *)gesture {
	CGRect image = _overlay.imageRect;
	if (image.size.width <= 0 || image.size.height <= 0) {
		return;
	}
	if (gesture.state == UIGestureRecognizerStateBegan) {
		// Where the finger first touched, before the pan's movement threshold.
		CGPoint location = [gesture locationInView:_overlay];
		CGPoint translation = [gesture translationInView:_overlay];
		CGPoint start = CGPointMake(location.x - translation.x, location.y - translation.y);
		CGRect box = [_overlay cropRectInView];
		STKCropEdge edges = STKCropEdgeNone;
		if (CGRectContainsPoint(CGRectInset(box, -kHandleReach, -kHandleReach), start)) {
			if (fabs(start.x - CGRectGetMinX(box)) < kHandleReach) {
				edges |= STKCropEdgeLeft;
			} else if (fabs(start.x - CGRectGetMaxX(box)) < kHandleReach) {
				edges |= STKCropEdgeRight;
			}
			if (fabs(start.y - CGRectGetMinY(box)) < kHandleReach) {
				edges |= STKCropEdgeTop;
			} else if (fabs(start.y - CGRectGetMaxY(box)) < kHandleReach) {
				edges |= STKCropEdgeBottom;
			}
			if (edges == STKCropEdgeNone && CGRectContainsPoint(box, start)) {
				edges = STKCropEdgeMove;
			}
		}
		_dragEdges = edges;
		_dragStartCrop = _crop;
	}
	if (_dragEdges == STKCropEdgeNone || (gesture.state != UIGestureRecognizerStateBegan && gesture.state != UIGestureRecognizerStateChanged)) {
		return;
	}

	CGPoint translation = [gesture translationInView:_overlay];
	CGFloat dx = translation.x / image.size.width, dy = translation.y / image.size.height;
	CGFloat minWidth = MIN(1, kMinCropSide / image.size.width), minHeight = MIN(1, kMinCropSide / image.size.height);
	CGRect start = _dragStartCrop;
	if (_dragEdges == STKCropEdgeMove) {
		CGFloat x = MAX(0, MIN(1 - start.size.width, start.origin.x + dx));
		CGFloat y = MAX(0, MIN(1 - start.size.height, start.origin.y + dy));
		[self setCrop:CGRectMake(x, y, start.size.width, start.size.height)];
		return;
	}
	CGFloat minX = CGRectGetMinX(start), maxX = CGRectGetMaxX(start), minY = CGRectGetMinY(start), maxY = CGRectGetMaxY(start);
	if (_dragEdges & STKCropEdgeLeft) {
		minX = MAX(0, MIN(maxX - minWidth, minX + dx));
	}
	if (_dragEdges & STKCropEdgeRight) {
		maxX = MIN(1, MAX(minX + minWidth, maxX + dx));
	}
	if (_dragEdges & STKCropEdgeTop) {
		minY = MAX(0, MIN(maxY - minHeight, minY + dy));
	}
	if (_dragEdges & STKCropEdgeBottom) {
		maxY = MIN(1, MAX(minY + minHeight, maxY + dy));
	}
	[self setCrop:CGRectMake(minX, minY, maxX - minX, maxY - minY)];
}

- (void)cancel {
	[self.navigationController popViewControllerAnimated:YES];
}

- (void)done {
	void (^onDone)(CGRect) = self.onDone;
	if (onDone) {
		onDone(_crop);
	}
	[self.navigationController popViewControllerAnimated:YES];
}

@end
