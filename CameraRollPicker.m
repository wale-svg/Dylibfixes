// ============================================================
// CameraRollPicker.m
// Floating green button on left safe-area edge (portrait + landscape).
// Tap -> PHPickerViewController (images + videos).
// Overlay window passes through touches so the host app stays fully
// interactive. Selected media is delivered via delegate forwarding
// and NSNotification.
// Compile: clang -arch arm64 -arch arm64e -shared -o CameraRollPicker.dylib \
//   CameraRollPicker.m -framework Foundation -framework UIKit \
//   -framework PhotosUI -framework AVFoundation -fobjc-arc
// Inject: optool install -c load -p "@executable_path/CameraRollPicker.dylib" -t AppBinary
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static UIImagePickerController *gActiveImagePicker = nil;
static id gActiveImagePickerDelegate = nil;
static AVCapturePhotoOutput *gActivePhotoOutput = nil;
static UIButton *gFloatingButton = nil;
static UIWindow *gOverlayWindow = nil;
static id gActivePickerDelegate = nil;

// ============================================================
// 1. Top-most view controller
// ============================================================
static UIViewController *topViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { keyWindow = w; break; }
            }
        }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ============================================================
// 2. Deliver selected image to active camera consumer
// ============================================================
static void deliverImage(UIImage *image) {
    if (!image) return;
    if (gActiveImagePicker && gActiveImagePickerDelegate &&
        [gActiveImagePickerDelegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
        NSDictionary *info = @{
            UIImagePickerControllerOriginalImage: image,
            UIImagePickerControllerMediaType: @"public.image"
        };
        [(id<UIImagePickerControllerDelegate>)gActiveImagePickerDelegate
            imagePickerController:gActiveImagePicker
            didFinishPickingMediaWithInfo:info];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerImageSelected"
                                                        object:image];
}

// ============================================================
// 3. PHPicker delegate (images + videos)
// ============================================================
@interface CameraRollOverlayDelegate : NSObject <PHPickerViewControllerDelegate>
@end

@implementation CameraRollOverlayDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) return;
    NSItemProvider *provider = results.firstObject.itemProvider;

    if ([provider canLoadObjectOfClass:[UIImage class]]) {
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *err) {
            if (img) dispatch_async(dispatch_get_main_queue(), ^{ deliverImage(img); });
        }];
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [provider loadItemForTypeIdentifier:@"public.movie" options:nil completionHandler:^(id item, NSError *err) {
            if (!item) return;
            NSURL *url = [item isKindOfClass:[NSURL class]] ? item : [NSURL URLWithString:[item description]];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerVideoSelected"
                                                                object:url];
        }];
    }
}

@end

// ============================================================
// 4. Passthrough container view – only the button receives touches
// ============================================================
@interface PassthroughView : UIView
@property (nonatomic, weak) UIView *interactiveSubview;
@end

@implementation PassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.interactiveSubview) {
        CGPoint p = [self.interactiveSubview convertPoint:point fromView:self];
        if ([self.interactiveSubview pointInside:p withEvent:event]) {
            return [self.interactiveSubview hitTest:p withEvent:event];
        }
    }
    return nil; // touches fall through to the app window
}
@end

// ============================================================
// 5. Floating green button with Auto Layout (orientation-safe)
//    Installed in a passthrough overlay window that never becomes key.
// ============================================================
static void installFloatingButton(void) {
    if (gFloatingButton) return;
    UIWindowScene *scene = nil;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) { scene = (UIWindowScene *)s; break; }
    }
    if (!scene) return;

    UIWindow *previousKey = nil;
    for (UIWindow *w in scene.windows) {
        if (w.isKeyWindow) { previousKey = w; break; }
    }

    gOverlayWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gOverlayWindow.windowLevel = UIWindowLevelAlert + 10;
    gOverlayWindow.backgroundColor = [UIColor clearColor];
    gOverlayWindow.rootViewController = [[UIViewController alloc] init];

    PassthroughView *container = [[PassthroughView alloc] initWithFrame:gOverlayWindow.bounds];
    container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    container.backgroundColor = [UIColor clearColor];
    gOverlayWindow.rootViewController.view = container;

    gOverlayWindow.hidden = NO;
    if (previousKey) [previousKey makeKeyWindow];

    CGFloat size = 56.0;
    gFloatingButton = [UIButton buttonWithType:UIButtonTypeCustom];
    gFloatingButton.translatesAutoresizingMaskIntoConstraints = NO;
    gFloatingButton.backgroundColor = [UIColor colorWithRed:0.0 green:0.75 blue:0.25 alpha:0.95];
    gFloatingButton.layer.cornerRadius = size / 2;
    gFloatingButton.layer.borderWidth = 2.0;
    gFloatingButton.layer.borderColor = [UIColor whiteColor].CGColor;
    [gFloatingButton setTitle:@"📷" forState:UIControlStateNormal];
    gFloatingButton.titleLabel.font = [UIFont systemFontOfSize:26];

    UIAction *action = [UIAction actionWithHandler:^(__kindof UIAction *a) {
        PHPickerConfiguration *cfg = [[PHPickerConfiguration alloc] init];
        cfg.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[[PHPickerFilter imagesFilter], [PHPickerFilter videosFilter]]];
        cfg.selectionLimit = 1;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:cfg];
        if (!gActivePickerDelegate) gActivePickerDelegate = [[CameraRollOverlayDelegate alloc] init];
        picker.delegate = gActivePickerDelegate;
        [topViewController() presentViewController:picker animated:YES completion:nil];
    }];
    [gFloatingButton addAction:action forControlEvents:UIControlEventTouchUpInside];

    [container addSubview:gFloatingButton];
    container.interactiveSubview = gFloatingButton;

    UILayoutGuide *safe = container.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [gFloatingButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [gFloatingButton.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [gFloatingButton.widthAnchor constraintEqualToConstant:size],
        [gFloatingButton.heightAnchor constraintEqualToConstant:size]
    ]];

    NSLog(@"[CameraRollPicker] Floating button installed – passthrough window, app remains interactive.");
}

// ============================================================
// 6. Hook UIImagePickerController presentation
// ============================================================
@interface UIViewController (CameraRollHook)
@end
@implementation UIViewController (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIViewController class];
        Method m1 = class_getInstanceMethod(cls, @selector(presentViewController:animated:completion:));
        Method m2 = class_getInstanceMethod(cls, @selector(swz_presentViewController:animated:completion:));
        method_exchangeImplementations(m1, m2);
    });
}
- (void)swz_presentViewController:(UIViewController *)vc animated:(BOOL)a completion:(void (^)(void))c {
    if ([vc isKindOfClass:[UIImagePickerController class]]) {
        UIImagePickerController *p = (UIImagePickerController *)vc;
        if (p.sourceType == UIImagePickerControllerSourceTypeCamera) {
            gActiveImagePicker = p;
            gActiveImagePickerDelegate = p.delegate;
        }
    }
    [self swz_presentViewController:vc animated:a completion:c];
}
@end

// ============================================================
// 7. Capture AVCapturePhotoOutput instances
// ============================================================
@interface AVCapturePhotoOutput (CameraRollHook)
@end
@implementation AVCapturePhotoOutput (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [AVCapturePhotoOutput class];
        Method m1 = class_getInstanceMethod(cls, @selector(init));
        Method m2 = class_getInstanceMethod(cls, @selector(swz_init));
        method_exchangeImplementations(m1, m2);
    });
}
- (instancetype)swz_init {
    id obj = [self swz_init];
    if (obj) gActivePhotoOutput = obj;
    return obj;
}
@end

// ============================================================
// 8. Install button on app launch
// ============================================================
__attribute__((constructor)) static void initCameraRollPicker(void) {
    NSLog(@"[CameraRollPicker] Loaded.");
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installFloatingButton();
        });
    }];
}
