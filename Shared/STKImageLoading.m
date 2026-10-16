#import "STKImageLoading.h"
#import "STKStore.h"
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const NSUInteger kMaxLoadedFrames = 30;
static const CGFloat kPasteGIFSide = 320;
static const NSUInteger kMaxPasteGIFFrames = 45;

static NSTimeInterval STKFrameDelay(CGImageSourceRef source, size_t index) {
	NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, index, NULL));
	NSDictionary *png = properties[(__bridge NSString *)kCGImagePropertyPNGDictionary];
	NSDictionary *gif = properties[(__bridge NSString *)kCGImagePropertyGIFDictionary];
	NSDictionary *heics = properties[(__bridge NSString *)kCGImagePropertyHEICSDictionary];
	NSNumber *delay = png[(__bridge NSString *)kCGImagePropertyAPNGUnclampedDelayTime] ?: png[(__bridge NSString *)kCGImagePropertyAPNGDelayTime]
		?: gif[(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime] ?: gif[(__bridge NSString *)kCGImagePropertyGIFDelayTime]
		?: heics[(__bridge NSString *)kCGImagePropertyHEICSUnclampedDelayTime] ?: heics[(__bridge NSString *)kCGImagePropertyHEICSDelayTime];
	return delay.doubleValue > 0.01 ? delay.doubleValue : 0.1;
}

// Decodes every step-th frame no larger than maxSide; each frame's delay covers the frames it stands in for.
static NSArray<UIImage *> *STKDecodeFrames(CGImageSourceRef source, CGFloat maxSide, NSUInteger maxFrames, NSMutableArray<NSNumber *> *delays) {
	NSDictionary *options = @{
		(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
		(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxSide),
		(__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
	};
	size_t count = CGImageSourceGetCount(source);
	size_t step = MAX(1, (count + maxFrames - 1) / maxFrames);
	NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:count / step + 1];
	for (size_t index = 0; index < count; index += step) {
		@autoreleasepool {
			CGImageRef frame = CGImageSourceCreateThumbnailAtIndex(source, index, (__bridge CFDictionaryRef)options);
			if (!frame) {
				continue;
			}
			[frames addObject:[UIImage imageWithCGImage:frame]];
			CGImageRelease(frame);
			NSTimeInterval delay = 0;
			for (size_t covered = index; count > 1 && covered < MIN(count, index + step); covered++) {
				delay += STKFrameDelay(source, covered);
			}
			[delays addObject:@(delay)];
		}
	}
	return frames;
}

static UIImage *STKDecodeImage(NSURL *url, CGFloat maxSide, NSArray<UIImage *> **framesOut, NSArray<NSNumber *> **delaysOut) {
	CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
	if (!source) {
		return nil;
	}
	NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
	NSArray<UIImage *> *frames = STKDecodeFrames(source, maxSide, kMaxLoadedFrames, delays);
	CFRelease(source);
	if (framesOut) {
		*framesOut = frames;
		*delaysOut = delays;
	}
	if (frames.count > 1) {
		return [UIImage animatedImageWithImages:frames duration:[[delays valueForKeyPath:@"@sum.self"] doubleValue]];
	}
	return frames.firstObject;
}

static NSURL *STKThumbnailCacheURL(NSURL *url, CGFloat maxSide) {
	NSURL *directory = [url.URLByDeletingLastPathComponent URLByAppendingPathComponent:STKThumbnailCacheDirectoryName isDirectory:YES];
	NSString *name = [NSString stringWithFormat:@"%@@%.0f.png", url.lastPathComponent.stringByDeletingPathExtension, maxSide];
	return [directory URLByAppendingPathComponent:name];
}

static void STKWriteAnimatedPNG(NSArray<UIImage *> *frames, NSArray<NSNumber *> *delays, NSURL *destinationURL) {
	[NSFileManager.defaultManager createDirectoryAtURL:destinationURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
	NSURL *temporary = [destinationURL URLByAppendingPathExtension:NSUUID.UUID.UUIDString];
	CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)temporary, (__bridge CFStringRef)UTTypePNG.identifier, frames.count, NULL);
	if (!destination) {
		return;
	}
	CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImagePropertyPNGDictionary: @{(__bridge NSString *)kCGImagePropertyAPNGLoopCount: @0}});
	for (NSUInteger index = 0; index < frames.count; index++) {
		NSDictionary *properties = @{(__bridge NSString *)kCGImagePropertyPNGDictionary: @{
			(__bridge NSString *)kCGImagePropertyAPNGDelayTime: delays[index],
			(__bridge NSString *)kCGImagePropertyAPNGUnclampedDelayTime: delays[index],
		}};
		CGImageDestinationAddImage(destination, frames[index].CGImage, (__bridge CFDictionaryRef)properties);
	}
	BOOL ok = CGImageDestinationFinalize(destination);
	CFRelease(destination);
	// Written aside and moved into place, so another process never reads half a file.
	if (!ok || rename(temporary.fileSystemRepresentation, destinationURL.fileSystemRepresentation) != 0) {
		[NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
	}
}

UIImage *STKLoadStickerImage(NSURL *url, CGFloat maxSide) {
	if (![url.pathExtension.lowercaseString isEqualToString:@"heics"]) {
		return STKDecodeImage(url, maxSide, NULL, NULL);
	}
	// Every HEICS frame is decoded from the ones before it, about 25 ms each even when scaled down, so the first load
	// keeps an animated PNG copy (a few ms a frame) for every later one.
	NSURL *cache = STKThumbnailCacheURL(url, maxSide);
	UIImage *cached = [NSFileManager.defaultManager fileExistsAtPath:cache.path] ? STKDecodeImage(cache, maxSide, NULL, NULL) : nil;
	if (cached) {
		return cached;
	}
	NSArray<UIImage *> *frames = nil;
	NSArray<NSNumber *> *delays = nil;
	UIImage *image = STKDecodeImage(url, maxSide, &frames, &delays);
	if (frames.count > 1) {
		STKWriteAnimatedPNG(frames, delays, cache);
	}
	return image;
}

NSUInteger STKImageCost(UIImage *image) {
	NSUInteger frames = MAX(1, image.images.count);
	CGImageRef first = image.images.firstObject.CGImage ?: image.CGImage;
	return frames * CGImageGetBytesPerRow(first) * CGImageGetHeight(first);
}

NSData *STKPasteableStickerData(NSURL *url, NSString **typeIdentifier) {
	NSString *extension = url.pathExtension.lowercaseString;
	if (![extension isEqualToString:@"heics"]) {
		*typeIdentifier = [extension isEqualToString:@"gif"] ? UTTypeGIF.identifier : UTTypePNG.identifier;
		return [NSData dataWithContentsOfURL:url];
	}
	CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
	if (!source) {
		return nil;
	}
	NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
	NSArray<UIImage *> *frames = STKDecodeFrames(source, kPasteGIFSide, kMaxPasteGIFFrames, delays);
	CFRelease(source);
	if (frames.count == 0) {
		return nil;
	}
	NSMutableData *data = [NSMutableData data];
	CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, (__bridge CFStringRef)UTTypeGIF.identifier, frames.count, NULL);
	if (!destination) {
		return nil;
	}
	CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImagePropertyGIFDictionary: @{(__bridge NSString *)kCGImagePropertyGIFLoopCount: @0}});
	for (NSUInteger index = 0; index < frames.count; index++) {
		NSDictionary *properties = @{(__bridge NSString *)kCGImagePropertyGIFDictionary: @{
			(__bridge NSString *)kCGImagePropertyGIFDelayTime: delays[index],
			(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime: delays[index],
		}};
		CGImageDestinationAddImage(destination, frames[index].CGImage, (__bridge CFDictionaryRef)properties);
	}
	BOOL ok = CGImageDestinationFinalize(destination);
	CFRelease(destination);
	*typeIdentifier = UTTypeGIF.identifier;
	return ok ? data : nil;
}

static NSData *STKHEICSFromFrames(NSArray<UIImage *> *frames, NSArray<NSNumber *> *delays) {
	NSMutableData *data = [NSMutableData data];
	CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, CFSTR("public.heics"), frames.count, NULL);
	if (!destination) {
		return nil;
	}
	CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImagePropertyHEICSDictionary: @{(__bridge NSString *)kCGImagePropertyHEICSLoopCount: @0}});
	for (NSUInteger index = 0; index < frames.count; index++) {
		NSDictionary *properties = @{
			(__bridge NSString *)kCGImagePropertyHEICSDictionary: @{
				(__bridge NSString *)kCGImagePropertyHEICSDelayTime: delays[index],
				(__bridge NSString *)kCGImagePropertyHEICSUnclampedDelayTime: delays[index],
			},
			(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.8,
		};
		CGImageDestinationAddImage(destination, frames[index].CGImage, (__bridge CFDictionaryRef)properties);
	}
	BOOL ok = CGImageDestinationFinalize(destination);
	CFRelease(destination);
	return ok ? data : nil;
}

NSArray<NSDictionary<NSString *, id> *> *STKTelegramPasteboardItems(NSURL *url) {
	NSData *file = [NSData dataWithContentsOfURL:url];
	CGImageSourceRef source = file ? CGImageSourceCreateWithData((__bridge CFDataRef)file, NULL) : NULL;
	if (!source) {
		return nil;
	}
	size_t count = CGImageSourceGetCount(source);
	NSArray<NSDictionary *> *items = nil;
	if ([url.pathExtension.lowercaseString isEqualToString:@"heics"]) {
		items = @[@{@"public.heics": file}];
	} else if (count > 1) {
		// Telegram's sticker export is 512 pixels and 30 fps at most.
		NSMutableArray<NSNumber *> *delays = [NSMutableArray array];
		NSArray<UIImage *> *frames = STKDecodeFrames(source, 512, 90, delays);
		NSData *heics = frames.count > 1 ? STKHEICSFromFrames(frames, delays) : nil;
		items = heics ? @[@{@"public.heics": heics}] : nil;
	} else {
		items = @[@{@"com.apple.png-sticker": file, UTTypePNG.identifier: file}];
	}
	CFRelease(source);
	return items;
}
