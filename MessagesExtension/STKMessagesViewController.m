#import <Messages/Messages.h>
#import "STKCreatorFlow.h"
#import "STKStore.h"

// Each sticker is an MSStickerView, which gives Messages' native behavior: tap to add it to the message,
// or touch and hold, then drop it onto any bubble or photo in the transcript.
@interface STKStickerViewCell : UICollectionViewCell
@property (nonatomic, readonly) MSStickerView *stickerView;
@end

@implementation STKStickerViewCell

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_stickerView = [[MSStickerView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
		_stickerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:_stickerView];
	}
	return self;
}

@end

@interface STKAddStickerCell : UICollectionViewCell
@end

@implementation STKAddStickerCell

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		UIImageView *plus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium]]];
		plus.tintColor = UIColor.secondaryLabelColor;
		plus.contentMode = UIViewContentModeCenter;
		plus.frame = CGRectInset(self.contentView.bounds, 8, 8);
		plus.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		plus.backgroundColor = UIColor.tertiarySystemFillColor;
		plus.layer.cornerRadius = 16;
		plus.clipsToBounds = YES;
		[self.contentView addSubview:plus];
		self.isAccessibilityElement = YES;
		self.accessibilityLabel = @"Make Sticker";
	}
	return self;
}

- (void)setHighlighted:(BOOL)highlighted {
	[super setHighlighted:highlighted];
	self.contentView.alpha = highlighted ? 0.5 : 1;
}

@end

@interface STKMessagesViewController : MSMessagesAppViewController <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout>
@end

@implementation STKMessagesViewController {
	UICollectionView *_collectionView;
	NSArray<MSSticker *> *_stickers;
	NSMutableDictionary<NSURL *, MSSticker *> *_stickerCache;
	BOOL _creatorPending;
}

- (void)viewDidLoad {
	[super viewDidLoad];
	_stickerCache = [NSMutableDictionary dictionary];

	UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
	layout.minimumInteritemSpacing = 6;
	layout.minimumLineSpacing = 6;
	layout.sectionInset = UIEdgeInsetsMake(10, 12, 10, 12);
	_collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
	_collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_collectionView.backgroundColor = UIColor.clearColor;
	_collectionView.dataSource = self;
	_collectionView.delegate = self;
	[_collectionView registerClass:STKStickerViewCell.class forCellWithReuseIdentifier:@"Sticker"];
	[_collectionView registerClass:STKAddStickerCell.class forCellWithReuseIdentifier:@"Add"];
	[self.view addSubview:_collectionView];

	CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, STKMessagesLibraryChanged, (__bridge CFStringRef)STKLibraryChangedNotification, NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
	[self reloadStickers];
}

- (void)dealloc {
	CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}

static void STKMessagesLibraryChanged(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
	STKMessagesViewController *controller = (__bridge STKMessagesViewController *)observer;
	dispatch_async(dispatch_get_main_queue(), ^{
		[controller reloadStickers];
	});
}

- (void)willBecomeActiveWithConversation:(MSConversation *)conversation {
	[super willBecomeActiveWithConversation:conversation];
	[self reloadStickers];
}

- (void)reloadStickers {
	NSMutableArray<MSSticker *> *stickers = [NSMutableArray array];
	NSMutableDictionary<NSURL *, MSSticker *> *cache = [NSMutableDictionary dictionary];
	for (NSURL *url in [STKStore.sharedStore stickerURLs]) {
		MSSticker *sticker = _stickerCache[url];
		if (!sticker) {
			NSError *error = nil;
			sticker = [[MSSticker alloc] initWithContentsOfFileURL:url localizedDescription:@"Sticker" error:&error];
			if (!sticker) {
				NSLog(@"[Stickers] Skipping %@: %@", url.lastPathComponent, error);
				continue;
			}
		}
		cache[url] = sticker;
		[stickers addObject:sticker];
	}
	_stickerCache = cache;
	_stickers = stickers;
	[_collectionView reloadData];
}

#pragma mark - Making stickers

- (void)makeSticker {
	if (self.presentationStyle == MSMessagesAppPresentationStyleExpanded) {
		[self presentCreator];
		return;
	}
	// The photo picker and editor need the full-height app view.
	_creatorPending = YES;
	[self requestPresentationStyle:MSMessagesAppPresentationStyleExpanded];
}

- (void)didTransitionToPresentationStyle:(MSMessagesAppPresentationStyle)presentationStyle {
	[super didTransitionToPresentationStyle:presentationStyle];
	if (_creatorPending && presentationStyle == MSMessagesAppPresentationStyleExpanded) {
		_creatorPending = NO;
		[self presentCreator];
	}
}

- (void)presentCreator {
	[STKCreatorFlow presentPickerFromViewController:self completion:^(BOOL saved) {
		[self reloadStickers];
		[self requestPresentationStyle:MSMessagesAppPresentationStyleCompact];
	}];
}

#pragma mark - Collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
	return _stickers.count + 1;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.item == 0) {
		return [collectionView dequeueReusableCellWithReuseIdentifier:@"Add" forIndexPath:indexPath];
	}
	STKStickerViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Sticker" forIndexPath:indexPath];
	cell.stickerView.sticker = _stickers[indexPath.item - 1];
	return cell;
}

- (void)collectionView:(UICollectionView *)collectionView willDisplayCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
	if ([cell isKindOfClass:STKStickerViewCell.class]) {
		[((STKStickerViewCell *)cell).stickerView startAnimating];
	}
}

- (void)collectionView:(UICollectionView *)collectionView didEndDisplayingCell:(UICollectionViewCell *)cell forItemAtIndexPath:(NSIndexPath *)indexPath {
	if ([cell isKindOfClass:STKStickerViewCell.class]) {
		[((STKStickerViewCell *)cell).stickerView stopAnimating];
	}
}

- (BOOL)collectionView:(UICollectionView *)collectionView shouldSelectItemAtIndexPath:(NSIndexPath *)indexPath {
	// Sticker cells handle their own taps (MSStickerView); only the "+" tile is selectable.
	return indexPath.item == 0;
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
	[collectionView deselectItemAtIndexPath:indexPath animated:YES];
	[self makeSticker];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
	CGFloat available = collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right;
	NSInteger columns = MAX(3, (NSInteger)(available / 110));
	CGFloat side = floor((available - layout.minimumInteritemSpacing * (columns - 1)) / columns);
	return CGSizeMake(side, side);
}

@end
