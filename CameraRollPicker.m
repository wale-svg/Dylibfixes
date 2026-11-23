// ============================================================
// CameraRollPicker.m
// Floating green camera-roll button that follows the top-most
// view controller, so it stays visible above ANY page that covers
// the app (web views, pushed controllers, modals, tab switches,
// etc.). No overlay UIWindow is created, so host app touches
// remain fully functional.
// Tap -> PHPickerViewController (images + videos).
// Selected media delivered via delegate forwarding and
// NSNotification.
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
static id gActivePickerDelegate = nil;

// ============================================================
// 1. Top-most view controller (walks entire presented chain)
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
// 4. Re-attach button to the current top-most view
// ============================================================
static void installFloatingButton(void); // forward decl

static void reattachFloatingButton(void) {
    if (!gFloatingButton) { installFloatingButton(); return; }
    UIViewController *top = topViewController();
    if (!top || !top.view) return;
    UIView *targetView = top.view;
    if (gFloatingButton.superview == targetView) return;

    [gFloatingButton removeFromSuperview];

    // Remove constraints referencing the button from the old superview
    UIView *oldSuper = gFloatingButton.superview;
    if (oldSuper) {
        for (NSLayoutConstraint *c in [oldSuper.constraints copy]) {
            if (c.firstItem == gFloatingButton || c.secondItem == gFloatingButton) {
                [oldSuper removeConstraint:c];
            }
        }
    }

    [targetView addSubview:gFloatingButton];
    [targetView bringSubviewToFront:gFloatingButton];

    CGFloat size = 56.0;
    UILayoutGuide *safe = targetView.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [gFloatingButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [gFloatingButton.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [gFloatingButton.widthAnchor constraintEqualToConstant:size],
        [gFloatingButton.heightAnchor constraintEqualToConstant:size]
    ]];
}

// ============================================================
// 5. Install the button (created once, then attached to top view)
// ============================================================
static void installFloatingButton(void) {
    if (gFloatingButton) { reattachFloatingButton(); return; }

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

    reattachFloatingButton();
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
// 8. Keep button on top across ALL page transitions
//    (web views, pushed controllers, modals, tab switches, etc.)
// ============================================================
@interface UIViewController (FloatingButtonFollow)
@end
@implementation UIViewController (FloatingButtonFollow)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIViewController class];

        Method m1 = class_getInstanceMethod(cls, @selector(viewDidAppear:));
        Method m2 = class_getInstanceMethod(cls, @selector(swz_viewDidAppear:));
        method_exchangeImplementations(m1, m2);

        Method m3 = class_getInstanceMethod(cls, @selector(viewDidLayoutSubviews));
        Method m4 = class_getInstanceMethod(cls, @selector(swz_viewDidLayoutSubviews));
        method_exchangeImplementations(m3, m4);

        Method m5 = class_getInstanceMethod(cls, @selector(dismissViewControllerAnimated:completion:));
        Method m6 = class_getInstanceMethod(cls, @selector(swz_dismissViewControllerAnimated:completion:));
        method_exchangeImplementations(m5, m6);
    });
}

- (void)swz_viewDidAppear:(BOOL)animated {
    [self swz_viewDidAppear:animated];
    dispatch_async(dispatch_get_main_queue(), ^{ reattachFloatingButton(); });
}

- (void)swz_viewDidLayoutSubviews {
    [self swz_viewDidLayoutSubviews];
    dispatch_async(dispatch_get_main_queue(), ^{ reattachFloatingButton(); });
}

- (void)swz_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    [self swz_dismissViewControllerAnimated:flag completion:^{
        if (completion) completion();
        dispatch_async(dispatch_get_main_queue(), ^{ reattachFloatingButton(); });
    }];
}

@end

// ============================================================
// 9. Install button on app launch
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
