#import "STKLibraryViewController.h"
#import "STKCreatorFlow.h"
#import "STKImageLoading.h"
#import "STKMediaSource.h"
#import "STKStore.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kCellIdentifier = @"Sticker";

@interface STKStickerCell : UICollectionViewCell
@property (nonatomic, readonly) UIImageView *imageView;
@property (nonatomic, copy) NSURL *url;
@end

@implementation STKStickerCell

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_imageView = [[UIImageView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
		_imageView.contentMode = UIViewContentModeScaleAspectFit;
		_imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:_imageView];
	}
	return self;
}

@end

@interface STKLibraryViewController () <UIDropInteractionDelegate, UICollectionViewDelegateFlowLayout>
@end

@implementation STKLibraryViewController {
	NSArray<NSURL *> *_stickers;
	NSCache<NSURL *, UIImage *> *_thumbnails;
	NSOperationQueue *_loadQueue;
	NSMutableSet<NSURL *> *_loading;
	UILabel *_emptyLabel;
}

- (instancetype)init {
	UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
	layout.minimumInteritemSpacing = 8;
	layout.minimumLineSpacing = 8;
	layout.sectionInset = UIEdgeInsetsMake(8, 16, 16, 16);
	if ((self = [super initWithCollectionViewLayout:layout])) {
		self.title = @"Stickers";
		_thumbnails = [NSCache new];
		_thumbnails.totalCostLimit = 128 * 1024 * 1024;
		// An uncached HEICS sticker takes most of a second to decode, so thumbnails load off the main thread.
		_loadQueue = [NSOperationQueue new];
		_loadQueue.maxConcurrentOperationCount = 3;
		_loadQueue.qualityOfService = NSQualityOfServiceUserInitiated;
		_loading = [NSMutableSet set];
	}
	return self;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	self.collectionView.backgroundColor = UIColor.systemBackgroundColor;
	self.collectionView.alwaysBounceVertical = YES;
	[self.collectionView registerClass:STKStickerCell.class forCellWithReuseIdentifier:kCellIdentifier];
	[self.collectionView addInteraction:[[UIDropInteraction alloc] initWithDelegate:self]];

	UIMenu *addMenu = [UIMenu menuWithChildren:@[
		[UIAction actionWithTitle:@"Choose Photo, Live Photo or GIF" image:[UIImage systemImageNamed:@"photo.on.rectangle"] identifier:nil handler:^(UIAction *action) {
			[self pickPhoto];
		}],
		[UIAction actionWithTitle:@"Paste Copied Subject" image:[UIImage systemImageNamed:@"doc.on.clipboard"] identifier:nil handler:^(UIAction *action) {
			[self pasteImage];
		}],
	]];
	self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"plus"] menu:addMenu];
	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"questionmark.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showHelp)];

	_emptyLabel = [UILabel new];
	_emptyLabel.text = @"No stickers yet.\n\nTap + to make one from a photo, Live Photo or GIF, or drag a subject you lifted in Photos into this window.";
	_emptyLabel.numberOfLines = 0;
	_emptyLabel.textAlignment = NSTextAlignmentCenter;
	_emptyLabel.textColor = UIColor.secondaryLabelColor;
	self.collectionView.backgroundView = _emptyLabel;

	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, STKLibraryChanged, (__bridge CFStringRef)STKLibraryChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	[self reload];
}

- (void)dealloc {
	CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}

static void STKLibraryChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
	STKLibraryViewController *controller = (__bridge STKLibraryViewController *)observer;
	dispatch_async(dispatch_get_main_queue(), ^{
		[controller reload];
	});
}

- (void)reload {
	_stickers = [STKStore.sharedStore stickerURLs];
	_emptyLabel.hidden = _stickers.count > 0;
	[self.collectionView reloadData];
}

#pragma mark - Adding stickers

- (void)pickPhoto {
	[STKCreatorFlow presentPickerFromViewController:self completion:^(BOOL saved) {
		[self reload];
	}];
}

- (void)pasteImage {
	// In Photos, touch and hold the subject of a photo and choose Copy; it lands on the pasteboard with transparency.
	UIPasteboard *pasteboard = UIPasteboard.generalPasteboard;
	STKMediaSource *source = nil;
	for (NSString *type in @[UTTypeGIF.identifier, UTTypePNG.identifier]) {
		NSData *data = [pasteboard dataForPasteboardType:type];
		if (data && (source = [STKMediaSource sourceWithImageData:data])) {
			break;
		}
	}
	if (!source && pasteboard.image) {
		source = [STKMediaSource sourceWithImage:pasteboard.image alreadyCutOut:YES];
	}
	if (!source) {
		[self showAlertWithTitle:@"Nothing to Paste" message:@"In Photos, touch and hold the subject of a photo, choose Copy, then come back and paste."];
		return;
	}
	[self presentPreviewForSource:source];
}

- (void)presentPreviewForSource:(STKMediaSource *)source {
	[STKCreatorFlow presentPreviewForSource:source fromViewController:self completion:^(BOOL saved) {
		[self reload];
	}];
}

#pragma mark - Drop (drag a lifted subject in from Photos)

- (BOOL)dropInteraction:(UIDropInteraction *)interaction canHandleSession:(id<UIDropSession>)session {
	return [session hasItemsConformingToTypeIdentifiers:@[UTTypeImage.identifier, UTTypeMovie.identifier]];
}

- (UIDropProposal *)dropInteraction:(UIDropInteraction *)interaction sessionDidUpdate:(id<UIDropSession>)session {
	return [[UIDropProposal alloc] initWithDropOperation:UIDropOperationCopy];
}

- (void)dropInteraction:(UIDropInteraction *)interaction performDrop:(id<UIDropSession>)session {
	NSItemProvider *provider = session.items.firstObject.itemProvider;
	if (!provider) {
		return;
	}
	[STKMediaSource loadFromItemProvider:provider completion:^(STKMediaSource *source, NSError *error) {
		if (source) {
			[self presentPreviewForSource:source];
		} else {
			[self showAlertWithTitle:@"Couldn't Load Photo" message:error.localizedDescription];
		}
	}];
}

#pragma mark - Collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
	return _stickers.count;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
	STKStickerCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:kCellIdentifier forIndexPath:indexPath];
	NSURL *url = _stickers[indexPath.item];
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
		UIImage *image = STKLoadStickerImage(url, 300);
		dispatch_async(dispatch_get_main_queue(), ^{
			[self->_loading removeObject:url];
			if (!image) {
				return;
			}
			[self->_thumbnails setObject:image forKey:url cost:STKImageCost(image)];
			for (STKStickerCell *cell in self.collectionView.visibleCells) {
				if ([cell.url isEqual:url]) {
					cell.imageView.image = image;
				}
			}
		});
	}];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
	CGFloat available = collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right;
	NSInteger columns = MAX(3, (NSInteger)(available / 110));
	CGFloat side = floor((available - layout.minimumInteritemSpacing * (columns - 1)) / columns);
	return CGSizeMake(side, side);
}

- (UIContextMenuConfiguration *)collectionView:(UICollectionView *)collectionView contextMenuConfigurationForItemAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
	NSURL *url = _stickers[indexPath.item];
	return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggested) {
		UIAction *copy = [UIAction actionWithTitle:@"Copy" image:[UIImage systemImageNamed:@"doc.on.doc"] identifier:nil handler:^(UIAction *action) {
			NSString *type = nil;
			NSData *data = STKPasteableStickerData(url, &type);
			if (data) {
				[UIPasteboard.generalPasteboard setData:data forPasteboardType:type];
			}
		}];
		UIAction *delete = [UIAction actionWithTitle:@"Delete" image:[UIImage systemImageNamed:@"trash"] identifier:nil handler:^(UIAction *action) {
			[STKStore.sharedStore removeStickerAtURL:url error:nil];
			[self reload];
		}];
		delete.attributes = UIMenuElementAttributesDestructive;
		return [UIMenu menuWithChildren:@[copy, delete]];
	}];
}

#pragma mark - Help

- (void)showHelp {
	[self showAlertWithTitle:@"Using Your Stickers" message:
		@"Keyboard: switch to the emoji keyboard and tap the sticker icon at the left of the category bar. Tap a sticker to insert it, or touch and hold it and drag it onto a message bubble. Tap + there to make a new sticker without leaving the app.\n\n"
		@"iMessage: open the Stickers app in the Messages app row to browse, peel and drag your stickers, or tap + to make one."];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

@end
