#import "STKPreviewViewController.h"
#import "STKCropViewController.h"
#import "STKCutoutEditorViewController.h"
#import "STKMediaSource.h"
#import "STKStickerFactory.h"
#import "STKStore.h"

typedef NS_ENUM(NSInteger, STKBackgroundMode) {
	STKBackgroundModeRemove,
	STKBackgroundModeKeep,
};

typedef NS_ENUM(NSInteger, STKMotionMode) {
	STKMotionModeAnimated,
	STKMotionModeStill,
};

@implementation STKPreviewViewController {
	STKMediaSource *_source;
	// Normalized to the source; strokes are in the same uncropped coordinates, so they survive re-cropping.
	CGRect _crop;
	NSArray<STKBrushStroke *> *_strokes;
	UIImage *_croppedStill;
	NSArray<UIImage *> *_croppedFrames;
	UIImage *_liftedStill;
	// Cut-outs of the cropped frames, by index into the source's frames; only the frames the chosen rate uses.
	NSMutableDictionary<NSNumber *, UIImage *> *_liftedFrames;
	NSArray<NSNumber *> *_frameRates;
	BOOL _liftFailed;
	BOOL _lifting;
	STKRenderedSticker *_sticker;
	NSUInteger _renderGeneration;

	UIImageView *_imageView;
	UIActivityIndicatorView *_spinner;
	UISegmentedControl *_backgroundControl;
	UISegmentedControl *_motionControl;
	UISegmentedControl *_frameRateControl;
	UIStackView *_frameRateRow;
	UISwitch *_outlineSwitch;
	UIButton *_cropButton;
	UIButton *_eraseButton;
	UILabel *_statusLabel;
}

- (instancetype)initWithSource:(STKMediaSource *)source {
	if ((self = [super initWithNibName:nil bundle:nil])) {
		_source = source;
		_crop = CGRectMake(0, 0, 1, 1);
		_strokes = @[];
		_liftedFrames = [NSMutableDictionary dictionary];
		self.title = source.animated ? @"New Live Sticker" : @"New Sticker";
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(save)];

	UIView *canvas = [UIView new];
	canvas.backgroundColor = [UIColor colorWithPatternImage:STKCheckerboardPattern()];
	canvas.layer.cornerRadius = 16;
	canvas.clipsToBounds = YES;

	_imageView = [UIImageView new];
	_imageView.contentMode = UIViewContentModeScaleAspectFit;
	_imageView.translatesAutoresizingMaskIntoConstraints = NO;
	[canvas addSubview:_imageView];

	_spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
	_spinner.hidesWhenStopped = YES;
	_spinner.translatesAutoresizingMaskIntoConstraints = NO;
	[canvas addSubview:_spinner];

	_backgroundControl = [[UISegmentedControl alloc] initWithItems:@[@"Remove Background", @"Keep Background"]];
	_backgroundControl.selectedSegmentIndex = _source.alreadyCutOut ? STKBackgroundModeKeep : STKBackgroundModeRemove;
	_backgroundControl.hidden = _source.alreadyCutOut;
	[_backgroundControl addTarget:self action:@selector(optionsChanged) forControlEvents:UIControlEventValueChanged];

	_motionControl = [[UISegmentedControl alloc] initWithItems:@[@"Animated", @"Still"]];
	_motionControl.selectedSegmentIndex = STKMotionModeAnimated;
	_motionControl.hidden = !_source.animated;
	[_motionControl addTarget:self action:@selector(optionsChanged) forControlEvents:UIControlEventValueChanged];

	_cropButton = [self toolButtonWithTitle:@"Crop" symbol:@"crop" action:@selector(showCrop)];
	_eraseButton = [self toolButtonWithTitle:@"Erase & Restore" symbol:@"eraser" action:@selector(showEraser)];
	UIStackView *tools = [[UIStackView alloc] initWithArrangedSubviews:@[_cropButton, _eraseButton]];
	tools.distribution = UIStackViewDistributionFillEqually;
	tools.spacing = 12;

	// The choices go up to the source's own frame rate (60 fps for some videos).
	double native = round([self nativeFrameRate]);
	NSMutableArray<NSNumber *> *rates = [NSMutableArray array];
	for (NSNumber *rate in @[@10, @15, @24, @30, @60]) {
		if (rate.doubleValue < native - 0.5) {
			[rates addObject:rate];
		}
	}
	if (native >= 1) {
		[rates addObject:@(native)];
	}
	_frameRates = rates;
	NSMutableArray<NSString *> *titles = [NSMutableArray array];
	for (NSNumber *rate in rates) {
		[titles addObject:rate.stringValue];
	}
	_frameRateControl = [[UISegmentedControl alloc] initWithItems:titles];
	NSUInteger thirty = [rates indexOfObject:@30];
	_frameRateControl.selectedSegmentIndex = thirty != NSNotFound ? thirty : rates.count - 1;
	[_frameRateControl addTarget:self action:@selector(optionsChanged) forControlEvents:UIControlEventValueChanged];
	UILabel *frameRateLabel = [UILabel new];
	frameRateLabel.text = @"FPS";
	[frameRateLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
	_frameRateRow = [[UIStackView alloc] initWithArrangedSubviews:@[frameRateLabel, _frameRateControl]];
	_frameRateRow.spacing = 12;
	_frameRateRow.hidden = !_source.animated || rates.count < 2;

	UILabel *outlineLabel = [UILabel new];
	outlineLabel.text = @"White Outline";
	_outlineSwitch = [UISwitch new];
	_outlineSwitch.on = YES;
	[_outlineSwitch addTarget:self action:@selector(optionsChanged) forControlEvents:UIControlEventValueChanged];
	UIStackView *outlineRow = [[UIStackView alloc] initWithArrangedSubviews:@[outlineLabel, _outlineSwitch]];
	outlineRow.distribution = UIStackViewDistributionEqualSpacing;

	_statusLabel = [UILabel new];
	_statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
	_statusLabel.textColor = UIColor.secondaryLabelColor;
	_statusLabel.numberOfLines = 0;
	_statusLabel.textAlignment = NSTextAlignmentCenter;

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[canvas, tools, _motionControl, _frameRateRow, _backgroundControl, outlineRow, _statusLabel]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 16;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	UIScrollView *scroll = [UIScrollView new];
	scroll.translatesAutoresizingMaskIntoConstraints = NO;
	[scroll addSubview:stack];
	[self.view addSubview:scroll];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
		[scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
		[scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
		[scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
		[stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
		[stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-16],
		[stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
		[stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20],
		[canvas.heightAnchor constraintEqualToAnchor:canvas.widthAnchor],
		[canvas.heightAnchor constraintLessThanOrEqualToConstant:420],
		[_imageView.topAnchor constraintEqualToAnchor:canvas.topAnchor constant:12],
		[_imageView.bottomAnchor constraintEqualToAnchor:canvas.bottomAnchor constant:-12],
		[_imageView.leadingAnchor constraintEqualToAnchor:canvas.leadingAnchor constant:12],
		[_imageView.trailingAnchor constraintEqualToAnchor:canvas.trailingAnchor constant:-12],
		[_spinner.centerXAnchor constraintEqualToAnchor:canvas.centerXAnchor],
		[_spinner.centerYAnchor constraintEqualToAnchor:canvas.centerYAnchor],
	]];

	[self update];
}

- (UIButton *)toolButtonWithTitle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
	UIButtonConfiguration *configuration = [UIButtonConfiguration grayButtonConfiguration];
	configuration.title = title;
	configuration.image = [UIImage systemImageNamed:symbol];
	configuration.imagePadding = 6;
	UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return button;
}

// Tinted while the crop or brush edits are in use.
- (void)updateToolButtons {
	BOOL cropped = !CGRectEqualToRect(_crop, CGRectMake(0, 0, 1, 1));
	NSArray *states = @[@[_cropButton, @(cropped)], @[_eraseButton, @(_strokes.count > 0)]];
	for (NSArray *state in states) {
		UIButton *button = state[0];
		UIButtonConfiguration *configuration = [state[1] boolValue] ? [UIButtonConfiguration tintedButtonConfiguration] : [UIButtonConfiguration grayButtonConfiguration];
		configuration.title = button.configuration.title;
		configuration.image = button.configuration.image;
		configuration.imagePadding = 6;
		button.configuration = configuration;
		button.enabled = !_lifting;
	}
}

- (double)nativeFrameRate {
	return _source.animated && _source.frameDuration > 0 ? 1 / _source.frameDuration : 0;
}

// Indices into the source's frames, evenly spaced for the chosen frame rate.
- (NSArray<NSNumber *> *)frameIndices {
	NSUInteger count = _source.frames.count;
	double native = [self nativeFrameRate];
	double rate = _frameRateControl.selectedSegmentIndex >= 0 && (NSUInteger)_frameRateControl.selectedSegmentIndex < _frameRates.count ? _frameRates[_frameRateControl.selectedSegmentIndex].doubleValue : native;
	NSUInteger target = native > 0 ? MIN(count, MAX(2, (NSUInteger)round(count * MIN(rate, native) / native))) : count;
	NSMutableArray<NSNumber *> *indices = [NSMutableArray arrayWithCapacity:target];
	for (NSUInteger index = 0; index < target; index++) {
		[indices addObject:@(MIN(count - 1, (NSUInteger)floor(index * (double)count / target)))];
	}
	return indices;
}

- (NSTimeInterval)selectedFrameDuration {
	return _source.frameDuration * _source.frames.count / MAX(1, [self frameIndices].count);
}

- (NSArray<UIImage *> *)selectedFrames {
	NSArray<UIImage *> *cropped = [self croppedFrames];
	NSMutableArray<UIImage *> *frames = [NSMutableArray array];
	for (NSNumber *index in [self frameIndices]) {
		[frames addObject:cropped[index.unsignedIntegerValue]];
	}
	return frames;
}

// nil until every frame the chosen rate needs has been cut out.
- (NSArray<UIImage *> *)selectedLiftedFrames {
	NSMutableArray<UIImage *> *frames = [NSMutableArray array];
	for (NSNumber *index in [self frameIndices]) {
		UIImage *frame = _liftedFrames[index];
		if (!frame) {
			return nil;
		}
		[frames addObject:frame];
	}
	return frames;
}

- (UIImage *)croppedStill {
	if (!_croppedStill) {
		_croppedStill = [STKStickerFactory image:_source.still croppedToNormalizedRect:_crop];
	}
	return _croppedStill;
}

- (NSArray<UIImage *> *)croppedFrames {
	if (!_croppedFrames) {
		NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:_source.frames.count];
		for (UIImage *frame in _source.frames) {
			@autoreleasepool {
				[frames addObject:[STKStickerFactory image:frame croppedToNormalizedRect:_crop]];
			}
		}
		_croppedFrames = frames;
	}
	return _croppedFrames;
}

- (void)showCrop {
	if (_lifting) {
		return;
	}
	UIImage *image = [self wantsAnimation] ? _source.frames.firstObject : _source.still;
	STKCropViewController *crop = [[STKCropViewController alloc] initWithImage:image crop:_crop];
	crop.onDone = ^(CGRect rect) {
		[self setCrop:rect];
	};
	[self.navigationController pushViewController:crop animated:YES];
}

- (void)setCrop:(CGRect)crop {
	if (CGRectEqualToRect(crop, _crop)) {
		return;
	}
	_crop = crop;
	// Background removal runs on the cropped image, so the subject it finds can change.
	_croppedStill = nil;
	_croppedFrames = nil;
	_liftedStill = nil;
	[_liftedFrames removeAllObjects];
	if (_liftFailed) {
		_liftFailed = NO;
		_statusLabel.text = nil;
		[_backgroundControl setEnabled:YES forSegmentAtIndex:STKBackgroundModeRemove];
		_backgroundControl.selectedSegmentIndex = STKBackgroundModeRemove;
	}
	[self update];
}

- (void)showEraser {
	if (_lifting) {
		return;
	}
	BOOL animated = [self wantsAnimation];
	UIImage *original = animated ? [self selectedFrames].firstObject : [self croppedStill];
	UIImage *image = original;
	if ([self wantsBackgroundRemoved]) {
		image = animated ? [self selectedLiftedFrames].firstObject : _liftedStill;
	}
	if (!image || !original) {
		return;
	}
	STKCutoutEditorViewController *editor = [[STKCutoutEditorViewController alloc] initWithImage:image original:original crop:_crop strokes:_strokes];
	editor.hint = animated ? @"Your edits apply to every frame." : nil;
	editor.onDone = ^(NSArray<STKBrushStroke *> *strokes) {
		self->_strokes = strokes;
		[self update];
	};
	[self.navigationController pushViewController:editor animated:YES];
}

- (BOOL)wantsAnimation {
	return _source.animated && _motionControl.selectedSegmentIndex == STKMotionModeAnimated;
}

- (BOOL)wantsBackgroundRemoved {
	return !_source.alreadyCutOut && !_liftFailed && _backgroundControl.selectedSegmentIndex == STKBackgroundModeRemove;
}

- (void)optionsChanged {
	_frameRateRow.hidden = !_source.animated || _frameRates.count < 2 || ![self wantsAnimation];
	[self update];
}

// Lifts the subject if the current options need a cut-out that isn't ready yet, then renders.
- (void)update {
	[self updateToolButtons];
	if (_lifting) {
		return;
	}
	BOOL animated = [self wantsAnimation];
	if ([self wantsBackgroundRemoved] && (animated ? ![self selectedLiftedFrames] : !_liftedStill)) {
		[self liftAnimated:animated];
		return;
	}
	[self render];
}

- (void)liftAnimated:(BOOL)animated {
	_lifting = YES;
	[self updateToolButtons];
	self.navigationItem.rightBarButtonItem.enabled = NO;
	// Only the frames the chosen rate needs and that haven't been cut out yet.
	NSMutableArray<NSNumber *> *indices = [NSMutableArray array];
	NSMutableArray<UIImage *> *frames = [NSMutableArray array];
	if (animated) {
		NSArray<UIImage *> *cropped = [self croppedFrames];
		for (NSNumber *index in [self frameIndices]) {
			if (!_liftedFrames[index]) {
				[indices addObject:index];
				[frames addObject:cropped[index.unsignedIntegerValue]];
			}
		}
	}
	UIImage *still = animated ? nil : [self croppedStill];
	CGRect crop = _crop;
	_imageView.image = animated ? frames.firstObject : still;
	_imageView.alpha = 0.4;
	[_spinner startAnimating];
	_statusLabel.text = @"Finding the subject…";

	// Ignore results for a crop that has since changed.
	BOOL (^stale)(void) = ^BOOL{
		return !CGRectEqualToRect(crop, self->_crop);
	};
	void (^failed)(NSError *) = ^(NSError *error) {
		self->_lifting = NO;
		self->_liftFailed = YES;
		[self updateToolButtons];
		self->_statusLabel.text = error.localizedDescription;
		[self->_backgroundControl setEnabled:NO forSegmentAtIndex:STKBackgroundModeRemove];
		self->_backgroundControl.selectedSegmentIndex = STKBackgroundModeKeep;
		[self render];
	};
	if (!animated) {
		[STKStickerFactory liftSubjectFromImage:still completion:^(UIImage *subject, NSError *error) {
			if (stale()) {
				self->_lifting = NO;
				[self update];
				return;
			}
			if (!subject) {
				failed(error);
				return;
			}
			self->_lifting = NO;
			self->_liftedStill = subject;
			self->_statusLabel.text = nil;
			[self updateToolButtons];
			[self render];
		}];
		return;
	}
	[STKStickerFactory liftSubjectFromFrames:frames progress:^(NSUInteger done, NSUInteger total) {
		self->_statusLabel.text = [NSString stringWithFormat:@"Removing the background… %lu of %lu frames", (unsigned long)done, (unsigned long)total];
	} completion:^(NSArray<UIImage *> *subjects, NSError *error) {
		if (stale()) {
			self->_lifting = NO;
			[self update];
			return;
		}
		if (!subjects) {
			failed(error);
			return;
		}
		self->_lifting = NO;
		for (NSUInteger i = 0; i < indices.count && i < subjects.count; i++) {
			self->_liftedFrames[indices[i]] = subjects[i];
		}
		self->_statusLabel.text = nil;
		[self updateToolButtons];
		[self render];
	}];
}

- (void)render {
	BOOL animated = [self wantsAnimation];
	BOOL removed = [self wantsBackgroundRemoved];
	NSArray<UIImage *> *originals = animated ? [self selectedFrames] : @[[self croppedStill]];
	NSArray<UIImage *> *frames = animated ? (removed ? [self selectedLiftedFrames] : originals) : @[(removed ? _liftedStill : originals.firstObject)];
	NSArray<STKBrushStroke *> *strokes = _strokes;
	CGRect crop = _crop;
	NSTimeInterval frameDuration = animated ? [self selectedFrameDuration] : 0;
	BOOL outline = _outlineSwitch.on;
	NSUInteger generation = ++_renderGeneration;

	self.navigationItem.rightBarButtonItem.enabled = NO;
	[_spinner startAnimating];
	if (animated) {
		_statusLabel.text = @"Making the animation…";
	}
	dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		NSArray<UIImage *> *edited = frames;
		if (strokes.count && frames.count == originals.count) {
			if (originals.count > 1) {
				[STKStickerFactory prepareStrokes:strokes forFrames:originals crop:crop];
			}
			NSMutableArray<UIImage *> *applied = [NSMutableArray arrayWithCapacity:frames.count];
			for (NSUInteger index = 0; index < frames.count; index++) {
				@autoreleasepool {
					[applied addObject:[STKStickerFactory applyStrokes:strokes toImage:frames[index] original:originals[index] crop:crop]];
				}
			}
			edited = applied;
		}
		STKRenderedSticker *sticker = [STKStickerFactory renderFrames:edited frameDuration:frameDuration outline:outline];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (generation != self->_renderGeneration) {
				return;
			}
			self->_sticker = sticker;
			self->_imageView.image = sticker.preview;
			self->_imageView.alpha = 1;
			[self->_spinner stopAnimating];
			if (!self->_liftFailed) {
				self->_statusLabel.text = nil;
			}
			self.navigationItem.rightBarButtonItem.enabled = sticker.data.length > 0;
		});
	});
}

- (void)save {
	STKRenderedSticker *sticker = _sticker;
	if (!sticker.data.length) {
		return;
	}
	self.navigationItem.rightBarButtonItem.enabled = NO;
	NSError *error = nil;
	// Looked up at runtime: in the keyboard's STKCreator.dylib the class lives in the already-loaded tweak.
	STKStore *store = [NSClassFromString(@"STKStore") sharedStore];
	if (![store addStickerData:sticker.data fileExtension:sticker.fileExtension error:&error]) {
		self.navigationItem.rightBarButtonItem.enabled = YES;
		UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Couldn't Save Sticker" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
		[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
		[self presentViewController:alert animated:YES completion:nil];
		return;
	}
	[self finish:YES];
}

- (void)cancel {
	[self finish:NO];
}

- (void)finish:(BOOL)saved {
	void (^onFinish)(BOOL) = self.onFinish;
	[self dismissViewControllerAnimated:YES completion:^{
		if (onFinish) {
			onFinish(saved);
		}
	}];
}

@end

UIImage *STKCheckerboardPattern(void) {
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(20, 20)];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[UIColor.secondarySystemBackgroundColor setFill];
		UIRectFill(CGRectMake(0, 0, 20, 20));
		[UIColor.tertiarySystemFillColor setFill];
		UIRectFill(CGRectMake(0, 0, 10, 10));
		UIRectFill(CGRectMake(10, 10, 10, 10));
	}];
}
