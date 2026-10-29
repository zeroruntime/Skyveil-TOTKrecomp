#import "main_menu.h"

#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <math.h>
#import <stdlib.h>
#import "../../third_party/d2r_gfx/gfx/nvn/fps_overlay.h"
#import "phone_settings.h"
#import "runtime.h"

@interface TOTKMainMenuController ()
@property(nonatomic, strong) AVQueuePlayer *player;
@property(nonatomic, strong) AVPlayerLooper *playerLooper;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) CAGradientLayer *legibilityGradient;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *settingsButton;
@property(nonatomic, strong) UIControl *settingsOverlay;
@property(nonatomic, strong) UIStackView *settingsPageContainer;
@property(nonatomic, strong) UIScrollView *settingsScrollView;
@property(nonatomic, strong) NSArray<UIStackView *> *settingsPages;
@property(nonatomic, strong) NSArray<UIButton *> *settingsTabButtons;
@property(nonatomic, strong) NSArray<NSArray<UIControl *> *> *settingsPageControllerItems;
@property(nonatomic, strong) UIButton *settingsCloseButton;
@property(nonatomic, strong) UILabel *masterVolumeValueLabel;
@property(nonatomic, strong) UISlider *masterVolumeSlider;
@property(nonatomic, strong) NSTimer *controllerPollTimer;
@property(nonatomic, strong) GCController *lastPolledController;
@property(nonatomic, weak) UIView *controllerFocusedView;
@property(nonatomic, strong) CALayer *controllerFocusRing;
@property(nonatomic) NSUInteger selectedSettingsTab;
@property(nonatomic) NSUInteger launcherFocusIndex;
@property(nonatomic) NSUInteger settingsFocusIndex;
@property(nonatomic) CGSize videoSize;
@property(nonatomic) NSUInteger playbackGeneration;
@property(nonatomic) BOOL leavingForGame;
@property(nonatomic) BOOL observingLifecycle;
@property(nonatomic) BOOL controllerInputHeld;
- (BOOL)iosFpsOverlayEnabledPreference;
- (NSInteger)iosFpsOverlayCornerPreference;
- (void)applyFpsOverlayPreferences;
- (NSInteger)iosMasterVolumePreference;
- (void)applyMasterVolumePreference;
@end

@implementation TOTKMainMenuController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self applyFpsOverlayPreferences];
    [self applyMasterVolumePreference];

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
    __weak typeof(self) weakSelf = self;
    button.configurationUpdateHandler = ^(UIButton *updatedButton) {
        UIButtonConfiguration *updated = updatedButton.configuration;
        BOOL focused = weakSelf.controllerFocusedView == updatedButton;
        UIColor *dark = [UIColor colorWithRed:0.11 green:0.12 blue:0.11 alpha:1.0];
        UIColor *focusGold = [UIColor colorWithRed:0.92 green:0.77 blue:0.49 alpha:1.0];
        UIColor *base = primary ? gold : cream;
        if (focused) {
            updated.baseForegroundColor = dark;
            updated.background.backgroundColor = focusGold;
        } else {
            updated.baseForegroundColor = updatedButton.isHighlighted ? [base colorWithAlphaComponent:0.72] : base;
            updated.background.backgroundColor = updatedButton.isHighlighted
                ? [UIColor colorWithRed:0.72 green:0.60 blue:0.34 alpha:0.28]
                : (primary ? [UIColor colorWithRed:0.63 green:0.51 blue:0.27 alpha:0.18]
                           : [UIColor colorWithWhite:0 alpha:0.04]);
        }
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
    [self updateControllerFocusRing];
}

- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self updatePlaybackState];
    [self startControllerPolling];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopControllerPolling];
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
    [self stopControllerPolling];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    (void)notification;
    [self updatePlaybackState];
    [self startControllerPolling];
}

- (void)sceneWillDeactivate:(NSNotification *)notification {
    (void)notification;
    [self updatePlaybackState];
    [self stopControllerPolling];
}

- (void)sceneDidActivate:(NSNotification *)notification {
    (void)notification;
    [self updatePlaybackState];
    [self startControllerPolling];
}

- (void)startControllerPolling {
    if (self.controllerPollTimer || self.leavingForGame || ![self menuIsVisibleAndActive]) return;
    self.controllerInputHeld = YES; // Require one neutral sample after launch or foregrounding.
    self.lastPolledController = nil;
    __weak typeof(self) weakSelf = self;
    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 60.0 repeats:YES block:^(NSTimer *tick) {
        (void)tick;
        [weakSelf pollController];
    }];
    self.controllerPollTimer = timer;
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)stopControllerPolling {
    [self.controllerPollTimer invalidate];
    self.controllerPollTimer = nil;
    self.lastPolledController = nil;
    self.controllerInputHeld = NO;
    [self setControllerFocusView:nil];
}

- (NSArray<UIControl *> *)controllerSettingsItems {
    if (!self.settingsOverlay) return @[];
    NSMutableArray<UIControl *> *items = [NSMutableArray array];
    if (self.selectedSettingsTab < self.settingsPageControllerItems.count) {
        [items addObjectsFromArray:self.settingsPageControllerItems[self.selectedSettingsTab]];
    }
    if (self.settingsCloseButton) [items addObject:self.settingsCloseButton];
    return items;
}

- (NSArray<UIControl *> *)activeControllerItems {
    if (self.leavingForGame) return @[];
    if (self.settingsOverlay) return [self controllerSettingsItems];
    return self.playButton && self.settingsButton ? @[self.playButton, self.settingsButton] : @[];
}

- (void)setControllerFocusView:(UIView *)view {
    UIView *previous = self.controllerFocusedView;
    [self.controllerFocusRing removeFromSuperlayer];
    self.controllerFocusRing = nil;
    self.controllerFocusedView = view;

    if (previous == self.playButton || previous == self.settingsButton) {
        [(UIButton *)previous setNeedsUpdateConfiguration];
    }
    if (view == self.playButton || view == self.settingsButton) {
        [(UIButton *)view setNeedsUpdateConfiguration];
        return;
    }
    if (!view) return;

    UIColor *gold = [UIColor colorWithRed:0.98 green:0.78 blue:0.32 alpha:1.0];
    CALayer *ring = [CALayer layer];
    ring.name = @"TOTKControllerFocusRing";
    ring.frame = view.bounds;
    ring.borderWidth = 3;
    ring.borderColor = gold.CGColor;
    ring.cornerRadius = MAX(view.layer.cornerRadius, 7);
    ring.backgroundColor = UIColor.clearColor.CGColor;
    [view.layer addSublayer:ring];
    self.controllerFocusRing = ring;
}

- (void)updateControllerFocusRing {
    UIView *view = self.controllerFocusedView;
    if (!view || !self.controllerFocusRing) return;
    self.controllerFocusRing.frame = view.bounds;
    self.controllerFocusRing.cornerRadius = MAX(view.layer.cornerRadius, 7);
}

- (void)updateControllerFocus {
    NSArray<UIControl *> *items = [self activeControllerItems];
    if (!self.lastPolledController || !items.count || self.leavingForGame) {
        [self setControllerFocusView:nil];
        return;
    }

    NSUInteger *focusIndex = self.settingsOverlay ? &_settingsFocusIndex : &_launcherFocusIndex;
    *focusIndex = MIN(*focusIndex, items.count - 1);
    UIControl *focused = items[*focusIndex];
    [self setControllerFocusView:focused];

    if (self.settingsOverlay && focused != self.settingsCloseButton) {
        CGRect target = [focused convertRect:focused.bounds toView:self.settingsScrollView];
        [self.settingsScrollView scrollRectToVisible:CGRectInset(target, 0, -8) animated:YES];
    }
}

- (void)moveControllerFocus:(NSInteger)direction {
    NSArray<UIControl *> *items = [self activeControllerItems];
    if (!items.count) return;
    NSUInteger *focusIndex = self.settingsOverlay ? &_settingsFocusIndex : &_launcherFocusIndex;
    *focusIndex = MIN(*focusIndex, items.count - 1);
    if (direction < 0 && *focusIndex > 0) (*focusIndex)--;
    else if (direction > 0 && *focusIndex + 1 < items.count) (*focusIndex)++;
    [self updateControllerFocus];
}

- (void)activateControllerItem:(UIControl *)item {
    if ([item isKindOfClass:UIButton.class]) [item sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (UISwitch *)toggleControlInRow:(UIButton *)row {
    for (UIView *subview in row.subviews) {
        if ([subview isKindOfClass:UISwitch.class]) return (UISwitch *)subview;
    }
    return nil;
}

- (void)moveSettingsTab:(NSInteger)direction {
    if (!self.settingsOverlay || !self.settingsTabButtons.count) return;
    NSInteger next = MAX(0, MIN((NSInteger)self.settingsTabButtons.count - 1,
                                (NSInteger)self.selectedSettingsTab + direction));
    if (next != (NSInteger)self.selectedSettingsTab) {
        [self.settingsTabButtons[(NSUInteger)next] sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

- (void)changeControllerValueForItem:(UIControl *)item direction:(NSInteger)direction {
    if ([item isKindOfClass:UISegmentedControl.class]) {
        UISegmentedControl *segmented = (UISegmentedControl *)item;
        NSInteger next = MAX(0, MIN((NSInteger)segmented.numberOfSegments - 1, segmented.selectedSegmentIndex + direction));
        if (next != segmented.selectedSegmentIndex) {
            segmented.selectedSegmentIndex = next;
            [segmented sendActionsForControlEvents:UIControlEventValueChanged];
        }
        return;
    }

    if ([item isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)item;
        slider.value = MAX(slider.minimumValue, MIN(slider.maximumValue, slider.value + (float)direction * 5.0f));
        [slider sendActionsForControlEvents:UIControlEventValueChanged];
        return;
    }

    if ([item isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)item;
        UISwitch *toggle = [self toggleControlInRow:button];
        if (toggle) {
            BOOL shouldBeOn = direction > 0;
            if (toggle.isOn != shouldBeOn) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    }
}

- (void)pollController {
    if (self.leavingForGame || ![self menuIsVisibleAndActive]) {
        [self stopControllerPolling];
        return;
    }

    GCController *controller = GCController.current;
    if (!controller.extendedGamepad) {
        controller = nil;
        for (GCController *candidate in GCController.controllers) {
            if (candidate.extendedGamepad) { controller = candidate; break; }
        }
    }
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    if (!gamepad) {
        self.lastPolledController = nil;
        self.controllerInputHeld = NO;
        [self setControllerFocusView:nil];
        return;
    }
    if (controller != self.lastPolledController) {
        self.lastPolledController = controller;
        self.controllerInputHeld = YES; // A held button on a reconnect cannot activate the menu immediately.
        [self updateControllerFocus];
    }

    float x = gamepad.leftThumbstick.xAxis.value;
    float y = gamepad.leftThumbstick.yAxis.value;
    BOOL up = gamepad.dpad.up.isPressed || y > 0.5f;
    BOOL down = gamepad.dpad.down.isPressed || y < -0.5f;
    BOOL left = gamepad.dpad.left.isPressed || x < -0.5f;
    BOOL right = gamepad.dpad.right.isPressed || x > 0.5f;
    BOOL activate = gamepad.buttonA.isPressed;
    BOOL back = gamepad.buttonB.isPressed;
    BOOL shoulderLeft = gamepad.leftShoulder.isPressed;
    BOOL shoulderRight = gamepad.rightShoulder.isPressed;
    BOOL any = up || down || left || right || activate || back || shoulderLeft || shoulderRight;
    if (!any) { self.controllerInputHeld = NO; return; }
    if (self.controllerInputHeld) return;
    self.controllerInputHeld = YES;

    if (back && self.settingsOverlay) {
        [self closeSettings];
        [self updateControllerFocus];
        return;
    }
    if (self.settingsOverlay && (shoulderLeft || shoulderRight)) {
        [self moveSettingsTab:shoulderRight ? 1 : -1];
        return;
    }
    if (activate) {
        NSArray<UIControl *> *items = [self activeControllerItems];
        NSUInteger focusIndex = self.settingsOverlay ? self.settingsFocusIndex : self.launcherFocusIndex;
        if (focusIndex < items.count) [self activateControllerItem:items[focusIndex]];
        [self updateControllerFocus];
        return;
    }
    if (up) [self moveControllerFocus:-1];
    else if (down) [self moveControllerFocus:1];
    else if (left || right) {
        NSArray<UIControl *> *items = [self activeControllerItems];
        NSUInteger focusIndex = self.settingsOverlay ? self.settingsFocusIndex : self.launcherFocusIndex;
        if (focusIndex < items.count) [self changeControllerValueForItem:items[focusIndex] direction:(right ? 1 : -1)];
        [self updateControllerFocus];
    }
}

- (void)playTapped:(UIButton *)sender {
    (void)sender;
    if (self.leavingForGame || self.settingsOverlay) return;
    self.leavingForGame = YES;
    self.playButton.enabled = NO;
    self.settingsButton.enabled = NO;

    [self stopControllerPolling];
    [self stopPlayback];
    void (^playHandler)(void) = self.playHandler;
    self.playHandler = nil;
    if (playHandler) playHandler();
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (NSArray<UIKeyCommand *> *)keyCommands {
    if (!self.settingsOverlay) return @[];
    return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape
                                 modifierFlags:0
                                        action:@selector(closeSettingsFromKeyboard:)]];
}

- (void)settingsTapped:(UIButton *)sender {
    (void)sender;
    if (self.leavingForGame || self.settingsOverlay) return;
    [self openSettingsPanel];
}

- (void)openSettingsPanel {
    if (self.leavingForGame || self.settingsOverlay) return;

    UIColor *cream = [UIColor colorWithRed:0.94 green:0.92 blue:0.84 alpha:1.0];
    UIColor *gold = [UIColor colorWithRed:0.89 green:0.75 blue:0.48 alpha:1.0];
    UIColor *dark = [UIColor colorWithRed:0.055 green:0.07 blue:0.06 alpha:1.0];

    UIControl *overlay = [UIControl new];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.64];
    overlay.accessibilityViewIsModal = YES;
    overlay.isAccessibilityElement = NO;
    [overlay addTarget:self action:@selector(settingsScrimTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    self.settingsOverlay = overlay;
    self.playButton.accessibilityElementsHidden = YES;
    self.settingsButton.accessibilityElementsHidden = YES;

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor colorWithRed:0.035 green:0.05 blue:0.043 alpha:0.96];
    card.layer.cornerRadius = 12;
    card.layer.borderWidth = 1;
    card.layer.borderColor = [gold colorWithAlphaComponent:0.58].CGColor;
    card.layer.shadowColor = UIColor.blackColor.CGColor;
    card.layer.shadowOpacity = 0.38;
    card.layer.shadowRadius = 24;
    card.layer.shadowOffset = CGSizeMake(0, 8);
    [overlay addSubview:card];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredWidth = [card.widthAnchor constraintEqualToConstant:640];
    preferredWidth.priority = 999;
    NSLayoutConstraint *preferredHeight = [card.heightAnchor constraintEqualToConstant:500];
    preferredHeight.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        preferredWidth,
        [card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24],
        preferredHeight
    ]];

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"Settings";
    title.font = [UIFont fontWithName:@"Georgia" size:26] ?: [UIFont systemFontOfSize:26 weight:UIFontWeightSemibold];
    title.textColor = gold;
    title.accessibilityTraits = UIAccessibilityTraitHeader;

    UISegmentedControl *displayMode = [[UISegmentedControl alloc] initWithItems:@[@"Handheld (720p)", @"Docked (1080p)"]];
    displayMode.translatesAutoresizingMaskIntoConstraints = NO;
    displayMode.selectedSegmentIndex = [NSUserDefaults.standardUserDefaults boolForKey:@"TOTK_DOCKED"] ? 1 : 0;
    [displayMode.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    displayMode.selectedSegmentTintColor = gold;
    displayMode.accessibilityLabel = @"Display mode";
    displayMode.accessibilityHint = @"Handheld uses 1280 by 720. Docked uses 1080p output with a 1600 by 900 scene and may reduce performance.";
    [displayMode setTitleTextAttributes:@{NSForegroundColorAttributeName: cream,
                                         NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightMedium]}
                                forState:UIControlStateNormal];
    [displayMode setTitleTextAttributes:@{NSForegroundColorAttributeName: dark,
                                         NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]}
                                forState:UIControlStateSelected];
    [displayMode addTarget:self action:@selector(displayModeChanged:) forControlEvents:UIControlEventValueChanged];
    UILabel *displayModeTitle = [self settingsLabel:@"Picture quality" font:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] color:cream];
    UILabel *displayModeDescription = [self settingsLabel:@"Docked uses 1080p output with a 1600×900 scene and may reduce performance." font:[UIFont systemFontOfSize:17] color:[cream colorWithAlphaComponent:0.82]];
    displayModeDescription.numberOfLines = 0;
    UIStackView *displayModeGroup = [[UIStackView alloc] initWithArrangedSubviews:@[displayModeTitle, displayModeDescription, displayMode]];
    displayModeGroup.axis = UILayoutConstraintAxisVertical;
    displayModeGroup.alignment = UIStackViewAlignmentFill;
    displayModeGroup.spacing = 8;

    UIButton *fpsOverlayRow = [self makeSettingsToggleRowWithTitle:@"Show FPS"
                                                             detail:@"Show a compact, measured frame-rate badge during play."
                                                          isEnabled:[self iosFpsOverlayEnabledPreference]
                                                                tag:103
                                                             action:@selector(fpsOverlayRowTapped:)];
    UILabel *fpsCornerTitle = [self settingsLabel:@"FPS Overlay" font:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] color:cream];
    UISegmentedControl *fpsCorner = [[UISegmentedControl alloc] initWithItems:@[@"Top left", @"Top right", @"Bottom left", @"Bottom right"]];
    fpsCorner.translatesAutoresizingMaskIntoConstraints = NO;
    fpsCorner.selectedSegmentIndex = [self iosFpsOverlayCornerPreference];
    fpsCorner.selectedSegmentTintColor = gold;
    fpsCorner.accessibilityLabel = @"FPS Overlay";
    fpsCorner.accessibilityHint = @"Choose which game picture corner holds the FPS badge.";
    [fpsCorner setTitleTextAttributes:@{NSForegroundColorAttributeName: cream,
                                       NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]}
                              forState:UIControlStateNormal];
    [fpsCorner setTitleTextAttributes:@{NSForegroundColorAttributeName: dark,
                                       NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]}
                              forState:UIControlStateSelected];
    [fpsCorner addTarget:self action:@selector(fpsCornerChanged:) forControlEvents:UIControlEventValueChanged];
    [fpsCorner.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIStackView *fpsCornerGroup = [[UIStackView alloc] initWithArrangedSubviews:@[fpsCornerTitle, fpsCorner]];
    fpsCornerGroup.axis = UILayoutConstraintAxisVertical;
    fpsCornerGroup.alignment = UIStackViewAlignmentFill;
    fpsCornerGroup.spacing = 8;

    UILabel *fpsTitle = [self settingsLabel:@"Phone frame rate" font:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] color:cream];
    UILabel *fpsDescription = [self settingsLabel:@"30 FPS holds at 30. Up to 60 FPS is a cap, not a guarantee; demanding scenes may run slower."
                                               font:[UIFont systemFontOfSize:18] color:[cream colorWithAlphaComponent:0.82]];
    fpsDescription.numberOfLines = 0;
    UIStackView *fpsLabels = [[UIStackView alloc] initWithArrangedSubviews:@[fpsTitle, fpsDescription]];
    fpsLabels.axis = UILayoutConstraintAxisVertical;
    fpsLabels.alignment = UIStackViewAlignmentFill;
    fpsLabels.spacing = 5;

    UISegmentedControl *frameRate = [[UISegmentedControl alloc] initWithItems:@[@"30 FPS", @"Up to 60"]];
    frameRate.translatesAutoresizingMaskIntoConstraints = NO;
    frameRate.selectedSegmentIndex = runtime_phone_fps() == 30 ? 0 : 1;
    frameRate.selectedSegmentTintColor = gold;
    frameRate.accessibilityLabel = @"Phone frame rate";
    frameRate.accessibilityHint = @"Choose a 30 FPS cap or up to 60 FPS.";
    [frameRate setTitleTextAttributes:@{NSForegroundColorAttributeName: cream,
                                       NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightMedium]}
                              forState:UIControlStateNormal];
    [frameRate setTitleTextAttributes:@{NSForegroundColorAttributeName: dark,
                                       NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]}
                              forState:UIControlStateSelected];
    [frameRate addTarget:self action:@selector(frameRateChanged:) forControlEvents:UIControlEventValueChanged];
    [frameRate.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;

    UIStackView *frameRateGroup = [[UIStackView alloc] initWithArrangedSubviews:@[fpsLabels, frameRate]];
    frameRateGroup.axis = UILayoutConstraintAxisVertical;
    frameRateGroup.alignment = UIStackViewAlignmentFill;
    frameRateGroup.spacing = 10;

    UIView *spacer = [UIView new];
    UILabel *volumeTitle = [self settingsLabel:@"Master Volume" font:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] color:cream];
    UILabel *volumeValue = [self settingsLabel:[NSString stringWithFormat:@"%ld%%", (long)[self iosMasterVolumePreference]]
                                           font:[UIFont systemFontOfSize:18 weight:UIFontWeightMedium] color:cream];
    volumeValue.textAlignment = NSTextAlignmentRight;
    self.masterVolumeValueLabel = volumeValue;
    UIStackView *volumeHeader = [[UIStackView alloc] initWithArrangedSubviews:@[volumeTitle, spacer, volumeValue]];
    volumeHeader.axis = UILayoutConstraintAxisHorizontal;
    volumeHeader.alignment = UIStackViewAlignmentCenter;
    volumeHeader.spacing = 8;

    UISlider *volumeSlider = [UISlider new];
    volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    volumeSlider.minimumValue = 0;
    volumeSlider.maximumValue = 100;
    volumeSlider.value = (float)[self iosMasterVolumePreference];
    volumeSlider.minimumTrackTintColor = gold;
    volumeSlider.maximumTrackTintColor = [cream colorWithAlphaComponent:0.28];
    volumeSlider.thumbTintColor = gold;
    volumeSlider.accessibilityLabel = @"Master Volume";
    volumeSlider.accessibilityHint = @"Adjusts game volume from silent to full volume.";
    volumeSlider.accessibilityValue = [NSString stringWithFormat:@"%ld percent", (long)[self iosMasterVolumePreference]];
    [volumeSlider addTarget:self action:@selector(masterVolumeChanged:) forControlEvents:UIControlEventValueChanged];
    self.masterVolumeSlider = volumeSlider;
    [volumeSlider.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    UIStackView *volumeGroup = [[UIStackView alloc] initWithArrangedSubviews:@[volumeHeader, volumeSlider]];
    volumeGroup.axis = UILayoutConstraintAxisVertical;
    volumeGroup.alignment = UIStackViewAlignmentFill;
    volumeGroup.spacing = 12;

    UIButton *gyroRow = [self makeSettingsToggleRowWithTitle:@"Phone gyro"
                                                    detail:@"Uses phone motion controls when no controller is connected."
                                                  isEnabled:totk_phone_setting_enabled(@"TOTK_PHONE_GYRO")
                                                     tag:101
                                                  action:@selector(gyroRowTapped:)];
    UIButton *hapticsRow = [self makeSettingsToggleRowWithTitle:@"Phone vibration"
                                                       detail:@"Uses phone vibration when no controller is connected."
                                                     isEnabled:totk_phone_setting_enabled(@"TOTK_PHONE_HAPTICS")
                                                        tag:102
                                                     action:@selector(hapticsRowTapped:)];
    UIButton *swapControllerLayoutRow = [self makeSettingsToggleRowWithTitle:@"Swap Controller Layout"
                                                                      detail:@"Swaps physical A/B and X/Y buttons during gameplay only. Menu and touch controls are unchanged."
                                                                    isEnabled:[NSUserDefaults.standardUserDefaults boolForKey:@"TOTK_SWAP_CONTROLLER_LAYOUT"]
                                                                         tag:104
                                                                      action:@selector(swapControllerLayoutRowTapped:)];

    UIStackView *displayPage = [[UIStackView alloc] initWithArrangedSubviews:@[displayModeGroup, fpsOverlayRow, fpsCornerGroup, frameRateGroup]];
    UIStackView *audioPage = [[UIStackView alloc] initWithArrangedSubviews:@[volumeGroup]];
    UIStackView *controlsPage = [[UIStackView alloc] initWithArrangedSubviews:@[gyroRow, hapticsRow, swapControllerLayoutRow]];
    self.settingsPages = @[displayPage, audioPage, controlsPage];
    self.settingsPageControllerItems = @[
        @[displayMode, fpsOverlayRow, fpsCorner, frameRate],
        @[volumeSlider],
        @[gyroRow, hapticsRow, swapControllerLayoutRow]
    ];
    for (UIStackView *page in self.settingsPages) {
        page.axis = UILayoutConstraintAxisVertical;
        page.alignment = UIStackViewAlignmentFill;
        page.spacing = 14;
        page.translatesAutoresizingMaskIntoConstraints = NO;
    }

    NSArray<NSString *> *tabTitles = @[@"Display", @"Audio", @"Controls"];
    NSArray<NSString *> *tabHints = @[@"Show display and frame-rate settings.", @"Adjust master volume.", @"Show gyro, vibration, and controller layout controls."];
    NSMutableArray<UIButton *> *tabButtons = [NSMutableArray arrayWithCapacity:tabTitles.count];
    UIStackView *tabBar = [[UIStackView alloc] init];
    tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    tabBar.axis = UILayoutConstraintAxisHorizontal;
    tabBar.alignment = UIStackViewAlignmentFill;
    tabBar.distribution = UIStackViewDistributionFillEqually;
    tabBar.spacing = 10;
    for (NSUInteger index = 0; index < tabTitles.count; index++) {
        UIButton *tab = [UIButton buttonWithType:UIButtonTypeCustom];
        tab.translatesAutoresizingMaskIntoConstraints = NO;
        tab.tag = (NSInteger)index;
        tab.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        [tab setTitle:tabTitles[index] forState:UIControlStateNormal];
        tab.accessibilityLabel = tabTitles[index];
        tab.accessibilityHint = tabHints[index];
        tab.accessibilityTraits = UIAccessibilityTraitButton | (index == 0 ? UIAccessibilityTraitSelected : 0);
        [tab setTitleColor:(index == 0 ? gold : cream) forState:UIControlStateNormal];
        tab.accessibilityValue = index == 0 ? @"Selected" : nil;
        [tab addTarget:self action:@selector(settingsTabTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIView *underline = [UIView new];
        underline.translatesAutoresizingMaskIntoConstraints = NO;
        underline.backgroundColor = gold;
        underline.userInteractionEnabled = NO;
        underline.tag = 1001;
        underline.hidden = index != 0;
        [tab addSubview:underline];
        [NSLayoutConstraint activateConstraints:@[
            [underline.leadingAnchor constraintEqualToAnchor:tab.leadingAnchor constant:10],
            [underline.trailingAnchor constraintEqualToAnchor:tab.trailingAnchor constant:-10],
            [underline.bottomAnchor constraintEqualToAnchor:tab.bottomAnchor],
            [underline.heightAnchor constraintEqualToConstant:2]
        ]];
        [tab.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
        [tabBar addArrangedSubview:tab];
        [tabButtons addObject:tab];
    }
    self.settingsTabButtons = tabButtons;
    self.selectedSettingsTab = 0;

    UIScrollView *scrollView = [UIScrollView new];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsVerticalScrollIndicator = YES;
    scrollView.alwaysBounceVertical = NO;
    scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    scrollView.accessibilityElementsHidden = NO;
    scrollView.verticalScrollIndicatorInsets = UIEdgeInsetsMake(4, 0, 4, 0);

    UIStackView *pageContainer = [[UIStackView alloc] initWithArrangedSubviews:@[displayPage]];
    pageContainer.translatesAutoresizingMaskIntoConstraints = NO;
    pageContainer.axis = UILayoutConstraintAxisVertical;
    pageContainer.alignment = UIStackViewAlignmentFill;
    pageContainer.spacing = 0;
    self.settingsPageContainer = pageContainer;
    self.settingsScrollView = scrollView;
    [scrollView addSubview:pageContainer];
    [NSLayoutConstraint activateConstraints:@[
        [pageContainer.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [pageContainer.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [pageContainer.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [pageContainer.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [pageContainer.widthAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.widthAnchor]
    ]];
    [scrollView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close setTitleColor:cream forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    close.backgroundColor = [UIColor colorWithRed:0.48 green:0.39 blue:0.21 alpha:0.24];
    close.layer.borderWidth = 1;
    close.layer.borderColor = [gold colorWithAlphaComponent:0.38].CGColor;
    close.layer.cornerRadius = 8;
    close.accessibilityLabel = @"Close settings";
    close.accessibilityHint = @"Dismisses this panel and returns to the main menu.";
    [close addTarget:self action:@selector(closeSettingsTapped:) forControlEvents:UIControlEventTouchUpInside];
    [close.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    self.settingsCloseButton = close;

    UIStackView *panelContent = [[UIStackView alloc] initWithArrangedSubviews:@[title, tabBar, scrollView, close]];
    panelContent.translatesAutoresizingMaskIntoConstraints = NO;
    panelContent.axis = UILayoutConstraintAxisVertical;
    panelContent.alignment = UIStackViewAlignmentFill;
    panelContent.spacing = 10;
    [card addSubview:panelContent];
    [NSLayoutConstraint activateConstraints:@[
        [panelContent.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:22],
        [panelContent.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-22],
        [panelContent.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [panelContent.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18]
    ]];

    self.settingsFocusIndex = 0;
    [self becomeFirstResponder];
    [self updateControllerFocus];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, title);
}

- (UILabel *)settingsLabel:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.isAccessibilityElement = YES;
    return label;
}

- (void)settingsTabTapped:(UIButton *)sender {
    NSUInteger selected = (NSUInteger)sender.tag;
    NSUInteger previous = self.selectedSettingsTab;
    if (selected >= self.settingsPages.count || selected == previous) return;
    self.settingsScrollView.contentOffset = CGPointZero;
    UIStackView *currentPage = self.settingsPages[previous];
    [self.settingsPageContainer removeArrangedSubview:currentPage];
    [currentPage removeFromSuperview];
    [self.settingsPageContainer addArrangedSubview:self.settingsPages[selected]];
    self.selectedSettingsTab = selected;
    self.settingsFocusIndex = 0;
    for (NSUInteger index = 0; index < self.settingsPages.count; index++) {
        BOOL isSelected = index == selected;
        UIButton *tab = self.settingsTabButtons[index];
        tab.accessibilityTraits = UIAccessibilityTraitButton | (isSelected ? UIAccessibilityTraitSelected : 0);
        tab.accessibilityValue = isSelected ? @"Selected" : nil;
        [tab setTitleColor:(isSelected
            ? [UIColor colorWithRed:0.89 green:0.75 blue:0.48 alpha:1.0]
            : [UIColor colorWithRed:0.94 green:0.92 blue:0.84 alpha:1.0])
                  forState:UIControlStateNormal];
        [tab viewWithTag:1001].hidden = !isSelected;
    }
    [self updateControllerFocus];
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, sender);
}

- (NSInteger)iosMasterVolumePreference {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"TOTK_IOS_MASTER_VOLUME"];
    NSInteger volume = saved ? [saved integerValue] : 100;
    return MAX(0, MIN(100, volume));
}

- (void)applyMasterVolumePreference {
    runtime_audio_master_volume_set((int)[self iosMasterVolumePreference]);
}

- (void)masterVolumeChanged:(UISlider *)slider {
    NSInteger volume = MAX(0, MIN(100, (NSInteger)lroundf(slider.value)));
    [slider setValue:(float)volume animated:NO];
    NSString *value = [NSString stringWithFormat:@"%ld%%", (long)volume];
    self.masterVolumeValueLabel.text = value;
    slider.accessibilityValue = [NSString stringWithFormat:@"%ld percent", (long)volume];
    [NSUserDefaults.standardUserDefaults setInteger:volume forKey:@"TOTK_IOS_MASTER_VOLUME"];
    runtime_audio_master_volume_set((int)volume);
}

- (UIButton *)makeSettingsToggleRowWithTitle:(NSString *)title
                                     detail:(NSString *)detail
                                  isEnabled:(BOOL)isEnabled
                                        tag:(NSInteger)tag
                                     action:(SEL)action {
    UIColor *cream = [UIColor colorWithRed:0.94 green:0.92 blue:0.84 alpha:1.0];
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.backgroundColor = [UIColor colorWithWhite:1 alpha:0.035];
    row.layer.cornerRadius = 8;
    row.layer.borderWidth = 1;
    row.layer.borderColor = [cream colorWithAlphaComponent:0.14].CGColor;
    row.accessibilityLabel = title;
    row.accessibilityValue = isEnabled ? @"On" : @"Off";
    row.accessibilityHint = [NSString stringWithFormat:@"%@ Double-tap to turn %@.", detail, isEnabled ? @"off" : @"on"];
    row.accessibilityTraits = UIAccessibilityTraitButton | (isEnabled ? UIAccessibilityTraitSelected : 0);
    [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    UILabel *name = [self settingsLabel:title font:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] color:cream];
    name.isAccessibilityElement = NO;
    UILabel *description = [self settingsLabel:detail font:[UIFont systemFontOfSize:18] color:[cream colorWithAlphaComponent:0.78]];
    description.numberOfLines = 0;
    description.isAccessibilityElement = NO;
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[name, description]];
    labels.translatesAutoresizingMaskIntoConstraints = NO;
    labels.userInteractionEnabled = NO;
    labels.axis = UILayoutConstraintAxisVertical;
    labels.alignment = UIStackViewAlignmentFill;
    labels.spacing = 4;
    [row addSubview:labels];

    UISwitch *toggle = [UISwitch new];
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    [toggle setOn:isEnabled animated:NO];
    toggle.tag = tag;
    toggle.userInteractionEnabled = NO;
    toggle.isAccessibilityElement = NO;
    [row addSubview:toggle];

    [NSLayoutConstraint activateConstraints:@[
        [labels.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:16],
        [labels.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
        [labels.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
        [labels.trailingAnchor constraintLessThanOrEqualToAnchor:toggle.leadingAnchor constant:-12],
        [toggle.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-16],
        [toggle.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:84]
    ]];
    return row;
}

- (BOOL)iosFpsOverlayEnabledPreference {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"TOTK_IOS_SHOW_FPS"];
    return saved ? [saved boolValue] : YES;
}

- (NSInteger)iosFpsOverlayCornerPreference {
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:@"TOTK_IOS_FPS_CORNER"];
    NSInteger corner = saved ? [saved integerValue] : FPS_OVERLAY_CORNER_TOP_RIGHT;
    return corner >= FPS_OVERLAY_CORNER_TOP_LEFT && corner <= FPS_OVERLAY_CORNER_BOTTOM_RIGHT
        ? corner : FPS_OVERLAY_CORNER_TOP_RIGHT;
}

- (void)applyFpsOverlayPreferences {
    fps_overlay_set_ios_preferences([self iosFpsOverlayEnabledPreference], (int)[self iosFpsOverlayCornerPreference]);
}

- (void)fpsOverlayRowTapped:(UIButton *)row {
    UISwitch *toggle = (UISwitch *)[row viewWithTag:103];
    if (!toggle) return;
    BOOL enabled = !toggle.isOn;
    [toggle setOn:enabled animated:YES];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"TOTK_IOS_SHOW_FPS"];
    row.accessibilityValue = enabled ? @"On" : @"Off";
    row.accessibilityHint = [NSString stringWithFormat:@"Show a compact, measured frame-rate badge during play. Double-tap to turn %@.", enabled ? @"off" : @"on"];
    row.accessibilityTraits = UIAccessibilityTraitButton | (enabled ? UIAccessibilityTraitSelected : 0);
    [self applyFpsOverlayPreferences];
}

- (void)fpsCornerChanged:(UISegmentedControl *)control {
    NSInteger corner = control.selectedSegmentIndex;
    if (corner < FPS_OVERLAY_CORNER_TOP_LEFT || corner > FPS_OVERLAY_CORNER_BOTTOM_RIGHT) return;
    [NSUserDefaults.standardUserDefaults setInteger:corner forKey:@"TOTK_IOS_FPS_CORNER"];
    [self applyFpsOverlayPreferences];
}

- (void)frameRateChanged:(UISegmentedControl *)control {
    int fps = control.selectedSegmentIndex == 0 ? 30 : 60;
    runtime_phone_fps_set(fps);
    [NSUserDefaults.standardUserDefaults setObject:(fps == 30 ? @"30" : @"60") forKey:@"TOTK_PHONE_FPS"];
}

- (void)displayModeChanged:(UISegmentedControl *)control {
    [NSUserDefaults.standardUserDefaults setBool:control.selectedSegmentIndex == 1 forKey:@"TOTK_DOCKED"];
}

- (void)gyroRowTapped:(UIButton *)row {
    [self setPreferenceToggleRow:row key:@"TOTK_PHONE_GYRO"];
}

- (void)hapticsRowTapped:(UIButton *)row {
    [self setPreferenceToggleRow:row key:@"TOTK_PHONE_HAPTICS"];
}

- (void)swapControllerLayoutRowTapped:(UIButton *)row {
    [self setPreferenceToggleRow:row key:@"TOTK_SWAP_CONTROLLER_LAYOUT"];
}

- (void)setPreferenceToggleRow:(UIButton *)row key:(NSString *)key {
    UISwitch *toggle = [self toggleControlInRow:row];
    if (!toggle) return;
    BOOL enabled = !toggle.isOn;
    [toggle setOn:enabled animated:YES];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:key];
    setenv(key.UTF8String, enabled ? "1" : "0", 1);
    row.accessibilityValue = enabled ? @"On" : @"Off";
    row.accessibilityHint = [NSString stringWithFormat:@"%@ Double-tap to turn %@.",
                             row.accessibilityLabel, enabled ? @"off" : @"on"];
    row.accessibilityTraits = UIAccessibilityTraitButton | (enabled ? UIAccessibilityTraitSelected : 0);
}

- (void)settingsScrimTapped:(UIControl *)sender {
    (void)sender;
    [self closeSettings];
}

- (void)closeSettingsTapped:(UIButton *)sender {
    (void)sender;
    [self closeSettings];
}

- (void)closeSettingsFromKeyboard:(UIKeyCommand *)command {
    (void)command;
    [self closeSettings];
}

- (void)closeSettings {
    UIControl *overlay = self.settingsOverlay;
    if (!overlay) return;
    self.settingsOverlay = nil;
    self.settingsCloseButton = nil;
    self.playButton.accessibilityElementsHidden = NO;
    self.settingsButton.accessibilityElementsHidden = NO;
    self.launcherFocusIndex = 1;
    [overlay removeFromSuperview];
    [self resignFirstResponder];
    [self updateControllerFocus];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.settingsButton);
}

- (void)stopPlayback {
    [self stopControllerPolling];
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
    [self.controllerPollTimer invalidate];
    if (self.observingLifecycle) [NSNotificationCenter.defaultCenter removeObserver:self];
    [self.player pause];
    [self.playerLooper disableLooping];
    [self.player removeAllItems];
}

@end
