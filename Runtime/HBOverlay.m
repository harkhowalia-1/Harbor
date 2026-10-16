// The keymap editor and hint overlay: a transparent window above the app.
// ⌘⇧K opens the editor. Click to place a button, drag to move it, press a key or a
// controller button to bind it, ⌫ deletes, Esc (or ⌘⇧K again) saves and closes.
#import "HBRuntime.h"

enum { kHBKeyEsc = 53, kHBKeyDelete = 51, kHBKeyForwardDelete = 117, kHBKeyEquals = 24, kHBKeyMinus = 27 };

@interface HBOverlayWindow : UIWindow
@end

@implementation HBOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Hints are look-only: clicks fall through to the app.
    return HBOverlay.shared.editing ? [super hitTest:point withEvent:event] : nil;
}
@end

#pragma mark - Element view

@interface HBElementView : UIView
@property (nonatomic, strong) NSMutableDictionary *element;
@property (nonatomic, strong) UILabel *label;
@property (nonatomic) BOOL selected;
@end

@implementation HBElementView

- (instancetype)initWithElement:(NSMutableDictionary *)element {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _element = element;
    _label = [[UILabel alloc] init];
    _label.textAlignment = NSTextAlignmentCenter;
    _label.textColor = UIColor.whiteColor;
    _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _label.numberOfLines = 2;
    _label.adjustsFontSizeToFitWidth = YES;
    [self addSubview:_label];
    self.layer.borderWidth = 2;
    self.userInteractionEnabled = NO;
    [self refresh];
    return self;
}

- (BOOL)isJoystick { return [_element[@"type"] isEqual:@"joystick"]; }

- (void)refresh {
    NSMutableArray *parts = [NSMutableArray array];
    if (self.isJoystick) {
        NSDictionary *keys = _element[@"keys"];
        if ([keys[@"up"] isEqual:@126]) [parts addObject:@"↑←↓→"];
        else if (keys) {
            [parts addObject:[NSString stringWithFormat:@"%@%@%@%@", HBKeyLabel([keys[@"up"] intValue]),
                              HBKeyLabel([keys[@"left"] intValue]), HBKeyLabel([keys[@"down"] intValue]),
                              HBKeyLabel([keys[@"right"] intValue])]];
        }
    } else if (_element[@"key"]) {
        [parts addObject:_element[@"label"] ?: HBKeyLabel([_element[@"key"] intValue])];
    }
    if (_element[@"controller"]) [parts addObject:[self controllerName:_element[@"controller"]]];
    _label.text = parts.count ? [parts componentsJoinedByString:@"\n"] : @"press a key";
    [self updateColors];
}

- (NSString *)controllerName:(NSString *)name {
    NSDictionary *short_ = @{@"buttonA": @"Ⓐ", @"buttonB": @"Ⓑ", @"buttonX": @"Ⓧ", @"buttonY": @"Ⓨ",
                             @"leftShoulder": @"LB", @"rightShoulder": @"RB", @"leftTrigger": @"LT",
                             @"rightTrigger": @"RT", @"leftThumbstick": @"L-stick", @"rightThumbstick": @"R-stick"};
    return short_[name] ?: name;
}

- (void)setSelected:(BOOL)selected {
    _selected = selected;
    [self updateColors];
}

- (void)updateColors {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:self.isJoystick ? 0.25 : 0.45];
    self.layer.borderColor = (_selected ? UIColor.systemYellowColor : [UIColor colorWithWhite:1 alpha:0.85]).CGColor;
}

- (void)placeIn:(CGSize)size {
    CGFloat diameter = self.isJoystick ? 2 * ([_element[@"radius"] doubleValue] ?: 0.12) * MIN(size.width, size.height) : 52;
    self.bounds = CGRectMake(0, 0, diameter, diameter);
    self.center = CGPointMake([_element[@"x"] doubleValue] * size.width, [_element[@"y"] doubleValue] * size.height);
    self.layer.cornerRadius = diameter / 2;
    _label.frame = CGRectInset(self.bounds, 4, 4);
}

@end

#pragma mark - Editor canvas

@interface HBOverlay ()
- (void)canvasBegan:(UITouch *)touch;
- (void)canvasMoved:(UITouch *)touch;
- (void)canvasEnded:(UITouch *)touch;
@end

@interface HBEditorCanvas : UIView
@end

@implementation HBEditorCanvas
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [HBOverlay.shared canvasBegan:touches.anyObject];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [HBOverlay.shared canvasMoved:touches.anyObject];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [HBOverlay.shared canvasEnded:touches.anyObject];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    for (UIView *view in self.subviews) {
        if ([view isKindOfClass:HBElementView.class]) [(HBElementView *)view placeIn:self.bounds.size];
    }
}
@end

#pragma mark - Overlay

@implementation HBOverlay {
    HBOverlayWindow *_window;
    HBEditorCanvas *_canvas;
    UIView *_banner;
    NSMutableArray<HBElementView *> *_views;
    HBElementView *_selected;
    HBElementView *_dragging;
    CGPoint _dragOffset;
}

+ (HBOverlay *)shared {
    static HBOverlay *overlay;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ overlay = [[HBOverlay alloc] init]; });
    return overlay;
}

- (BOOL)ensureWindow {
    if (_window) return YES;
    UIWindow *app = HBAppWindow();
    if (!app.windowScene) return NO;
    _window = [[HBOverlayWindow alloc] initWithWindowScene:app.windowScene];
    _window.windowLevel = UIWindowLevelAlert + 10;
    _window.backgroundColor = UIColor.clearColor;
    UIViewController *root = [[UIViewController alloc] init];
    root.view.backgroundColor = UIColor.clearColor;
    _window.rootViewController = root;
    _canvas = [[HBEditorCanvas alloc] initWithFrame:root.view.bounds];
    _canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:_canvas];
    _banner = [self makeBanner];
    [root.view addSubview:_banner];
    [self pinBanner];
    _views = [NSMutableArray array];
    return YES;
}

- (UIView *)makeBanner {
    UIVisualEffectView *panel =
        [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
    panel.layer.cornerRadius = 12;
    panel.clipsToBounds = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel.contentView addSubview:stack];

    UILabel *help = [[UILabel alloc] init];
    help.numberOfLines = 0;
    help.textColor = UIColor.whiteColor;
    help.font = [UIFont systemFontOfSize:12];
    NSMutableAttributedString *text = [[NSMutableAttributedString alloc]
        initWithString:@"Keymap editor\n"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightBold]}];
    [text appendAttributedString:[[NSAttributedString alloc]
        initWithString:@"Click to add a button, drag to move. Select one, then press a key or a controller "
                       @"button to bind it. Joystick: WASD, IJKL or arrows to rebind, +/− to resize. "
                       @"⌫ deletes. Esc saves."]];
    help.attributedText = text;
    [stack addArrangedSubview:help];

    UIStackView *buttons = [[UIStackView alloc] init];
    buttons.spacing = 8;
    buttons.distribution = UIStackViewDistributionFillEqually;
    [buttons addArrangedSubview:[self bannerButton:@"Add joystick" action:@selector(addJoystick)]];
    [buttons addArrangedSubview:[self bannerButton:@"Clear all" action:@selector(clearAll)]];
    [buttons addArrangedSubview:[self bannerButton:@"Done" action:@selector(toggleEditor)]];
    [stack addArrangedSubview:buttons];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:panel.contentView.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:panel.contentView.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:panel.contentView.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:panel.contentView.trailingAnchor constant:-12],
    ]];
    return panel;
}

- (void)pinBanner {
    UIView *root = _banner.superview;
    [NSLayoutConstraint activateConstraints:@[
        [_banner.topAnchor constraintEqualToAnchor:root.safeAreaLayoutGuide.topAnchor constant:8],
        [_banner.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:8],
        [_banner.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-8],
    ]];
}

- (UIButton *)bannerButton:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.tintColor = UIColor.systemYellowColor;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

#pragma mark Modes

- (void)toggleEditor {
    if (![self ensureWindow]) return;
    _editing = !_editing;
    if (_editing) {
        [HBTouchInjector.shared endAll];
        [self rebuildViews];
    } else {
        HBKeymap.shared.elements = [_views valueForKey:@"element"];
        [HBKeymap.shared save];
        [self select:nil];
        HBLog(@"Keymap saved: %lu controls", (unsigned long)HBKeymap.shared.elements.count);
    }
    [self refreshVisibility];
}

- (void)setShowsHints:(BOOL)showsHints {
    _showsHints = showsHints;
    if (showsHints && ![self ensureWindow]) {
        // The app window may not exist yet at launch; try again shortly.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self->_showsHints) self.showsHints = YES;
        });
        return;
    }
    if (showsHints) [self rebuildViews];
    [self refreshVisibility];
}

- (void)reload {
    [HBKeymap.shared load];
    if (_window) [self rebuildViews];
}

- (void)refreshVisibility {
    BOOL visible = _editing || (_showsHints && HBKeymap.shared.elements.count > 0);
    _window.hidden = !visible;
    _banner.hidden = !_editing;
    _canvas.backgroundColor = _editing ? [UIColor colorWithWhite:0 alpha:0.3] : UIColor.clearColor;
    _canvas.alpha = _editing ? 1 : 0.4;
}

- (void)rebuildViews {
    for (UIView *view in _views) [view removeFromSuperview];
    [_views removeAllObjects];
    for (NSMutableDictionary *element in HBKeymap.shared.elements) [self addViewFor:element];
}

- (HBElementView *)addViewFor:(NSMutableDictionary *)element {
    HBElementView *view = [[HBElementView alloc] initWithElement:element];
    [_canvas addSubview:view];
    [_views addObject:view];
    [view placeIn:_canvas.bounds.size];
    return view;
}

- (void)select:(HBElementView *)view {
    _selected.selected = NO;
    _selected = view;
    view.selected = YES;
}

#pragma mark Editing

- (CGPoint)normalized:(CGPoint)point {
    CGSize size = _canvas.bounds.size;
    return CGPointMake(fmin(fmax(point.x / size.width, 0), 1), fmin(fmax(point.y / size.height, 0), 1));
}

- (void)canvasBegan:(UITouch *)touch {
    CGPoint point = [touch locationInView:_canvas];
    for (HBElementView *view in _views.reverseObjectEnumerator) {
        if (hypot(point.x - view.center.x, point.y - view.center.y) <= view.bounds.size.width / 2) {
            [self select:view];
            _dragging = view;
            _dragOffset = CGPointMake(point.x - view.center.x, point.y - view.center.y);
            return;
        }
    }
    CGPoint n = [self normalized:point];
    NSMutableDictionary *element = [@{@"type": @"button", @"x": @(n.x), @"y": @(n.y)} mutableCopy];
    [self select:[self addViewFor:element]];
    _dragging = nil;
}

- (void)canvasMoved:(UITouch *)touch {
    if (!_dragging) return;
    CGPoint point = [touch locationInView:_canvas];
    CGPoint n = [self normalized:CGPointMake(point.x - _dragOffset.x, point.y - _dragOffset.y)];
    _dragging.element[@"x"] = @(n.x);
    _dragging.element[@"y"] = @(n.y);
    [_dragging placeIn:_canvas.bounds.size];
}

- (void)canvasEnded:(UITouch *)touch {
    _dragging = nil;
}

- (void)addJoystick {
    NSMutableDictionary *element = [@{
        @"type": @"joystick", @"x": @0.2, @"y": @0.75, @"radius": @0.14,
        @"keys": @{@"up": @13, @"left": @0, @"down": @1, @"right": @2},
    } mutableCopy];
    [self select:[self addViewFor:element]];
}

- (void)clearAll {
    for (UIView *view in _views) [view removeFromSuperview];
    [_views removeAllObjects];
    _selected = nil;
}

- (void)editorKey:(uint16_t)keyCode label:(NSString *)label {
    if (keyCode == kHBKeyEsc) {
        [self toggleEditor];
        return;
    }
    if (!_selected) return;
    if (keyCode == kHBKeyDelete || keyCode == kHBKeyForwardDelete) {
        [_selected removeFromSuperview];
        [_views removeObject:_selected];
        _selected = nil;
        return;
    }
    NSMutableDictionary *element = _selected.element;
    if (_selected.isJoystick) {
        NSDictionary *sets = @{
            @13: @{@"up": @13, @"left": @0, @"down": @1, @"right": @2},     // W A S D
            @34: @{@"up": @34, @"left": @38, @"down": @40, @"right": @37},  // I J K L
            @126: @{@"up": @126, @"left": @123, @"down": @125, @"right": @124}, // arrows
        };
        NSDictionary *aliases = @{@0: @13, @1: @13, @2: @13, @38: @34, @40: @34, @37: @34, @123: @126, @124: @126, @125: @126};
        NSNumber *setKey = aliases[@(keyCode)] ?: @(keyCode);
        if (sets[setKey]) element[@"keys"] = sets[setKey];
        double radius = [element[@"radius"] doubleValue] ?: 0.12;
        if (keyCode == kHBKeyEquals) element[@"radius"] = @(fmin(radius + 0.02, 0.4));
        if (keyCode == kHBKeyMinus) element[@"radius"] = @(fmax(radius - 0.02, 0.05));
    } else {
        element[@"key"] = @(keyCode);
        element[@"label"] = label;
    }
    [_selected refresh];
    [_selected placeIn:_canvas.bounds.size];
}

- (void)editorControllerInput:(NSString *)name {
    if (!_selected) return;
    BOOL stick = [name hasSuffix:@"Thumbstick"];
    if (_selected.isJoystick != stick) return;
    _selected.element[@"controller"] = name;
    [_selected refresh];
}

@end
