#import "STKStickerFactory.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <dlfcn.h>

// Private VisionKitCore (iOS 16) API used by Photos' "Lift Subject from Background".
// Signatures verified against the iOS 16.4 VisionKitCore binary.
@protocol STKRemoveBackgroundRequestHandler <NSObject>
+ (BOOL)isSupported;
- (void)performRequest:(id)request completion:(void (^)(id result, NSError *error))completion;
@end

@protocol STKRemoveBackgroundRequest <NSObject>
- (instancetype)initWithCGImage:(CGImageRef)image;
- (void)setCropToFit:(BOOL)cropToFit;
// Returns only the subject mask, which is several times quicker than a full cut-out.
- (void)setMaskOnly:(BOOL)maskOnly;
@end

@protocol STKRemoveBackgroundResult <NSObject>
- (CGImageRef)createCGImage CF_RETURNS_RETAINED;
// Where a cropped-to-fit result sits in the input image, in pixels.
- (CGRect)cropRect;
// For mask-only requests: white where the subject is, transparent elsewhere, at a fixed size (512x512 on iOS 16)
// that maps onto the whole input image.
- (CGImageRef)maskImage;
@end

static const CGFloat kStaticCanvas = 512.0;
static const CGFloat kMinStaticCanvas = 300.0;
static const NSUInteger kMaxStickerBytes = 500 * 1024;
static const CGFloat kMaxInputLength = 2048.0;

// Canvas size and frame step tried in order until an animated sticker fits the size limit.
typedef struct {
	CGFloat canvas;
	NSUInteger step;
} STKAnimationBudget;

// Steps are on top of thinning the frames to about kMaxPNGFrames, since PNG and GIF can't fit many more.
static const STKAnimationBudget kAnimationBudgets[] = {
	{320, 1}, {280, 1}, {280, 2}, {240, 2}, {200, 2}, {200, 3},
};
static const STKAnimationBudget kGIFBudgets[] = {
	{280, 1}, {240, 2}, {200, 2}, {160, 3}, {140, 4},
};
static const NSUInteger kMaxPNGFrames = 24;

// HEICS (HEVC frames with alpha, what iOS 17's live stickers use) holds a 30 fps animation in the size limit.
// Each canvas size is tried at falling quality before going smaller.
static const CGFloat kHEICSCanvases[] = {400, 320, 256};
static const CGFloat kHEICSQualities[] = {0.75, 0.6, 0.45, 0.3};

// Background removal requests kept in flight at once. Each one waits on a round trip to mediaanalysisd, so a few
// overlapping requests are about 3x quicker than one at a time (8x with mask-only requests).
static const NSUInteger kLiftsInFlight = 4;

// Smart lasso selections are worked out on a downscaled area of this many pixels on the long side, at most.
static const CGFloat kSelectionMaskSide = 512;
// Below this share of the outline's area, a smart lasso found nothing.
static const CGFloat kMinSelectionCoverage = 0.01;

@implementation STKBrushStroke {
	// What a smart lasso found in each animation frame (NSNull where nothing), keyed by the frame before background
	// removal. Filled off the main thread.
	NSMapTable<UIImage *, id> *_frameMasks;
}

- (void)setMask:(UIImage *)mask forFrame:(UIImage *)frame {
	@synchronized (self) {
		if (!_frameMasks) {
			_frameMasks = [NSMapTable weakToStrongObjectsMapTable];
		}
		[_frameMasks setObject:mask ?: (id)NSNull.null forKey:frame];
	}
}

- (BOOL)hasMaskForFrame:(UIImage *)frame {
	@synchronized (self) {
		return [_frameMasks objectForKey:frame] != nil;
	}
}

// The selection in frame, or nil if nothing was found there. Falls back to the one found where the lasso was drawn.
- (UIImage *)maskForFrame:(UIImage *)frame {
	@synchronized (self) {
		id mask = [_frameMasks objectForKey:frame];
		return mask ? (mask == NSNull.null ? nil : mask) : self.selectionMask;
	}
}

@end

@implementation STKRenderedSticker

- (instancetype)initWithData:(NSData *)data fileExtension:(NSString *)fileExtension preview:(UIImage *)preview animated:(BOOL)animated {
	if ((self = [super init])) {
		_data = data;
		_fileExtension = fileExtension;
		_preview = preview;
		_animated = animated;
	}
	return self;
}

@end

static Class STKVisionKitClass(NSString *name) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		dlopen("/System/Library/PrivateFrameworks/VisionKitCore.framework/VisionKitCore", RTLD_LAZY);
	});
	return NSClassFromString(name);
}

static UIGraphicsImageRendererFormat *STKRendererFormat(void) {
	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
	format.scale = 1;
	format.opaque = NO;
	return format;
}

// Redraws the image upright at scale 1, capping the long edge.
static UIImage *STKNormalizedImage(UIImage *image, CGFloat maxLength) {
	CGSize size = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
	CGFloat factor = MIN(1.0, maxLength / MAX(size.width, size.height));
	if (factor >= 1 && image.scale == 1 && image.imageOrientation == UIImageOrientationUp && image.CGImage) {
		return image;
	}
	size = CGSizeMake(round(size.width * factor), round(size.height * factor));
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:STKRendererFormat()];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[image drawInRect:CGRectMake(0, 0, size.width, size.height)];
	}];
}

// Bounding box of the pixels that are not (nearly) transparent, in pixel coordinates. CGRectNull if none are.
static CGRect STKOpaqueBounds(CGImageRef image) {
	size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
	uint8_t *alpha = calloc(width * height, 1);
	if (!alpha) {
		return CGRectMake(0, 0, width, height);
	}
	CGContextRef context = CGBitmapContextCreate(alpha, width, height, 8, width, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
	CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
	CGContextRelease(context);

	size_t minX = width, minY = height, maxX = 0, maxY = 0;
	for (size_t y = 0; y < height; y++) {
		const uint8_t *row = alpha + y * width;
		for (size_t x = 0; x < width; x++) {
			if (row[x] > 8) {
				if (x < minX) minX = x;
				if (x > maxX) maxX = x;
				if (y < minY) minY = y;
				if (y > maxY) maxY = y;
			}
		}
	}
	free(alpha);
	if (minX > maxX || minY > maxY) {
		return CGRectNull;
	}
	return CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
}

static UIImage *STKCrop(UIImage *image, CGRect rect) {
	CGImageRef cropped = CGImageCreateWithImageInRect(image.CGImage, rect);
	if (!cropped) {
		return image;
	}
	UIImage *result = [UIImage imageWithCGImage:cropped];
	CGImageRelease(cropped);
	return result;
}

// Draws an already-cropped subject centered on a square canvas, with an optional white die-cut outline.
// fast stamps the outline fewer times, which matters when rendering 90 frames.
static UIImage *STKRenderOnCanvas(UIImage *cropped, CGFloat canvas, BOOL outline, BOOL fast) {
	CGFloat outlineWidth = round(canvas * 0.02);
	CGFloat padding = outline ? outlineWidth + canvas * 0.008 + 1 : canvas * 0.008;
	CGFloat inner = canvas - padding * 2;
	CGFloat factor = inner / MAX(cropped.size.width, cropped.size.height);
	CGSize fitted = CGSizeMake(round(cropped.size.width * factor), round(cropped.size.height * factor));
	CGRect target = CGRectMake(round((canvas - fitted.width) / 2), round((canvas - fitted.height) / 2), fitted.width, fitted.height);

	UIImage *silhouette = nil;
	if (outline) {
		UIGraphicsImageRenderer *tint = [[UIGraphicsImageRenderer alloc] initWithSize:fitted format:STKRendererFormat()];
		silhouette = [tint imageWithActions:^(UIGraphicsImageRendererContext *context) {
			CGRect rect = CGRectMake(0, 0, fitted.width, fitted.height);
			[cropped drawInRect:rect];
			[UIColor.whiteColor setFill];
			UIRectFillUsingBlendMode(rect, kCGBlendModeSourceIn);
		}];
	}

	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(canvas, canvas) format:STKRendererFormat()];
	return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
		if (silhouette) {
			// Stamp the white silhouette around the subject to dilate it into a die-cut border.
			CGContextSaveGState(context.CGContext);
			CGContextSetShadowWithColor(context.CGContext, CGSizeMake(0, canvas / 512), canvas / 170, [UIColor colorWithWhite:0 alpha:0.25].CGColor);
			CGContextBeginTransparencyLayer(context.CGContext, NULL);
			int rings = fast ? 2 : 3, stamps = fast ? 20 : 32;
			for (int ring = 1; ring <= rings; ring++) {
				CGFloat radius = outlineWidth * ring / rings;
				for (int step = 0; step < stamps; step++) {
					CGFloat angle = step * 2 * M_PI / stamps;
					[silhouette drawInRect:CGRectOffset(target, radius * cos(angle), radius * sin(angle))];
				}
			}
			CGContextEndTransparencyLayer(context.CGContext);
			CGContextRestoreGState(context.CGContext);
		}
		[cropped drawInRect:target];
	}];
}

// A stroke in the pixel coordinates of an image of the given size cropped to crop (normalized to the source).
static UIBezierPath *STKStrokePath(STKBrushStroke *stroke, CGRect crop, CGSize size) {
	CGFloat scaleX = size.width / crop.size.width, scaleY = size.height / crop.size.height;
	UIBezierPath *path = [UIBezierPath bezierPath];
	path.lineWidth = MAX(1, stroke.width * scaleX);
	path.lineCapStyle = kCGLineCapRound;
	path.lineJoinStyle = kCGLineJoinRound;
	for (NSValue *value in stroke.points) {
		CGPoint point = value.CGPointValue;
		point = CGPointMake((point.x - crop.origin.x) * scaleX, (point.y - crop.origin.y) * scaleY);
		if (path.empty) {
			[path moveToPoint:point];
		} else {
			[path addLineToPoint:point];
		}
	}
	if (stroke.points.count == 1) {
		// A tap: a zero-length line still gets round caps, so it paints a dot.
		[path addLineToPoint:CGPointMake(path.currentPoint.x + 0.01, path.currentPoint.y)];
	}
	return path;
}

typedef NS_ENUM(NSInteger, STKAnimationFormat) {
	STKAnimationFormatPNG,
	STKAnimationFormatGIF,
	STKAnimationFormatHEICS,
};

static BOOL STKCanWriteHEICS(void) {
	static BOOL supported;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSArray *types = CFBridgingRelease(CGImageDestinationCopyTypeIdentifiers());
		supported = [types containsObject:@"public.heics"];
	});
	return supported;
}

// quality only applies to HEICS.
static NSData *STKEncodeAnimation(NSArray<UIImage *> *frames, NSTimeInterval delay, STKAnimationFormat format, CGFloat quality) {
	NSMutableData *data = [NSMutableData data];
	NSString *type = format == STKAnimationFormatGIF ? UTTypeGIF.identifier : format == STKAnimationFormatHEICS ? @"public.heics" : UTTypePNG.identifier;
	CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)type, frames.count, NULL);
	if (!destination) {
		return nil;
	}
	CFStringRef dictionaryKey = format == STKAnimationFormatGIF ? kCGImagePropertyGIFDictionary : format == STKAnimationFormatHEICS ? kCGImagePropertyHEICSDictionary : kCGImagePropertyPNGDictionary;
	CFStringRef loopKey = format == STKAnimationFormatGIF ? kCGImagePropertyGIFLoopCount : format == STKAnimationFormatHEICS ? kCGImagePropertyHEICSLoopCount : kCGImagePropertyAPNGLoopCount;
	CFStringRef delayKey = format == STKAnimationFormatGIF ? kCGImagePropertyGIFDelayTime : format == STKAnimationFormatHEICS ? kCGImagePropertyHEICSDelayTime : kCGImagePropertyAPNGDelayTime;
	CFStringRef unclampedKey = format == STKAnimationFormatGIF ? kCGImagePropertyGIFUnclampedDelayTime : format == STKAnimationFormatHEICS ? kCGImagePropertyHEICSUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime;
	CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{(__bridge NSString *)dictionaryKey: @{(__bridge NSString *)loopKey: @0}});
	// The plain delay is clamped to 0.1 s for old decoders; players use the unclamped one, which allows 30 fps.
	NSMutableDictionary *frameProperties = [@{(__bridge NSString *)dictionaryKey: @{(__bridge NSString *)delayKey: @(delay), (__bridge NSString *)unclampedKey: @(delay)}} mutableCopy];
	if (format == STKAnimationFormatHEICS) {
		frameProperties[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @(quality);
	}
	for (UIImage *frame in frames) {
		CGImageDestinationAddImage(destination, frame.CGImage, (__bridge CFDictionaryRef)frameProperties);
	}
	BOOL ok = CGImageDestinationFinalize(destination);
	CFRelease(destination);
	return ok ? data : nil;
}

// Cuts a frame out with a mask-only result: keeps the frame where the (stretched) mask is opaque.
static UIImage *STKApplyMask(UIImage *frame, CGImageRef mask) {
	CGSize size = frame.size;
	CGRect rect = CGRectMake(0, 0, size.width, size.height);
	UIImage *maskImage = [UIImage imageWithCGImage:mask];
	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:STKRendererFormat()] imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[frame drawInRect:rect];
		[maskImage drawInRect:rect blendMode:kCGBlendModeDestinationIn alpha:1];
	}];
}

static NSError *STKUnsupportedError(void) {
	return [NSError errorWithDomain:@"com.josh.stickers" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Background removal isn't available on this device (requires iOS 16 on an A12 chip or newer)."}];
}

static BOOL STKLiftingReady(void) {
	Class handlerClass = STKVisionKitClass(@"VKCRemoveBackgroundRequestHandler");
	Class requestClass = STKVisionKitClass(@"VKCRemoveBackgroundRequest");
	return [handlerClass respondsToSelector:@selector(isSupported)] && [(Class<STKRemoveBackgroundRequestHandler>)handlerClass isSupported]
		&& [requestClass instancesRespondToSelector:@selector(initWithCGImage:)] && [handlerClass instancesRespondToSelector:@selector(performRequest:completion:)];
}

// A normalized rect (relative to the uncropped source) in the pixel coordinates of an image of the given size
// cropped to crop.
static CGRect STKRectInCrop(CGRect rect, CGRect crop, CGSize size) {
	CGFloat scaleX = size.width / crop.size.width, scaleY = size.height / crop.size.height;
	return CGRectMake((rect.origin.x - crop.origin.x) * scaleX, (rect.origin.y - crop.origin.y) * scaleY, rect.size.width * scaleX, rect.size.height * scaleY);
}

// A lasso's outline in the coordinates of rect, which covers the normalized area within.
static UIBezierPath *STKLassoPath(STKBrushStroke *stroke, CGRect within, CGRect rect) {
	UIBezierPath *path = [UIBezierPath bezierPath];
	for (NSValue *value in stroke.points) {
		CGPoint point = value.CGPointValue;
		point = CGPointMake(rect.origin.x + (point.x - within.origin.x) / within.size.width * rect.size.width,
			rect.origin.y + (point.y - within.origin.y) / within.size.height * rect.size.height);
		if (path.empty) {
			[path moveToPoint:point];
		} else {
			[path addLineToPoint:point];
		}
	}
	[path closePath];
	return path;
}

// The lasso's bounding box plus some surroundings, so background removal sees what the object stands out from.
static CGRect STKSelectionRect(STKBrushStroke *stroke, CGRect crop) {
	CGRect bounds = CGRectNull;
	for (NSValue *value in stroke.points) {
		CGPoint point = value.CGPointValue;
		bounds = CGRectUnion(bounds, CGRectMake(point.x, point.y, 0, 0));
	}
	CGFloat margin = MAX(bounds.size.width, bounds.size.height) * 0.1;
	return CGRectIntersection(CGRectInset(bounds, -margin, -margin), crop);
}

// Turns a background removal mask of the searched area into the lasso's selection: a grayscale image, white where
// selected. Keeps only objects inside the outline; erasing prefers ones the outline goes all the way around. nil if
// the outline holds (next to) nothing.
// pixels is the searched area's size in the frame, for the selection's aspect ratio.
static UIImage *STKSelectionFromMask(CGImageRef found, STKBrushStroke *stroke, CGRect searched, CGSize pixels) {
	CGFloat factor = kSelectionMaskSide / MAX(pixels.width, pixels.height);
	size_t width = MAX(1, (size_t)round(pixels.width * factor)), height = MAX(1, (size_t)round(pixels.height * factor));
	size_t count = width * height;
	uint8_t *mask = calloc(count, 1), *inside = calloc(count, 1);
	int32_t *labels = calloc(count, sizeof(int32_t));
	size_t *stack = malloc(count * sizeof(size_t));
	if (!mask || !inside || !labels || !stack) {
		free(mask), free(inside), free(labels), free(stack);
		return nil;
	}
	CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
	CGContextRef maskContext = CGBitmapContextCreate(mask, width, height, 8, width, gray, (CGBitmapInfo)kCGImageAlphaNone);
	CGContextRef insideContext = CGBitmapContextCreate(inside, width, height, 8, width, gray, (CGBitmapInfo)kCGImageAlphaNone);
	// The mask is white on transparent (or a cut-out), so its alpha over black is the selection.
	CGContextDrawImage(maskContext, CGRectMake(0, 0, width, height), found);
	CGContextTranslateCTM(insideContext, 0, height);
	CGContextScaleCTM(insideContext, 1, -1);
	CGContextAddPath(insideContext, STKLassoPath(stroke, searched, CGRectMake(0, 0, width, height)).CGPath);
	CGContextSetGrayFillColor(insideContext, 1, 1);
	CGContextFillPath(insideContext);

	// Label the found objects (soft edges included) and measure how much of each lies inside the outline.
	size_t outlineArea = 0;
	for (size_t i = 0; i < count; i++) {
		outlineArea += inside[i] > 127;
	}
	NSMutableData *totals = [NSMutableData data], *insides = [NSMutableData data];
	int32_t components = 0;
	for (size_t start = 0; start < count; start++) {
		if (mask[start] < 64 || labels[start]) {
			continue;
		}
		size_t total = 0, within = 0, top = 0;
		labels[start] = ++components;
		stack[top++] = start;
		while (top) {
			size_t i = stack[--top];
			total++;
			within += inside[i] > 127;
			size_t x = i % width, y = i / width;
			size_t neighbours[4] = {x > 0 ? i - 1 : i, x + 1 < width ? i + 1 : i, y > 0 ? i - width : i, y + 1 < height ? i + width : i};
			for (int n = 0; n < 4; n++) {
				size_t j = neighbours[n];
				if (!labels[j] && mask[j] >= 64) {
					labels[j] = components;
					stack[top++] = j;
				}
			}
		}
		[totals appendBytes:&total length:sizeof(total)];
		[insides appendBytes:&within length:sizeof(within)];
	}
	const size_t *componentTotals = totals.bytes, *componentInsides = insides.bytes;
	uint8_t *keep = calloc(components + 1, 1);
	BOOL enclosedOnly = NO;
	if (!stroke.restores) {
		for (int32_t c = 0; c < components; c++) {
			if (componentInsides[c] >= componentTotals[c] * 0.85 && componentInsides[c] >= outlineArea * kMinSelectionCoverage) {
				enclosedOnly = YES;
			}
		}
	}
	size_t selected = 0;
	for (int32_t c = 0; c < components; c++) {
		BOOL enclosed = componentInsides[c] >= componentTotals[c] * 0.85;
		if (componentInsides[c] > 0 && (!enclosedOnly || enclosed)) {
			keep[c + 1] = 1;
			selected += componentInsides[c];
		}
	}
	for (size_t i = 0; i < count; i++) {
		// Firm up the mask's soft patches so erasing doesn't leave a faint ghost, keeping a narrow soft edge.
		mask[i] = keep[labels[i]] ? (uint8_t)MAX(0, MIN(255, ((int)mask[i] - 48) * 255 / 144)) : 0;
	}
	UIImage *selection = nil;
	if (outlineArea && selected >= MAX(20, outlineArea * kMinSelectionCoverage)) {
		CGImageRef image = CGBitmapContextCreateImage(maskContext);
		selection = [UIImage imageWithCGImage:image];
		CGImageRelease(image);
	}
	CGContextRelease(maskContext);
	CGContextRelease(insideContext);
	CGColorSpaceRelease(gray);
	free(mask), free(inside), free(labels), free(stack), free(keep);
	return selection;
}

// Runs background removal on the area around a smart lasso in original (a frame cropped to crop) and calls back, on
// whatever queue VisionKit uses, with the selection or nil.
static void STKFindSelection(STKBrushStroke *stroke, UIImage *original, CGRect crop, id<STKRemoveBackgroundRequestHandler> handler, void (^completion)(UIImage *selection)) {
	CGSize size = CGSizeMake(original.size.width * original.scale, original.size.height * original.scale);
	CGRect area = STKRectInCrop(stroke.selectionRect, crop, size);
	if (CGRectIsEmpty(area) || stroke.points.count < 3) {
		completion(nil);
		return;
	}
	// The area on its own, upscaled if small: the subject finder works on its whole input.
	CGFloat longest = MAX(area.size.width, area.size.height);
	CGFloat factor = MAX(kSelectionMaskSide / longest, MIN(1.0, 1536 / longest));
	CGSize patchSize = CGSizeMake(round(area.size.width * factor), round(area.size.height * factor));
	UIImage *patch = [[[UIGraphicsImageRenderer alloc] initWithSize:patchSize format:STKRendererFormat()] imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[UIColor.blackColor setFill];
		UIRectFill(CGRectMake(0, 0, patchSize.width, patchSize.height));
		[original drawInRect:CGRectMake(-area.origin.x * factor, -area.origin.y * factor, size.width * factor, size.height * factor)];
	}];
	id<STKRemoveBackgroundRequest> request = [(id<STKRemoveBackgroundRequest>)[STKVisionKitClass(@"VKCRemoveBackgroundRequest") alloc] initWithCGImage:patch.CGImage];
	if ([request respondsToSelector:@selector(setCropToFit:)]) {
		[request setCropToFit:NO];
	}
	BOOL maskOnly = [request respondsToSelector:@selector(setMaskOnly:)];
	if (maskOnly) {
		[request setMaskOnly:YES];
	}
	[handler performRequest:request completion:^(id result, NSError *error) {
		CGImageRef found = NULL;
		if (maskOnly && [result respondsToSelector:@selector(maskImage)]) {
			found = CGImageRetain([(id<STKRemoveBackgroundResult>)result maskImage]);
		} else if ([result respondsToSelector:@selector(createCGImage)]) {
			found = [(id<STKRemoveBackgroundResult>)result createCGImage];
		}
		UIImage *selection = nil;
		if (found) {
			selection = STKSelectionFromMask(found, stroke, stroke.selectionRect, area.size);
			CGImageRelease(found);
		}
		completion(selection);
		(void)handler;
	}];
}

// Lifts the subject from every frame of an animation, kLiftsInFlight requests at a time. Keeps itself alive through
// the requests' completion blocks until the last one finishes.
@interface STKFrameLifter : NSObject
@end

@implementation STKFrameLifter {
	NSArray<UIImage *> *_frames;
	NSMutableArray *_subjects;
	NSUInteger _next;
	NSUInteger _finished;
	NSError *_lastError;
	id<STKRemoveBackgroundRequestHandler> _handler;
	void (^_progress)(NSUInteger, NSUInteger);
	void (^_completion)(NSArray<UIImage *> *, NSError *);
}

- (instancetype)initWithFrames:(NSArray<UIImage *> *)frames progress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSArray<UIImage *> *, NSError *))completion {
	if ((self = [super init])) {
		_frames = frames;
		_subjects = [NSMutableArray arrayWithCapacity:frames.count];
		for (NSUInteger index = 0; index < frames.count; index++) {
			[_subjects addObject:NSNull.null];
		}
		_handler = [STKVisionKitClass(@"VKCRemoveBackgroundRequestHandler") new];
		_progress = progress;
		_completion = completion;
	}
	return self;
}

- (void)start {
	if (_progress) {
		_progress(0, _frames.count);
	}
	[self fill];
}

- (void)fill {
	while (_next < _frames.count && _next - _finished < kLiftsInFlight) {
		[self liftFrameAtIndex:_next++];
	}
}

- (void)liftFrameAtIndex:(NSUInteger)index {
	UIImage *frame = STKNormalizedImage(_frames[index], kMaxInputLength);
	id<STKRemoveBackgroundRequest> request = [(id<STKRemoveBackgroundRequest>)[STKVisionKitClass(@"VKCRemoveBackgroundRequest") alloc] initWithCGImage:frame.CGImage];
	if ([request respondsToSelector:@selector(setCropToFit:)]) {
		[request setCropToFit:NO];
	}
	BOOL maskOnly = [request respondsToSelector:@selector(setMaskOnly:)];
	if (maskOnly) {
		[request setMaskOnly:YES];
	}
	[_handler performRequest:request completion:^(id result, NSError *error) {
		UIImage *subject = nil;
		if (maskOnly && [result respondsToSelector:@selector(maskImage)]) {
			CGImageRef mask = [(id<STKRemoveBackgroundResult>)result maskImage];
			if (mask) {
				subject = STKApplyMask(frame, mask);
			}
		} else if ([result respondsToSelector:@selector(createCGImage)]) {
			CGImageRef cgImage = [(id<STKRemoveBackgroundResult>)result createCGImage];
			if (cgImage) {
				subject = [UIImage imageWithCGImage:cgImage];
				CGImageRelease(cgImage);
			}
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			[self finishFrameAtIndex:index subject:subject error:error];
		});
	}];
}

- (void)finishFrameAtIndex:(NSUInteger)index subject:(UIImage *)subject error:(NSError *)error {
	_finished++;
	if (subject) {
		_subjects[index] = subject;
	} else {
		_lastError = error ?: _lastError;
	}
	if (_progress) {
		_progress(_finished, _frames.count);
	}
	if (_finished < _frames.count) {
		[self fill];
		return;
	}

	NSIndexSet *found = [_subjects indexesOfObjectsPassingTest:^BOOL(id candidate, NSUInteger i, BOOL *stop) {
		return candidate != NSNull.null;
	}];
	// Allow the odd frame to miss (a blink, motion blur), but not most of them.
	if (found.count == 0 || found.count * 2 < _frames.count) {
		_completion(nil, _lastError ?: [NSError errorWithDomain:@"com.josh.stickers" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No subject was found in most frames."}]);
		return;
	}
	// A frame with no subject reuses the nearest one that has it, so the result still lines up frame for frame.
	NSMutableArray<UIImage *> *filled = [NSMutableArray arrayWithCapacity:_subjects.count];
	for (NSUInteger i = 0; i < _subjects.count; i++) {
		NSUInteger before = [found indexLessThanOrEqualToIndex:i], after = [found indexGreaterThanOrEqualToIndex:i];
		NSUInteger nearest = before == NSNotFound ? after : after == NSNotFound ? before : (i - before <= after - i ? before : after);
		[filled addObject:_subjects[nearest]];
	}
	_completion(filled, nil);
}

@end

@implementation STKStickerFactory

+ (BOOL)isSubjectLiftingSupported {
	return STKLiftingReady();
}

+ (void)liftSubjectFromImage:(UIImage *)image completion:(void (^)(UIImage *, NSError *))completion {
	Class handlerClass = STKVisionKitClass(@"VKCRemoveBackgroundRequestHandler");
	Class requestClass = STKVisionKitClass(@"VKCRemoveBackgroundRequest");
	if (!STKLiftingReady()) {
		completion(nil, STKUnsupportedError());
		return;
	}

	UIImage *upright = STKNormalizedImage(image, kMaxInputLength);
	id<STKRemoveBackgroundRequest> request = [(id<STKRemoveBackgroundRequest>)[requestClass alloc] initWithCGImage:upright.CGImage];
	// Keep the cut-out the same size as the input so it lines up with the original for restoring and with other frames.
	if ([request respondsToSelector:@selector(setCropToFit:)]) {
		[request setCropToFit:NO];
	}
	id<STKRemoveBackgroundRequestHandler> handler = [handlerClass new];
	[handler performRequest:request completion:^(id result, NSError *error) {
		UIImage *subject = nil;
		if ([result respondsToSelector:@selector(createCGImage)]) {
			CGImageRef cgImage = [(id<STKRemoveBackgroundResult>)result createCGImage];
			if (cgImage) {
				subject = [UIImage imageWithCGImage:cgImage];
				CGImageRelease(cgImage);
			}
		}
		if (subject && !CGSizeEqualToSize(subject.size, upright.size)) {
			// Cropped to the subject anyway: put it back where it was in the input.
			CGRect place = [result respondsToSelector:@selector(cropRect)] ? [(id<STKRemoveBackgroundResult>)result cropRect] : CGRectNull;
			if (CGRectIsEmpty(place) || fabs(place.size.width - subject.size.width) > 2 || fabs(place.size.height - subject.size.height) > 2) {
				place = CGRectMake(0, 0, upright.size.width, upright.size.height);
			}
			UIImage *cutOut = subject;
			subject = [[[UIGraphicsImageRenderer alloc] initWithSize:upright.size format:STKRendererFormat()] imageWithActions:^(UIGraphicsImageRendererContext *context) {
				[cutOut drawInRect:place];
			}];
		}
		if (!subject && !error) {
			error = [NSError errorWithDomain:@"com.josh.stickers" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No subject was found in this photo."}];
		}
		// Keep the handler alive until the request finishes.
		(void)handler;
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(subject, subject ? nil : error);
		});
	}];
}

+ (void)liftSubjectFromFrames:(NSArray<UIImage *> *)frames progress:(void (^)(NSUInteger, NSUInteger))progress completion:(void (^)(NSArray<UIImage *> *, NSError *))completion {
	if (!STKLiftingReady()) {
		completion(nil, STKUnsupportedError());
		return;
	}
	[[[STKFrameLifter alloc] initWithFrames:frames progress:progress completion:completion] start];
}

+ (UIImage *)image:(UIImage *)image croppedToNormalizedRect:(CGRect)crop {
	CGRect unit = CGRectMake(0, 0, 1, 1);
	crop = CGRectIntersection(crop, unit);
	if (CGRectIsEmpty(crop)) {
		crop = unit;
	}
	CGSize full = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
	if (CGRectEqualToRect(crop, unit) && image.imageOrientation == UIImageOrientationUp && image.scale == 1 && MAX(full.width, full.height) <= kMaxInputLength) {
		return image;
	}
	CGFloat factor = MIN(1.0, kMaxInputLength / MAX(crop.size.width * full.width, crop.size.height * full.height));
	CGSize size = CGSizeMake(MAX(1, round(crop.size.width * full.width * factor)), MAX(1, round(crop.size.height * full.height * factor)));
	CGRect drawn = CGRectMake(-crop.origin.x * full.width * factor, -crop.origin.y * full.height * factor, full.width * factor, full.height * factor);
	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:STKRendererFormat()] imageWithActions:^(UIGraphicsImageRendererContext *context) {
		[image drawInRect:drawn];
	}];
}

+ (UIImage *)applyStrokes:(NSArray<STKBrushStroke *> *)strokes toImage:(UIImage *)image original:(UIImage *)original crop:(CGRect)crop {
	if (!strokes.count) {
		return image;
	}
	CGSize size = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
	CGRect rect = CGRectMake(0, 0, size.width, size.height);
	return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:STKRendererFormat()] imageWithActions:^(UIGraphicsImageRendererContext *context) {
		CGContextRef cg = context.CGContext;
		[image drawInRect:rect];
		for (STKBrushStroke *stroke in strokes) {
			if (stroke.kind == STKStrokeKindInvert) {
				// The original with everything drawn so far cut out of it.
				CGImageRef drawn = CGBitmapContextCreateImage(cg);
				[original drawInRect:rect blendMode:kCGBlendModeCopy alpha:1];
				[[UIImage imageWithCGImage:drawn] drawInRect:rect blendMode:kCGBlendModeDestinationOut alpha:1];
				CGImageRelease(drawn);
				continue;
			}
			CGContextSaveGState(cg);
			if (stroke.kind == STKStrokeKindBrush) {
				UIBezierPath *path = STKStrokePath(stroke, crop, size);
				CGContextAddPath(cg, path.CGPath);
				CGContextSetLineWidth(cg, path.lineWidth);
				CGContextSetLineCap(cg, kCGLineCapRound);
				CGContextSetLineJoin(cg, kCGLineJoinRound);
				CGContextReplacePathWithStrokedPath(cg);
				CGContextClip(cg);
			} else if (stroke.kind != STKStrokeKindWhole) {
				CGContextAddPath(cg, STKLassoPath(stroke, crop, rect).CGPath);
				CGContextClip(cg);
				if (stroke.kind == STKStrokeKindSmartLasso) {
					UIImage *mask = [stroke maskForFrame:original];
					if (!mask && stroke.restores) {
						// Nothing found to add in this frame. (Erasing with nothing found clears the whole outline.)
						CGContextRestoreGState(cg);
						continue;
					}
					if (mask) {
						// Clip masks are drawn bottom-up, so flip around the mask's rect; flipping again undoes it.
						CGRect maskRect = STKRectInCrop(stroke.selectionRect, crop, size);
						CGFloat flip = maskRect.origin.y * 2 + maskRect.size.height;
						CGContextTranslateCTM(cg, 0, flip);
						CGContextScaleCTM(cg, 1, -1);
						CGContextClipToMask(cg, maskRect, mask.CGImage);
						CGContextTranslateCTM(cg, 0, flip);
						CGContextScaleCTM(cg, 1, -1);
					}
				}
			}
			if (stroke.restores) {
				// Copy the original's pixels (alpha included) back in.
				[original drawInRect:rect blendMode:kCGBlendModeCopy alpha:1];
			} else {
				CGContextSetBlendMode(cg, kCGBlendModeClear);
				CGContextFillRect(cg, rect);
			}
			CGContextRestoreGState(cg);
		}
	}];
}

+ (void)findSelectionForStroke:(STKBrushStroke *)stroke inImage:(UIImage *)original crop:(CGRect)crop completion:(void (^)(BOOL))completion {
	if (!STKLiftingReady()) {
		completion(NO);
		return;
	}
	stroke.selectionRect = STKSelectionRect(stroke, crop);
	STKFindSelection(stroke, original, crop, [STKVisionKitClass(@"VKCRemoveBackgroundRequestHandler") new], ^(UIImage *selection) {
		dispatch_async(dispatch_get_main_queue(), ^{
			stroke.selectionMask = selection;
			completion(selection != nil);
		});
	});
}

+ (void)prepareStrokes:(NSArray<STKBrushStroke *> *)strokes forFrames:(NSArray<UIImage *> *)originals crop:(CGRect)crop {
	if (!STKLiftingReady()) {
		return;
	}
	id<STKRemoveBackgroundRequestHandler> handler = [STKVisionKitClass(@"VKCRemoveBackgroundRequestHandler") new];
	dispatch_semaphore_t slots = dispatch_semaphore_create(kLiftsInFlight);
	dispatch_group_t group = dispatch_group_create();
	for (STKBrushStroke *stroke in strokes) {
		if (stroke.kind != STKStrokeKindSmartLasso || CGRectIsEmpty(stroke.selectionRect)) {
			continue;
		}
		for (UIImage *original in originals) {
			if ([stroke hasMaskForFrame:original]) {
				continue;
			}
			// A request that never calls back shouldn't hang the render; that frame keeps the drawn-on frame's selection.
			if (dispatch_semaphore_wait(slots, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) != 0) {
				break;
			}
			dispatch_group_enter(group);
			@autoreleasepool {
				STKFindSelection(stroke, original, crop, handler, ^(UIImage *selection) {
					[stroke setMask:selection forFrame:original];
					dispatch_semaphore_signal(slots);
					dispatch_group_leave(group);
				});
			}
		}
	}
	dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
}

+ (STKRenderedSticker *)renderFrames:(NSArray<UIImage *> *)frames frameDuration:(NSTimeInterval)frameDuration outline:(BOOL)outline {
	NSMutableArray<UIImage *> *upright = [NSMutableArray arrayWithCapacity:frames.count];
	for (UIImage *frame in frames) {
		[upright addObject:STKNormalizedImage(frame, kMaxInputLength)];
	}

	// One crop box for every frame, so the subject doesn't jump around as it moves.
	CGRect bounds = CGRectNull;
	for (UIImage *frame in upright) {
		bounds = CGRectUnion(bounds, STKOpaqueBounds(frame.CGImage));
	}
	if (CGRectIsNull(bounds)) {
		bounds = CGRectMake(0, 0, upright.firstObject.size.width, upright.firstObject.size.height);
	}
	NSMutableArray<UIImage *> *cropped = [NSMutableArray arrayWithCapacity:upright.count];
	for (UIImage *frame in upright) {
		[cropped addObject:STKCrop(frame, bounds)];
	}

	if (cropped.count == 1) {
		CGFloat canvas = kStaticCanvas;
		UIImage *sticker = STKRenderOnCanvas(cropped.firstObject, canvas, outline, NO);
		NSData *data = UIImagePNGRepresentation(sticker);
		while (data.length > kMaxStickerBytes && canvas > kMinStaticCanvas) {
			canvas = MAX(kMinStaticCanvas, round(canvas * 0.85));
			sticker = STKRenderOnCanvas(cropped.firstObject, canvas, outline, NO);
			data = UIImagePNGRepresentation(sticker);
		}
		return [[STKRenderedSticker alloc] initWithData:data fileExtension:@"png" preview:sticker animated:NO];
	}

	__block NSData *data = nil;
	__block NSArray<UIImage *> *rendered = nil;
	__block NSTimeInterval delay = frameDuration;
	NSArray<UIImage *> *(^renderCanvas)(CGFloat, NSUInteger) = ^NSArray<UIImage *> *(CGFloat canvas, NSUInteger step) {
		NSMutableArray<UIImage *> *canvasFrames = [NSMutableArray array];
		for (NSUInteger index = 0; index < cropped.count; index += step) {
			@autoreleasepool {
				[canvasFrames addObject:STKRenderOnCanvas(cropped[index], canvas, outline, YES)];
			}
		}
		return canvasFrames;
	};

	// HEICS first: every frame, rendering each canvas size once and trying qualities on it. If even that is too big
	// (60 fps can be), every other frame before giving up on HEICS.
	if (STKCanWriteHEICS()) {
		for (NSUInteger step = 1; step <= 2; step++) {
			for (size_t size = step == 1 ? 0 : 1; size < sizeof(kHEICSCanvases) / sizeof(kHEICSCanvases[0]); size++) {
				NSArray<UIImage *> *canvasFrames = renderCanvas(kHEICSCanvases[size], step);
				NSTimeInterval stepDelay = frameDuration * step;
				for (size_t level = 0; level < sizeof(kHEICSQualities) / sizeof(kHEICSQualities[0]); level++) {
					NSData *encoded = STKEncodeAnimation(canvasFrames, stepDelay, STKAnimationFormatHEICS, kHEICSQualities[level]);
					if (encoded.length > 0 && encoded.length <= kMaxStickerBytes) {
						UIImage *preview = [UIImage animatedImageWithImages:canvasFrames duration:stepDelay * canvasFrames.count];
						return [[STKRenderedSticker alloc] initWithData:encoded fileExtension:@"heics" preview:preview animated:YES];
					}
				}
			}
		}
	}

	// Animated PNG keeps soft, partly transparent edges, so try it next; GIF only has on/off transparency. Both need
	// far fewer frames to fit.
	NSUInteger baseStep = MAX(1, (cropped.count + kMaxPNGFrames - 1) / kMaxPNGFrames);
	BOOL (^attempt)(STKAnimationBudget, STKAnimationFormat) = ^BOOL(STKAnimationBudget budget, STKAnimationFormat format) {
		NSUInteger step = budget.step * baseStep;
		rendered = renderCanvas(budget.canvas, step);
		delay = frameDuration * step;
		data = STKEncodeAnimation(rendered, delay, format, 1);
		return data.length > 0 && data.length <= kMaxStickerBytes;
	};
	NSString *extension = @"png";
	BOOL fits = NO;
	for (size_t index = 0; !fits && index < sizeof(kAnimationBudgets) / sizeof(kAnimationBudgets[0]); index++) {
		fits = attempt(kAnimationBudgets[index], STKAnimationFormatPNG);
	}
	for (size_t index = 0; !fits && index < sizeof(kGIFBudgets) / sizeof(kGIFBudgets[0]); index++) {
		fits = attempt(kGIFBudgets[index], STKAnimationFormatGIF);
		extension = @"gif";
	}
	UIImage *preview = [UIImage animatedImageWithImages:rendered duration:delay * rendered.count];
	return [[STKRenderedSticker alloc] initWithData:data ?: [NSData data] fileExtension:extension preview:preview animated:YES];
}

@end
