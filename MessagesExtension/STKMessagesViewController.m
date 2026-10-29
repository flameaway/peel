#import <Messages/Messages.h>
#import "STKCreatorFlow.h"
#import "STKStore.h"

// Each sticker is an MSStickerView, which gives Messages' native behavior: tap to add it to the message,
// or touch and hold, then drop it onto any bubble or photo in the transcript. In edit mode the stickers jiggle
// and show a delete badge instead.
@interface STKStickerViewCell : UICollectionViewCell
@property (nonatomic, readonly) MSStickerView *stickerView;
@property (nonatomic, copy) void (^onDelete)(void);
// Not setEditing:, which UICollectionViewCell already has: the collection view calls that with its own editing
// state (always NO here), which would hide the delete badges again right away.
- (void)setDeleting:(BOOL)deleting;
@end

@implementation STKStickerViewCell {
	UIButton *_deleteButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		_stickerView = [[MSStickerView alloc] initWithFrame:CGRectInset(self.contentView.bounds, 4, 4)];
		_stickerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:_stickerView];

		UIImageSymbolConfiguration *symbol = [[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold]
			configurationByApplyingConfiguration:[UIImageSymbolConfiguration configurationWithPaletteColors:@[UIColor.whiteColor, UIColor.systemRedColor]]];
		_deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
		[_deleteButton setImage:[UIImage systemImageNamed:@"minus.circle.fill" withConfiguration:symbol] forState:UIControlStateNormal];
		_deleteButton.frame = CGRectMake(-4, -4, 36, 36);
		_deleteButton.accessibilityLabel = @"Delete Sticker";
		_deleteButton.hidden = YES;
		[_deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
		[self.contentView addSubview:_deleteButton];
	}
	return self;
}

- (void)deleteTapped {
	if (self.onDelete) {
		self.onDelete();
	}
}

- (void)setDeleting:(BOOL)deleting {
	_deleteButton.hidden = !deleting;
	_stickerView.userInteractionEnabled = !deleting;
	if (!deleting) {
		[self.contentView.layer removeAnimationForKey:@"jiggle"];
		return;
	}
	if (![self.contentView.layer animationForKey:@"jiggle"]) {
		CAKeyframeAnimation *jiggle = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
		jiggle.values = @[@(-0.035), @0.035, @(-0.035)];
		jiggle.duration = 0.28;
		jiggle.repeatCount = HUGE_VALF;
		// Out of step with the neighbours, like the home screen.
		jiggle.timeOffset = arc4random_uniform(280) / 1000.0;
		[self.contentView.layer addAnimation:jiggle forKey:@"jiggle"];
	}
}

- (void)prepareForReuse {
	[super prepareForReuse];
	self.onDelete = nil;
	[self setDeleting:NO];
}

@end

// The "+" (make a sticker) and Edit/Done tiles in front of the stickers.
@interface STKAddStickerCell : UICollectionViewCell
- (void)setSymbolName:(NSString *)name accessibilityLabel:(NSString *)label;
@end

@implementation STKAddStickerCell {
	UIImageView *_plus;
}

- (void)setSymbolName:(NSString *)name accessibilityLabel:(NSString *)label {
	_plus.image = [UIImage systemImageNamed:name withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium]];
	self.accessibilityLabel = label;
}

- (instancetype)initWithFrame:(CGRect)frame {
	if ((self = [super initWithFrame:frame])) {
		UIImageView *plus = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium]]];
		_plus = plus;
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
	NSArray<NSURL *> *_stickerURLs;
	BOOL _editing;
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
	// Stickers made before the library moved out of the app group (the app that used to do this is gone).
	[STKStore.sharedStore migrateFromAppGroup];
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
	NSMutableArray<NSURL *> *urls = [NSMutableArray array];
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
		[urls addObject:url];
	}
	_stickerCache = cache;
	_stickers = stickers;
	_stickerURLs = urls;
	if (!stickers.count) {
		_editing = NO;
	}
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

#pragma mark - Editing

// "+" and, once there are stickers, Edit come before the stickers.
- (NSInteger)leadingTiles {
	return _stickers.count ? 2 : 1;
}

- (void)setEditingStickers:(BOOL)editing {
	_editing = editing;
	[_collectionView reloadData];
}

- (void)deleteStickerAtURL:(NSURL *)url {
	NSUInteger index = [_stickerURLs indexOfObject:url];
	if (index == NSNotFound) {
		return;
	}
	[STKStore.sharedStore removeStickerAtURL:url error:nil];
	NSMutableArray *stickers = [_stickers mutableCopy], *urls = [_stickerURLs mutableCopy];
	[stickers removeObjectAtIndex:index];
	[urls removeObjectAtIndex:index];
	_stickers = stickers;
	_stickerURLs = urls;
	[_stickerCache removeObjectForKey:url];
	if (!stickers.count) {
		[self setEditingStickers:NO];
		return;
	}
	[_collectionView deleteItemsAtIndexPaths:@[[NSIndexPath indexPathForItem:index + [self leadingTiles] inSection:0]]];
}

#pragma mark - Collection view

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
	return _stickers.count + [self leadingTiles];
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
	if (indexPath.item < [self leadingTiles]) {
		STKAddStickerCell *tile = [collectionView dequeueReusableCellWithReuseIdentifier:@"Add" forIndexPath:indexPath];
		if (indexPath.item == 0) {
			[tile setSymbolName:@"plus" accessibilityLabel:@"Make Sticker"];
		} else {
			[tile setSymbolName:_editing ? @"checkmark" : @"pencil" accessibilityLabel:_editing ? @"Done" : @"Edit Stickers"];
		}
		return tile;
	}
	STKStickerViewCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"Sticker" forIndexPath:indexPath];
	cell.stickerView.sticker = _stickers[indexPath.item - [self leadingTiles]];
	NSURL *url = _stickerURLs[indexPath.item - [self leadingTiles]];
	__weak typeof(self) weakSelf = self;
	cell.onDelete = ^{
		[weakSelf deleteStickerAtURL:url];
	};
	[cell setDeleting:_editing];
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
	// Sticker cells handle their own taps (MSStickerView); only the tiles in front are selectable.
	return indexPath.item < [self leadingTiles];
}

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
	[collectionView deselectItemAtIndexPath:indexPath animated:YES];
	if (indexPath.item == 1) {
		[self setEditingStickers:!_editing];
		return;
	}
	[self setEditingStickers:NO];
	[self makeSticker];
}

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewFlowLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
	CGFloat available = collectionView.bounds.size.width - layout.sectionInset.left - layout.sectionInset.right;
	NSInteger columns = MAX(3, (NSInteger)(available / 110));
	CGFloat side = floor((available - layout.minimumInteritemSpacing * (columns - 1)) / columns);
	return CGSizeMake(side, side);
}

@end
