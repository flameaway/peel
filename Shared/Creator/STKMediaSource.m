#import "STKMediaSource.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSTimeInterval kMaxDuration = 3.0;
// Frames are kept at the source's own rate up to this; the sticker maker lets you pick a lower one.
static const double kMaxFrameRate = 60;
static const NSUInteger kMaxFrames = 180;
// Stickers are at most 400 pixels across; this leaves room to crop in while keeping the frames in memory reasonable.
static const CGFloat kMaxFrameSide = 540;
static const CGFloat kMaxHighRateFrameSide = 420;

// Over 90 frames (3 s above 30 fps), keep each frame smaller.
static CGFloat STKFrameSide(NSUInteger frameCount) {
	return frameCount > 90 ? kMaxHighRateFrameSide : kMaxFrameSide;
}

static NSError *STKLoadError(NSString *message) {
	return [NSError errorWithDomain:@"com.josh.stickers" code:3 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation STKMediaSource

- (instancetype)initWithStill:(UIImage *)still frames:(NSArray<UIImage *> *)frames frameDuration:(NSTimeInterval)frameDuration alreadyCutOut:(BOOL)alreadyCutOut {
	if ((self = [super init])) {
		_still = still;
		_frames = frames.count > 1 ? frames : @[];
		_frameDuration = frameDuration;
		_alreadyCutOut = alreadyCutOut;
	}
	return self;
}

- (BOOL)isAnimated {
	return _frames.count > 1;
}

+ (instancetype)sourceWithImage:(UIImage *)image alreadyCutOut:(BOOL)alreadyCutOut {
	return [[self alloc] initWithStill:image frames:@[] frameDuration:0 alreadyCutOut:alreadyCutOut];
}

static BOOL STKHasTransparency(CGImageRef image) {
	CGImageAlphaInfo alpha = CGImageGetAlphaInfo(image);
	return alpha != kCGImageAlphaNone && alpha != kCGImageAlphaNoneSkipFirst && alpha != kCGImageAlphaNoneSkipLast;
}

+ (instancetype)sourceWithImageData:(NSData *)data {
	CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
	if (!source) {
		return nil;
	}
	size_t count = CGImageSourceGetCount(source);
	if (count <= 1) {
		CFRelease(source);
		UIImage *image = [UIImage imageWithData:data];
		return image ? [self sourceWithImage:image alreadyCutOut:STKHasTransparency(image.CGImage)] : nil;
	}

	// Resample to at most kMaxFrames evenly timed frames within kMaxDuration.
	NSMutableArray<NSNumber *> *delays = [NSMutableArray arrayWithCapacity:count];
	NSTimeInterval total = 0;
	for (size_t index = 0; index < count; index++) {
		NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
		NSDictionary *gif = properties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
		NSDictionary *png = properties[(__bridge NSString *)kCGImagePropertyPNGDictionary];
		NSNumber *delay = gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime]
			?: png[(__bridge NSString *)kCGImagePropertyAPNGUnclampedDelayTime] ?: png[(__bridge NSString *)kCGImagePropertyAPNGDelayTime];
		NSTimeInterval seconds = delay.doubleValue > 0.01 ? delay.doubleValue : 0.1;
		[delays addObject:@(seconds)];
		total += seconds;
	}
	NSTimeInterval clip = MIN(total, kMaxDuration);
	// As many frames as the source has (up to 60 fps), but no more.
	NSTimeInterval sourceFrameDuration = MAX(1 / kMaxFrameRate, total / count);
	NSUInteger frameCount = MIN(kMaxFrames, MAX(2, (NSUInteger)round(clip / sourceFrameDuration)));
	NSTimeInterval frameDuration = clip / frameCount;
	NSDictionary *options = @{
		(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
		(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(STKFrameSide(frameCount)),
		(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
	};
	NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:frameCount];
	size_t sourceIndex = 0;
	NSTimeInterval sourceEnd = delays.firstObject.doubleValue;
	for (NSUInteger index = 0; index < frameCount; index++) {
		NSTimeInterval time = index * frameDuration;
		while (time >= sourceEnd && sourceIndex + 1 < count) {
			sourceIndex++;
			sourceEnd += delays[sourceIndex].doubleValue;
		}
		CGImageRef frame = CGImageSourceCreateThumbnailAtIndex(source, sourceIndex, (__bridge CFDictionaryRef)options);
		if (frame) {
			[frames addObject:[UIImage imageWithCGImage:frame]];
			CGImageRelease(frame);
		}
	}
	CFRelease(source);
	if (frames.count == 0) {
		return nil;
	}
	return [[self alloc] initWithStill:frames.firstObject frames:frames frameDuration:frameDuration alreadyCutOut:STKHasTransparency(frames.firstObject.CGImage)];
}

// Samples up to kMaxFrames evenly from the middle kMaxDuration seconds of a video.
+ (instancetype)sourceWithVideoAtURL:(NSURL *)url still:(UIImage *)still {
	AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
	NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
	if (!(duration > 0)) {
		return still ? [self sourceWithImage:still alreadyCutOut:NO] : nil;
	}
	NSTimeInterval clip = MIN(duration, kMaxDuration);
	NSTimeInterval start = (duration - clip) / 2;
	float nominalRate = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject.nominalFrameRate;
	double frameRate = nominalRate > 1 ? MIN(kMaxFrameRate, nominalRate) : kMaxFrameRate;
	NSUInteger frameCount = MIN(kMaxFrames, MAX(2, (NSUInteger)round(clip * frameRate)));
	NSTimeInterval frameDuration = clip / frameCount;

	AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
	generator.appliesPreferredTrackTransform = YES;
	generator.maximumSize = CGSizeMake(STKFrameSide(frameCount), STKFrameSide(frameCount));
	generator.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(frameDuration / 2, 600);
	generator.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(frameDuration / 2, 600);
	// One batch request decodes forward through the video; asking frame by frame seeks back to a keyframe each time.
	NSMutableArray *times = [NSMutableArray arrayWithCapacity:frameCount];
	for (NSUInteger index = 0; index < frameCount; index++) {
		[times addObject:[NSValue valueWithCMTime:CMTimeMakeWithSeconds(start + index * frameDuration, 6000)]];
	}
	NSMutableArray *slots = [NSMutableArray arrayWithCapacity:frameCount];
	for (NSUInteger index = 0; index < frameCount; index++) {
		[slots addObject:NSNull.null];
	}
	dispatch_semaphore_t finished = dispatch_semaphore_create(0);
	__block NSUInteger remaining = frameCount;
	NSObject *lock = [NSObject new];
	[generator generateCGImagesAsynchronouslyForTimes:times completionHandler:^(CMTime requested, CGImageRef image, CMTime actual, AVAssetImageGeneratorResult result, NSError *error) {
		NSUInteger index = (NSUInteger)MAX(0, round((CMTimeGetSeconds(requested) - start) / frameDuration));
		@synchronized (lock) {
			if (image && result == AVAssetImageGeneratorSucceeded && index < frameCount) {
				slots[index] = [UIImage imageWithCGImage:image];
			}
			if (--remaining == 0) {
				dispatch_semaphore_signal(finished);
			}
		}
	}];
	if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))) != 0) {
		[generator cancelAllCGImageGeneration];
	}
	// Fill any frame that failed to decode with the one before it, so the timing stays even.
	NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:frameCount];
	@synchronized (lock) {
		UIImage *last = nil;
		for (id slot in slots) {
			last = slot != NSNull.null ? slot : last;
			if (last) {
				[frames addObject:last];
			}
		}
	}
	if (frames.count < 2) {
		return still || frames.count ? [self sourceWithImage:still ?: frames.firstObject alreadyCutOut:NO] : nil;
	}
	return [[self alloc] initWithStill:still ?: frames[frames.count / 2] frames:frames frameDuration:frameDuration alreadyCutOut:NO];
}

+ (void)loadFromItemProvider:(NSItemProvider *)provider completion:(void (^)(STKMediaSource *, NSError *))completion {
	void (^finish)(STKMediaSource *, NSError *) = ^(STKMediaSource *source, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(source, source ? nil : (error ?: STKLoadError(@"The photo couldn't be read.")));
		});
	};
	NSArray<NSString *> *types = provider.registeredTypeIdentifiers;
	BOOL (^conforms)(UTType *) = ^BOOL(UTType *type) {
		for (NSString *identifier in types) {
			if ([[UTType typeWithIdentifier:identifier] conformsToType:type]) {
				return YES;
			}
		}
		return NO;
	};

	if (conforms(UTTypeGIF)) {
		[provider loadDataRepresentationForTypeIdentifier:UTTypeGIF.identifier completionHandler:^(NSData *data, NSError *error) {
			finish(data ? [self sourceWithImageData:data] : nil, error);
		}];
		return;
	}

	if ([provider canLoadObjectOfClass:PHLivePhoto.class]) {
		[self loadLivePhotoFromProvider:provider completion:finish];
		return;
	}

	if (conforms(UTTypeMovie)) {
		[provider loadFileRepresentationForTypeIdentifier:UTTypeMovie.identifier completionHandler:^(NSURL *url, NSError *error) {
			// The file is deleted when this handler returns, so read the frames now.
			finish(url ? [self sourceWithVideoAtURL:url still:nil] : nil, error);
		}];
		return;
	}

	if (conforms(UTTypePNG)) {
		// Keep animated PNGs animated (and transparent PNGs transparent).
		[provider loadDataRepresentationForTypeIdentifier:UTTypePNG.identifier completionHandler:^(NSData *data, NSError *error) {
			finish(data ? [self sourceWithImageData:data] : nil, error);
		}];
		return;
	}

	[self loadStillFromProvider:provider completion:^(UIImage *image, NSError *error) {
		finish(image ? [self sourceWithImage:image alreadyCutOut:STKHasTransparency(image.CGImage)] : nil, error);
	}];
}

+ (void)loadStillFromProvider:(NSItemProvider *)provider completion:(void (^)(UIImage *, NSError *))completion {
	void (^fromData)(void) = ^{
		[provider loadDataRepresentationForTypeIdentifier:UTTypeImage.identifier completionHandler:^(NSData *data, NSError *error) {
			UIImage *image = data ? [UIImage imageWithData:data] : nil;
			completion(image, error);
		}];
	};
	if (![provider canLoadObjectOfClass:UIImage.class]) {
		fromData();
		return;
	}
	[provider loadObjectOfClass:UIImage.class completionHandler:^(UIImage *image, NSError *error) {
		if (image) {
			completion(image, nil);
		} else {
			fromData();
		}
	}];
}

+ (void)loadLivePhotoFromProvider:(NSItemProvider *)provider completion:(void (^)(STKMediaSource *, NSError *))completion {
	[self loadStillFromProvider:provider completion:^(UIImage *still, NSError *stillError) {
		[provider loadObjectOfClass:PHLivePhoto.class completionHandler:^(PHLivePhoto *livePhoto, NSError *error) {
			[self loadLivePhoto:livePhoto still:still error:error ?: stillError completion:completion];
		}];
	}];
}

+ (void)loadLivePhotoAsset:(PHAsset *)asset completion:(void (^)(STKMediaSource *_Nullable, NSError *_Nullable))completion {
	void (^finish)(STKMediaSource *, NSError *) = ^(STKMediaSource *source, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(source, source ? nil : (error ?: STKLoadError(@"The Live Photo couldn't be read.")));
		});
	};
	PHImageRequestOptions *stillOptions = [PHImageRequestOptions new];
	stillOptions.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
	stillOptions.networkAccessAllowed = YES;
	// Sticker frames are much smaller than this; it's only for the Still option and cropping.
	CGSize stillSize = CGSizeMake(2048, 2048);
	[PHImageManager.defaultManager requestImageForAsset:asset targetSize:stillSize contentMode:PHImageContentModeAspectFit options:stillOptions resultHandler:^(UIImage *still, NSDictionary *info) {
		PHLivePhotoRequestOptions *options = [PHLivePhotoRequestOptions new];
		options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
		options.networkAccessAllowed = YES;
		[PHImageManager.defaultManager requestLivePhotoForAsset:asset targetSize:PHImageManagerMaximumSize contentMode:PHImageContentModeDefault options:options resultHandler:^(PHLivePhoto *livePhoto, NSDictionary *livePhotoInfo) {
			// High quality is delivered once, but skip a degraded result just in case.
			if ([livePhotoInfo[PHImageResultIsDegradedKey] boolValue]) {
				return;
			}
			[self loadLivePhoto:livePhoto still:still error:livePhotoInfo[PHImageErrorKey] ?: info[PHImageErrorKey] completion:finish];
		}];
	}];
}

+ (void)loadLivePhoto:(PHLivePhoto *)livePhoto completion:(void (^)(STKMediaSource *_Nullable, NSError *_Nullable))completion {
	[self loadLivePhoto:livePhoto still:nil error:nil completion:^(STKMediaSource *source, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			completion(source, source ? nil : (error ?: STKLoadError(@"The Live Photo couldn't be read.")));
		});
	}];
}

+ (void)loadLivePhoto:(PHLivePhoto *)livePhoto still:(UIImage *)still error:(NSError *)error completion:(void (^)(STKMediaSource *, NSError *))completion {
	PHAssetResource *video = nil;
	for (PHAssetResource *resource in livePhoto ? [PHAssetResource assetResourcesForLivePhoto:livePhoto] : @[]) {
		// The full-size one has the user's edits (trim, key photo), when there are any.
		if (resource.type == PHAssetResourceTypeFullSizePairedVideo || (resource.type == PHAssetResourceTypePairedVideo && !video)) {
			video = resource;
		}
	}
	if (!video) {
		// Fall back to the still part of the Live Photo.
		completion(still ? [self sourceWithImage:still alreadyCutOut:NO] : nil, error);
		return;
	}
	NSURL *file = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mov"]];
	PHAssetResourceRequestOptions *options = [PHAssetResourceRequestOptions new];
	options.networkAccessAllowed = YES;
	[PHAssetResourceManager.defaultManager writeDataForAssetResource:video toFile:file options:options completionHandler:^(NSError *writeError) {
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			STKMediaSource *source = writeError ? nil : [self sourceWithVideoAtURL:file still:still];
			[NSFileManager.defaultManager removeItemAtURL:file error:nil];
			if (!source && still) {
				source = [self sourceWithImage:still alreadyCutOut:NO];
			}
			completion(source, writeError);
		});
	}];
}

@end
