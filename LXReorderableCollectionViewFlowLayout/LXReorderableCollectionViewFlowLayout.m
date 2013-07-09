//
//  LXReorderableCollectionViewFlowLayout.m
//
//  Created by Stan Chang Khin Boon on 1/10/12.
//  Copyright (c) 2012 d--buzz. All rights reserved.
//

#import "LXReorderableCollectionViewFlowLayout.h"
#import <QuartzCore/QuartzCore.h>

#define LX_FRAMES_PER_SECOND 60.0

static const CGFloat kPinchMinScale = 1.0f;
static const CGFloat kPinchMaxScale = 4.0f;

#ifndef CGGEOMETRY_LXSUPPORT_H_
CG_INLINE CGPoint
LXS_CGPointAdd(CGPoint point1, CGPoint point2) {
    return CGPointMake(point1.x + point2.x, point1.y + point2.y);
}
#endif

typedef NS_ENUM(NSInteger, LXScrollingDirection) {
    LXScrollingDirectionUnknown = 0,
    LXScrollingDirectionUp,
    LXScrollingDirectionDown,
    LXScrollingDirectionLeft,
    LXScrollingDirectionRight
};

static NSString * const kLXScrollingDirectionKey = @"LXScrollingDirection";
static NSString * const kLXCollectionViewKeyPath = @"collectionView";

@interface UICollectionViewCell (LXReorderableCollectionViewFlowLayout)

- (UIImage *)LX_rasterizedImage;

@end

@implementation UICollectionViewCell (LXReorderableCollectionViewFlowLayout)

- (UIImage *)LX_rasterizedImage {
    UIGraphicsBeginImageContextWithOptions(self.bounds.size, self.isOpaque, 0.0f);
    [self.layer renderInContext:UIGraphicsGetCurrentContext()];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

@end

@interface LXReorderableCollectionViewFlowLayout () {
    NSMutableArray *_insertedIndexPaths;
    NSMutableArray *_deletedIndexPaths;
}

@property (strong, nonatomic) NSIndexPath *selectedItemIndexPath;
@property (strong, nonatomic) NSIndexPath *destinationIndexPath;
@property (strong, nonatomic) UIView *currentView;
@property (assign, nonatomic) CGPoint currentViewCenter;
@property (assign, nonatomic) CGPoint panTranslationInCollectionView;
@property (strong, nonatomic) NSTimer *scrollingTimer;

@property (assign, nonatomic, readonly) id<LXReorderableCollectionViewDataSource> dataSource;
@property (assign, nonatomic, readonly) id<LXReorderableCollectionViewDelegateFlowLayout> delegate;

@property (nonatomic, assign) BOOL pinching;
@property (nonatomic, assign) CGFloat pinchScale;
@property (nonatomic, assign) CGPoint pinchCenter;

@end

@implementation LXReorderableCollectionViewFlowLayout

- (void)setDefaults {
    _scrollingSpeed = 300.0f;
    _scrollingTriggerEdgeInsets = UIEdgeInsetsMake(50.0f, 50.0f, 50.0f, 50.0f);
}

- (void)prepareLayout {
    _insertedIndexPaths = [NSMutableArray new];
    _deletedIndexPaths = [NSMutableArray new];
}

- (void)prepareForCollectionViewUpdates:(NSArray*)updates
{
    [super prepareForCollectionViewUpdates:updates];
    for (UICollectionViewUpdateItem *updateItem in updates) {
        if (updateItem.updateAction ==
            UICollectionUpdateActionInsert)
        {
            [_insertedIndexPaths addObject:
             updateItem.indexPathAfterUpdate];
        } else if (updateItem.updateAction ==
                   UICollectionUpdateActionDelete)
        {
            [_deletedIndexPaths addObject:
             updateItem.indexPathBeforeUpdate];
        }
    }
}

- (void)finalizeCollectionViewUpdates
{
    [_insertedIndexPaths removeAllObjects];
    [_deletedIndexPaths removeAllObjects];
}

/*
- (UICollectionViewLayoutAttributes *)initialLayoutAttributesForAppearingItemAtIndexPath:(NSIndexPath*)itemIndexPath
{
    if ([_insertedIndexPaths containsObject:itemIndexPath]) {
//        UICollectionViewLayoutAttributes *attributes =
//        [UICollectionViewLayoutAttributes
//         layoutAttributesForCellWithIndexPath:itemIndexPath];

        CGRect visibleRect =
        (CGRect){.origin = self.collectionView.contentOffset,
            .size = self.collectionView.bounds.size};
        attributes.center = CGPointMake(CGRectGetMidX(visibleRect),
                                        CGRectGetMidY(visibleRect));
        attributes.alpha = 0.0f;
//        attributes.transform3D = CATransform3DMakeScale(0.6f,
//                                                        0.6f,
//                                                        1.0f);

        return attributes;
    } else {
        return
        [super initialLayoutAttributesForAppearingItemAtIndexPath:
         itemIndexPath];
    }
}

- (UICollectionViewLayoutAttributes *)finalLayoutAttributesForDisappearingItemAtIndexPath:(NSIndexPath*)itemIndexPath
{
    if (false && [_deletedIndexPaths containsObject:itemIndexPath]) {
        UICollectionViewLayoutAttributes *attributes =
        [UICollectionViewLayoutAttributes
         layoutAttributesForCellWithIndexPath:itemIndexPath];

//        CGRect visibleRect =
//        (CGRect){.origin = self.collectionView.contentOffset,
//            .size = self.collectionView.bounds.size};
//        attributes.center = CGPointMake(CGRectGetMidX(visibleRect),
//                                        CGRectGetMidY(visibleRect));
        attributes.alpha = 0.0f;
//        attributes.transform3D = CATransform3DMakeScale(1.3f,
//                                                        1.3f,
//                                                        1.0f);

        return attributes;
    } else {
        return
        [super finalLayoutAttributesForDisappearingItemAtIndexPath:
         itemIndexPath];
    }
}
*/

- (void)setPinchScale:(CGFloat)pinchScale {
    _pinchScale = pinchScale;
//    [self invalidateLayout];
}

- (void)setPinchCenter:(CGPoint)pinchCenter {
    _pinchCenter = pinchCenter;
//    [self invalidateLayout];
}

- (void)setupCollectionView {
    _longPressGestureRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                action:@selector(handleLongPressGesture:)];
    _longPressGestureRecognizer.delegate = self;
    [self.collectionView addGestureRecognizer:_longPressGestureRecognizer];

    self.pinching = NO;
    _pinchGestureRecognizer = [[UIPinchGestureRecognizer alloc] initWithTarget:self
                                                                        action:@selector(handlePinchGesture:)];
    _pinchGestureRecognizer.delegate = self;
    [self.collectionView addGestureRecognizer:_pinchGestureRecognizer];

    // Links the default long press gesture recognizer to the custom long press gesture recognizer we are creating now
    // by enforcing failure dependency so that they doesn't clash.
    // In other words, our long-press recognizer takes precedence.
    for (UIGestureRecognizer *gestureRecognizer in self.collectionView.gestureRecognizers) {
        if ([gestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]  && gestureRecognizer != _longPressGestureRecognizer) {
            [gestureRecognizer requireGestureRecognizerToFail:_longPressGestureRecognizer];
        }
    }
    
    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self
                                                                    action:@selector(handlePanGesture:)];
    _panGestureRecognizer.delegate = self;
    [self.collectionView addGestureRecognizer:_panGestureRecognizer];
}

- (id)init {
    self = [super init];
    if (self) {
        [self setDefaults];
        [self addObserver:self forKeyPath:kLXCollectionViewKeyPath options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (id)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    if (self) {
        [self setDefaults];
        [self addObserver:self forKeyPath:kLXCollectionViewKeyPath options:NSKeyValueObservingOptionNew context:nil];
    }
    return self;
}

- (void)dealloc {
    [self invalidatesScrollTimer];
    [self removeObserver:self forKeyPath:kLXCollectionViewKeyPath];
}

- (void)applyLayoutAttributes:(UICollectionViewLayoutAttributes *)attributes {
    if ([attributes.indexPath isEqual:self.selectedItemIndexPath]) {
        // dfcarney: makes for nicer animation at gesture end
        // attributes.hidden = YES;

//        CGFloat scale = self.pinchScale;
//        CATransform3D transform = CATransform3DMakeScale(scale, scale, 1.f);
//        attributes.transform3D = transform;
//        attributes.zIndex = 1;
    } else {
        attributes.zIndex = 0;
    }
}

- (id<LXReorderableCollectionViewDataSource>)dataSource {
    return (id<LXReorderableCollectionViewDataSource>)self.collectionView.dataSource;
}

- (id<LXReorderableCollectionViewDelegateFlowLayout>)delegate {
    return (id<LXReorderableCollectionViewDelegateFlowLayout>)self.collectionView.delegate;
}

- (void)invalidateLayoutIfNecessary {
    NSIndexPath *newIndexPath = [self.collectionView indexPathForItemAtPoint:self.currentView.center];
    NSIndexPath *previousIndexPath = self.selectedItemIndexPath;
    
    // dfcarney: we want notifications if we're hovering over our original location
    if (newIndexPath == nil) { // || [newIndexPath isEqual:previousIndexPath]) {
        return;
    }
    
    if ([self.dataSource respondsToSelector:@selector(collectionView:itemAtIndexPath:canMoveToIndexPath:)] &&
        ![self.dataSource collectionView:self.collectionView itemAtIndexPath:previousIndexPath canMoveToIndexPath:newIndexPath]) {
        return;
    }
    
    self.destinationIndexPath = newIndexPath;
    
    // dfcarney: don't update it. Instead, track the original indexPath and modify everything after the pan gesture is complete.
    //self.selectedItemIndexPath = newIndexPath;
    
    // dfcarney: this is mostly useless now.
    [self.dataSource collectionView:self.collectionView itemAtIndexPath:previousIndexPath willMoveToIndexPath:newIndexPath];
    
    // dfcarney: rely on the collectionView and delegate to sort stuff out.
    return;
    
    __weak typeof(self) weakSelf = self;
    [self.collectionView performBatchUpdates:^{
        __strong typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf.collectionView deleteItemsAtIndexPaths:@[ previousIndexPath ]];
            [strongSelf.collectionView insertItemsAtIndexPaths:@[ newIndexPath ]];
        }
    } completion:nil];
}

- (void)invalidatesScrollTimer {
    if (self.scrollingTimer.isValid) {
        [self.scrollingTimer invalidate];
    }
    self.scrollingTimer = nil;
}

- (void)setupScrollTimerInDirection:(LXScrollingDirection)direction {
    if (self.scrollingTimer.isValid) {
        LXScrollingDirection oldDirection = [self.scrollingTimer.userInfo[kLXScrollingDirectionKey] integerValue];
        
        if (direction == oldDirection) {
            return;
        }
    }
    
    [self invalidatesScrollTimer];
    
    self.scrollingTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / LX_FRAMES_PER_SECOND
                                                           target:self
                                                         selector:@selector(handleScroll:)
                                                         userInfo:@{ kLXScrollingDirectionKey : @(direction) }
                                                          repeats:YES];
}

#pragma mark - Target/Action methods

// Tight loop, allocate memory sparely, even if they are stack allocation.
- (void)handleScroll:(NSTimer *)timer {
    LXScrollingDirection direction = (LXScrollingDirection)[timer.userInfo[kLXScrollingDirectionKey] integerValue];
    if (direction == LXScrollingDirectionUnknown) {
        return;
    }
    
    CGSize frameSize = self.collectionView.bounds.size;
    CGSize contentSize = self.collectionView.contentSize;
    CGPoint contentOffset = self.collectionView.contentOffset;
    CGFloat distance = self.scrollingSpeed / LX_FRAMES_PER_SECOND;
    CGPoint translation = CGPointZero;
    
    switch(direction) {
        case LXScrollingDirectionUp: {
            distance = -distance;
            CGFloat minY = 0.0f;
            
            if ((contentOffset.y + distance) <= minY) {
                distance = -contentOffset.y;
            }
            
            translation = CGPointMake(0.0f, distance);
        } break;
        case LXScrollingDirectionDown: {
            CGFloat maxY = MAX(contentSize.height, frameSize.height) - frameSize.height;
            
            if ((contentOffset.y + distance) >= maxY) {
                distance = maxY - contentOffset.y;
            }
            
            translation = CGPointMake(0.0f, distance);
        } break;
        case LXScrollingDirectionLeft: {
            distance = -distance;
            CGFloat minX = 0.0f;
            
            if ((contentOffset.x + distance) <= minX) {
                distance = -contentOffset.x;
            }
            
            translation = CGPointMake(distance, 0.0f);
        } break;
        case LXScrollingDirectionRight: {
            CGFloat maxX = MAX(contentSize.width, frameSize.width) - frameSize.width;
            
            if ((contentOffset.x + distance) >= maxX) {
                distance = maxX - contentOffset.x;
            }
            
            translation = CGPointMake(distance, 0.0f);
        } break;
        default: {
            // Do nothing...
        } break;
    }
    
    self.currentViewCenter = LXS_CGPointAdd(self.currentViewCenter, translation);
    self.currentView.center = LXS_CGPointAdd(self.currentViewCenter, self.panTranslationInCollectionView);
    self.collectionView.contentOffset = LXS_CGPointAdd(contentOffset, translation);
}

- (void)handlePinchGesture:(UIPinchGestureRecognizer *)gestureRecognizer {
    switch(gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan: {
            self.pinching = YES;
            
            NSIndexPath *currentIndexPath = [self.collectionView indexPathForItemAtPoint:[gestureRecognizer locationInView:self.collectionView]];
            self.selectedItemIndexPath = currentIndexPath;

            if (self.selectedItemIndexPath) {
                self.pinchCenter = [gestureRecognizer locationInView:self.collectionView];

                UICollectionViewCell *collectionViewCell = [self.collectionView cellForItemAtIndexPath:self.selectedItemIndexPath];

                self.currentView = [[UIView alloc] initWithFrame:collectionViewCell.frame];

                UIImage *image = [collectionViewCell LX_rasterizedImage];
                UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
                imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                imageView.contentMode = UIViewContentModeScaleAspectFit;
                imageView.alpha = 1.0f;

                [self.currentView addSubview:imageView];
                [[self.collectionView superview] addSubview:self.currentView];

                self.currentViewCenter = self.currentView.center;
            }
        }
        break;
        case UIGestureRecognizerStateChanged: {
            CGPoint point = [gestureRecognizer locationInView:self.collectionView];
//            self.pinchScale = gestureRecognizer.scale;

            CGFloat theScale = gestureRecognizer.scale;
            theScale = MIN(theScale, kPinchMaxScale);
            theScale = MAX(theScale, kPinchMinScale);
            
            self.pinchScale = theScale;

            CGAffineTransform transform = CGAffineTransformMakeScale(self.pinchScale, self.pinchScale);
            self.currentView.transform = transform;

            CGFloat theScalePct = (self.pinchScale - kPinchMinScale) / (kPinchMaxScale - kPinchMinScale);
            self.collectionView.alpha = 1.f - theScalePct;
        }
        break;
        default: {
            CGFloat theScalePct = (self.pinchScale - kPinchMinScale) / (kPinchMaxScale - kPinchMinScale);
            if (theScalePct > 0.80) {
                __weak typeof(self) weakSelf = self;
                [UIView
                 animateWithDuration:0.2
                 delay:0.0
                 options:UIViewAnimationOptionBeginFromCurrentState
                 animations:^{
                     __strong typeof(self) strongSelf = weakSelf;
                     if (strongSelf) {

//                         CGAffineTransform transform = CGAffineTransformMakeScale(kPinchMaxScale, kPinchMaxScale);
//                         strongSelf.currentView.transform = transform;
//                         strongSelf.pinchScale = kPinchMaxScale;

                         CGAffineTransform transform = CGAffineTransformIdentity;
                         strongSelf.currentView.transform = transform;

                         CGRect bounds = strongSelf.currentView.bounds;
                         CGSize maxSize = [strongSelf.dataSource maxZoomReferenceSize];
                         bounds.size = maxSize;
                         strongSelf.currentView.bounds = bounds;

                         UIImageView *imageView = [strongSelf.currentView subviews][0];
                         imageView.image = [self.dataSource imageForItemAtIndexPath:self.selectedItemIndexPath];

                         strongSelf.currentView.alpha = 1.f;
                         strongSelf.collectionView.alpha = 0.f;
                         strongSelf.currentView.center = self.collectionView.center;
                     }
                 }
                 completion:^(BOOL finished) {
                     __strong typeof(self) strongSelf = weakSelf;
                     if (strongSelf) {
                         [strongSelf.delegate collectionView:self.collectionView layout:self didPinchOpenItemAtIndexPath:self.selectedItemIndexPath withInterstitialView:self.currentView];

                         // rely on the delegate to removeFromSuperview
                         // [strongSelf.currentView removeFromSuperview];
                         
                         strongSelf.currentView = nil;
                         strongSelf.selectedItemIndexPath = nil;
                         strongSelf.pinching = NO;
                     }
                 }];
            } else {
                __weak typeof(self) weakSelf = self;
                [UIView
                 animateWithDuration:0.3
                 delay:0.0
                 options:UIViewAnimationOptionBeginFromCurrentState
                 animations:^{
                     __strong typeof(self) strongSelf = weakSelf;
                     if (strongSelf) {
                         CGAffineTransform transform = CGAffineTransformIdentity;
                         strongSelf.currentView.transform = transform;
                         strongSelf.pinchScale = 1.0;
                         strongSelf.currentView.alpha = 0.f;
                         strongSelf.collectionView.alpha = 1.0;
                     }
                 }
                 completion:^(BOOL finished) {
                     __strong typeof(self) strongSelf = weakSelf;
                     if (strongSelf) {
                         [strongSelf.currentView removeFromSuperview];
                         strongSelf.currentView = nil;
                         strongSelf.selectedItemIndexPath = nil;
                         strongSelf.pinching = NO;
                     }
                 }];
            }
        }
    }
}


- (void)handleLongPressGesture:(UILongPressGestureRecognizer *)gestureRecognizer {
    switch(gestureRecognizer.state) {
        case UIGestureRecognizerStateBegan: {
            NSIndexPath *currentIndexPath = [self.collectionView indexPathForItemAtPoint:[gestureRecognizer locationInView:self.collectionView]];

            if ([self.delegate respondsToSelector:@selector(collectionView:longPressDidBegin:)]) {
                [self.delegate collectionView:self.collectionView longPressDidBegin:currentIndexPath];
            }

            if ([self.dataSource respondsToSelector:@selector(collectionView:canMoveItemAtIndexPath:)] &&
               ![self.dataSource collectionView:self.collectionView canMoveItemAtIndexPath:currentIndexPath]) {
                return;
            }
            
            self.selectedItemIndexPath = currentIndexPath;
            self.destinationIndexPath = currentIndexPath;
            
            if ([self.delegate respondsToSelector:@selector(collectionView:layout:willBeginDraggingItemAtIndexPath:)]) {
                [self.delegate collectionView:self.collectionView layout:self willBeginDraggingItemAtIndexPath:self.selectedItemIndexPath];
            }
            
            UICollectionViewCell *collectionViewCell = [self.collectionView cellForItemAtIndexPath:self.selectedItemIndexPath];
            
            self.currentView = [[UIView alloc] initWithFrame:collectionViewCell.frame];
            
            collectionViewCell.highlighted = YES;
            UIImageView *highlightedImageView = [[UIImageView alloc] initWithImage:[collectionViewCell LX_rasterizedImage]];
            highlightedImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            highlightedImageView.alpha = 1.0f;
            
            collectionViewCell.highlighted = NO;
            UIImageView *imageView = [[UIImageView alloc] initWithImage:[collectionViewCell LX_rasterizedImage]];
            imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            imageView.alpha = 0.0f;
            
            [self.currentView addSubview:imageView];
            [self.currentView addSubview:highlightedImageView];
            [self.collectionView addSubview:self.currentView];
            
            self.currentViewCenter = self.currentView.center;
            
            __weak typeof(self) weakSelf = self;
            [UIView
             animateWithDuration:0.3
             delay:0.0
             options:UIViewAnimationOptionBeginFromCurrentState
             animations:^{
                 __strong typeof(self) strongSelf = weakSelf;
                 if (strongSelf) {
                     strongSelf.currentView.transform = CGAffineTransformMakeScale(1.1f, 1.1f);
                     highlightedImageView.alpha = 0.0f;
                     imageView.alpha = 1.0f;
                 }
             }
             completion:^(BOOL finished) {
                 __strong typeof(self) strongSelf = weakSelf;
                 if (strongSelf) {
                     [highlightedImageView removeFromSuperview];

                     
                     if ([strongSelf.delegate respondsToSelector:@selector(collectionView:layout:didBeginDraggingItemAtIndexPath:)]) {
                         [strongSelf.delegate collectionView:strongSelf.collectionView layout:strongSelf didBeginDraggingItemAtIndexPath:strongSelf.selectedItemIndexPath];
                     }
                 }
             }];
            
            [self invalidateLayout];
        } break;
        case UIGestureRecognizerStateEnded: {
            NSIndexPath *currentIndexPath = self.selectedItemIndexPath;
            
            if (currentIndexPath) {
                if ([self.delegate respondsToSelector:@selector(collectionView:layout:willEndDraggingItemAtIndexPath:to:)]) {
                    [self.delegate collectionView:self.collectionView layout:self willEndDraggingItemAtIndexPath:currentIndexPath to:self.destinationIndexPath];
                }
                
                self.selectedItemIndexPath = nil;
                self.currentViewCenter = CGPointZero;
                
                UICollectionViewLayoutAttributes *layoutAttributes = [self layoutAttributesForItemAtIndexPath:currentIndexPath];
                
                __weak typeof(self) weakSelf = self;
                [UIView
                 animateWithDuration:0.0 // dfcarney: was 0.3
                 delay:0.0
                 options:UIViewAnimationOptionBeginFromCurrentState
                 animations:^{
                     // dfcarney: rely on the collectionView and delegate to animate/redraw things
                     // __strong typeof(self) strongSelf = weakSelf;
                     // if (strongSelf) {
                     //     strongSelf.currentView.transform = CGAffineTransformMakeScale(1.0f, 1.0f);
                     //     strongSelf.currentView.center = layoutAttributes.center;
                     // }
                 }
                 completion:^(BOOL finished) {
                     __strong typeof(self) strongSelf = weakSelf;
                     if (strongSelf) {
                         [strongSelf.currentView removeFromSuperview];
                         strongSelf.currentView = nil;
                         // dfcarney: rely on the collectionView and delegate to animate/redraw things
                         // [strongSelf invalidateLayout];
                         
                         if ([strongSelf.delegate respondsToSelector:@selector(collectionView:layout:didEndDraggingItemAtIndexPath:to:)]) {
                             [strongSelf.delegate collectionView:strongSelf.collectionView layout:strongSelf didEndDraggingItemAtIndexPath:currentIndexPath to:strongSelf.destinationIndexPath];
                         }
                     }
                 }];
            }

            if ([self.delegate respondsToSelector:@selector(collectionViewLongPressDidEnd:)]) {
                [self.delegate collectionViewLongPressDidEnd:self.collectionView];
            }

        } break;
            
        default: break;
    }
}

- (void)handlePanGesture:(UIPanGestureRecognizer *)gestureRecognizer {
    if (self.pinching) {
        switch (gestureRecognizer.state) {
            case UIGestureRecognizerStateBegan:
            case UIGestureRecognizerStateChanged: {
                self.panTranslationInCollectionView = [gestureRecognizer translationInView:self.collectionView];
                self.currentView.center = LXS_CGPointAdd(self.currentViewCenter, self.panTranslationInCollectionView);
            }
//            case UIGestureRecognizerStateEnded: {
//            } break;
            default: {
                // Do nothing...
            } break;
        }
    } else {
        switch (gestureRecognizer.state) {
            case UIGestureRecognizerStateBegan:
            case UIGestureRecognizerStateChanged: {
                self.panTranslationInCollectionView = [gestureRecognizer translationInView:self.collectionView];
                CGPoint viewCenter = self.currentView.center = LXS_CGPointAdd(self.currentViewCenter, self.panTranslationInCollectionView);
                
                [self invalidateLayoutIfNecessary];
                
                switch (self.scrollDirection) {
                    case UICollectionViewScrollDirectionVertical: {
                        if (viewCenter.y < (CGRectGetMinY(self.collectionView.bounds) + self.scrollingTriggerEdgeInsets.top)) {
                            [self setupScrollTimerInDirection:LXScrollingDirectionUp];
                        } else {
                            if (viewCenter.y > (CGRectGetMaxY(self.collectionView.bounds) - self.scrollingTriggerEdgeInsets.bottom)) {
                                [self setupScrollTimerInDirection:LXScrollingDirectionDown];
                            } else {
                                [self invalidatesScrollTimer];
                            }
                        }
                    } break;
                    case UICollectionViewScrollDirectionHorizontal: {
                        if (viewCenter.x < (CGRectGetMinX(self.collectionView.bounds) + self.scrollingTriggerEdgeInsets.left)) {
                            [self setupScrollTimerInDirection:LXScrollingDirectionLeft];
                        } else {
                            if (viewCenter.x > (CGRectGetMaxX(self.collectionView.bounds) - self.scrollingTriggerEdgeInsets.right)) {
                                [self setupScrollTimerInDirection:LXScrollingDirectionRight];
                            } else {
                                [self invalidatesScrollTimer];
                            }
                        }
                    } break;
                }
            } break;
            case UIGestureRecognizerStateEnded: {
                [self invalidatesScrollTimer];
            } break;
            default: {
                // Do nothing...
            } break;
        }
    }
}

#pragma mark - UICollectionViewLayout overridden methods

- (NSArray *)layoutAttributesForElementsInRect:(CGRect)rect {
    NSArray *layoutAttributesForElementsInRect = [super layoutAttributesForElementsInRect:rect];
    
    for (UICollectionViewLayoutAttributes *layoutAttributes in layoutAttributesForElementsInRect) {
        switch (layoutAttributes.representedElementCategory) {
            case UICollectionElementCategoryCell: {
                [self applyLayoutAttributes:layoutAttributes];
            } break;
            default: {
                // Do nothing...
            } break;
        }
    }
    
    return layoutAttributesForElementsInRect;
}

- (UICollectionViewLayoutAttributes *)layoutAttributesForItemAtIndexPath:(NSIndexPath *)indexPath {
    UICollectionViewLayoutAttributes *layoutAttributes = [super layoutAttributesForItemAtIndexPath:indexPath];
    
    switch (layoutAttributes.representedElementCategory) {
        case UICollectionElementCategoryCell: {
            [self applyLayoutAttributes:layoutAttributes];
        } break;
        default: {
            // Do nothing...
        } break;
    }
    
    return layoutAttributes;
}

#pragma mark - UIGestureRecognizerDelegate methods

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([self.panGestureRecognizer isEqual:gestureRecognizer]) {
        return (self.selectedItemIndexPath != nil);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    if ([self.longPressGestureRecognizer isEqual:gestureRecognizer]) {
        return [self.panGestureRecognizer isEqual:otherGestureRecognizer];
    }
    
    if ([self.panGestureRecognizer isEqual:gestureRecognizer]) {
        return [self.longPressGestureRecognizer isEqual:otherGestureRecognizer];
    }

    if ([self.pinchGestureRecognizer isEqual:gestureRecognizer]) {
        return [self.panGestureRecognizer isEqual:otherGestureRecognizer];
    }

    if ([self.panGestureRecognizer isEqual:gestureRecognizer]) {
        return [self.pinchGestureRecognizer isEqual:otherGestureRecognizer];
    }

    return NO;
}

#pragma mark - Key-Value Observing methods

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:kLXCollectionViewKeyPath]) {
        if (self.collectionView != nil) {
            [self setupCollectionView];
        } else {
            [self invalidatesScrollTimer];
        }
    }
}

#pragma mark - Depreciated methods

#pragma mark Starting from 0.1.0
- (void)setUpGestureRecognizersOnCollectionView {
    // Do nothing...
}

@end
