#import "main_menu.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>

@interface TOTKMainMenuController ()
@property(nonatomic, strong) AVQueuePlayer *player;
@property(nonatomic, strong) AVPlayerLooper *playerLooper;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CAGradientLayer *legibilityGradient;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *settingsButton;
@property(nonatomic) CGSize videoSize;
@property(nonatomic) NSUInteger playbackGeneration;
@property(nonatomic) BOOL leavingForGame;
@property(nonatomic) BOOL observingLifecycle;
@end

@implementation TOTKMainMenuController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor colorWithRed:0.025 green:0.035 blue:0.03 alpha:1.0];
    self.view.clipsToBounds = YES;

    self.videoSize = CGSizeMake(16, 9); // Fallback while the bundled clip's track metadata loads.
    self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:nil];
    self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.playerLayer.backgroundColor = UIColor.blackColor.CGColor;
    [self.view.layer addSublayer:self.playerLayer];

    self.legibilityGradient = [CAGradientLayer layer];
    self.legibilityGradient.startPoint = CGPointMake(0, 0.5);
    self.legibilityGradient.endPoint = CGPointMake(1, 0.5);
    self.legibilityGradient.locations = @[@0.0, @0.38, @0.72, @1.0];
    self.legibilityGradient.colors = @[
        (id)[UIColor colorWithWhite:0 alpha:0].CGColor,
        (id)[UIColor colorWithWhite:0 alpha:0.02].CGColor,
        (id)[UIColor colorWithWhite:0.015 alpha:0.48].CGColor,
        (id)[UIColor colorWithWhite:0.015 alpha:0.78].CGColor
    ];
    [self.view.layer addSublayer:self.legibilityGradient];

    self.playButton = [self makeMenuButton:@"Play" primary:YES action:@selector(playTapped:)];
    self.settingsButton = [self makeMenuButton:@"Settings" primary:NO action:@selector(settingsTapped:)];
    UIStackView *menu = [[UIStackView alloc] initWithArrangedSubviews:@[self.playButton, self.settingsButton]];
    menu.axis = UILayoutConstraintAxisVertical;
    menu.alignment = UIStackViewAlignmentTrailing;
    menu.distribution = UIStackViewDistributionFillEqually;
    menu.spacing = 4;
    menu.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:menu];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [menu.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-56],
        [menu.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [menu.widthAnchor constraintEqualToConstant:220],
        [self.playButton.heightAnchor constraintGreaterThanOrEqualToConstant:56],
        [self.settingsButton.heightAnchor constraintGreaterThanOrEqualToConstant:56]
    ]];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(applicationWillResignActive:)
                   name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(applicationDidBecomeActive:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(sceneWillDeactivate:)
                   name:UISceneWillDeactivateNotification object:nil];
    [center addObserver:self selector:@selector(sceneDidActivate:)
                   name:UISceneDidActivateNotification object:nil];
    self.observingLifecycle = YES;

    [self prepareMenuVideo];
}

- (UIButton *)makeMenuButton:(NSString *)title primary:(BOOL)primary action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *configuration = UIButtonConfiguration.plainButtonConfiguration;
    UIColor *gold = [UIColor colorWithRed:0.89 green:0.75 blue:0.48 alpha:1.0];
    UIColor *cream = [UIColor colorWithRed:0.94 green:0.92 blue:0.84 alpha:1.0];
    UIFont *font = [UIFont fontWithName:@"Georgia" size:30] ?: [UIFont systemFontOfSize:30 weight:UIFontWeightMedium];
    configuration.baseForegroundColor = primary ? gold : cream;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(12, 20, 12, 20);
    configuration.background.cornerRadius = 2;
    configuration.background.backgroundColor = primary
        ? [UIColor colorWithRed:0.63 green:0.51 blue:0.27 alpha:0.18]
        : [UIColor colorWithWhite:0 alpha:0.04];
    configuration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary<NSAttributedStringKey, id> *styled = [attributes mutableCopy];
        styled[NSFontAttributeName] = font;
        styled[NSKernAttributeName] = @0.2;
        return styled;
    };
    button.configuration = configuration;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    button.accessibilityLabel = title;
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:220].active = YES;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:56].active = YES;
    button.configurationUpdateHandler = ^(UIButton *updatedButton) {
        UIButtonConfiguration *updated = updatedButton.configuration;
        UIColor *base = primary ? gold : cream;
        updated.baseForegroundColor = updatedButton.isHighlighted
            ? [base colorWithAlphaComponent:0.72]
            : base;
        updated.background.backgroundColor = updatedButton.isHighlighted
            ? [UIColor colorWithRed:0.72 green:0.60 blue:0.34 alpha:0.28]
            : (primary ? [UIColor colorWithRed:0.63 green:0.51 blue:0.27 alpha:0.18]
                       : [UIColor colorWithWhite:0 alpha:0.04]);
        updatedButton.configuration = updated;
    };
    return button;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGSize source = self.videoSize;
    if (source.width <= 0 || source.height <= 0) source = CGSizeMake(16, 9);
    CGFloat scale = MAX(CGRectGetWidth(bounds) / source.width,
                        CGRectGetHeight(bounds) / source.height);
    CGSize scaled = CGSizeMake(source.width * scale, source.height * scale);
    self.playerLayer.frame = CGRectMake(CGRectGetMidX(bounds) - scaled.width * 0.5,
                                        CGRectGetMinY(bounds),
                                        scaled.width,
                                        scaled.height);
    self.legibilityGradient.frame = bounds;
}

- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updatePlaybackState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.player pause];
}

- (void)prepareMenuVideo {
    NSString *path = [NSBundle.mainBundle pathForResource:@"totk_menu_video" ofType:@"mp4"];
    if (!path.length || self.leavingForGame) return;

    NSUInteger generation = ++self.playbackGeneration;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
    __weak typeof(self) weakSelf = self;
    [asset loadValuesAsynchronouslyForKeys:@[@"playable", @"tracks", @"duration"] completionHandler:^{
        NSError *error = nil;
        AVKeyValueStatus playableStatus = [asset statusOfValueForKey:@"playable" error:&error];
        AVKeyValueStatus tracksStatus = [asset statusOfValueForKey:@"tracks" error:&error];
        AVKeyValueStatus durationStatus = [asset statusOfValueForKey:@"duration" error:&error];
        AVAssetTrack *videoTrack = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        CGSize videoSize = CGSizeZero;
        if (videoTrack) {
            CGRect transformed = CGRectApplyAffineTransform(
                CGRectMake(0, 0, videoTrack.naturalSize.width, videoTrack.naturalSize.height),
                videoTrack.preferredTransform);
            videoSize = CGSizeMake(fabs(CGRectGetWidth(transformed)), fabs(CGRectGetHeight(transformed)));
        }
        BOOL valid = playableStatus == AVKeyValueStatusLoaded
            && tracksStatus == AVKeyValueStatusLoaded
            && durationStatus == AVKeyValueStatusLoaded
            && asset.playable
            && CMTIME_IS_NUMERIC(asset.duration)
            && CMTimeGetSeconds(asset.duration) > 0
            && videoTrack != nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            TOTKMainMenuController *strongSelf = weakSelf;
            if (!strongSelf || !valid || strongSelf.leavingForGame ||
                generation != strongSelf.playbackGeneration) return;

            if (isfinite(videoSize.width) && isfinite(videoSize.height) &&
                videoSize.width > 0 && videoSize.height > 0) {
                strongSelf.videoSize = videoSize;
                [strongSelf.view setNeedsLayout];
            }

            AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
            AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]];
            player.muted = YES;
            player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:item];
            strongSelf.player = player;
            strongSelf.playerLooper = looper;
            strongSelf.playerLayer.player = player;
            [strongSelf updatePlaybackState];
        });
    }];
}

- (BOOL)menuIsVisibleAndActive {
    if (self.leavingForGame || !self.isViewLoaded || !self.view.window ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIWindowScene *scene = self.view.window.windowScene;
    return !scene || scene.activationState == UISceneActivationStateForegroundActive;
}

- (void)updatePlaybackState {
    if ([self menuIsVisibleAndActive]) [self.player play];
    else [self.player pause];
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    (void)notification;
    [self.player pause];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self updatePlaybackState];
}

- (void)sceneWillDeactivate:(NSNotification *)notification {
    (void)notification;
    [self updatePlaybackState];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    (void)notification;
    [self updatePlaybackState];
}

- (void)playTapped:(UIButton *)sender {
    (void)sender;
    if (self.leavingForGame) return;
    self.leavingForGame = YES;
    self.playButton.enabled = NO;
    self.settingsButton.enabled = NO;

    [self stopPlayback];
    void (^playHandler)(void) = self.playHandler;
    self.playHandler = nil;
    if (playHandler) playHandler();
}

- (void)settingsTapped:(UIButton *)sender {
    (void)sender;
    if (self.leavingForGame || self.presentedViewController) return;
    UIAlertController *settings = [UIAlertController alertControllerWithTitle:@"Settings"
                                                                      message:@"Controls and additional options will be available in a future update."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [settings addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:settings animated:YES completion:nil];
}

- (void)stopPlayback {
    ++self.playbackGeneration;
    if (self.observingLifecycle) {
        [NSNotificationCenter.defaultCenter removeObserver:self];
        self.observingLifecycle = NO;
    }
    [self.player pause];
    [self.playerLooper disableLooping];
    [self.playerLayer.player pause];
    self.playerLayer.player = nil;
    [self.playerLayer removeFromSuperlayer];
    self.playerLayer = nil;
    [self.player removeAllItems];
    self.playerLooper = nil;
    self.player = nil;
}

- (void)dealloc {
    if (self.observingLifecycle) [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.player pause];
    [self.playerLooper disableLooping];
    [self.player removeAllItems];
}

@end
