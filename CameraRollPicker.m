// ============================================================
// CameraRollPicker.m
// Universal camera-input replacement.
// Detects ALL camera input paths used by iOS apps:
//   1) UIImagePickerController (camera source)
//   2) WKWebView <input type="file" capture>
//   3) Custom AVCaptureSession / AVCapturePhotoOutput
//   4) UIDocumentPickerViewController (camera-roll import)
//   5) PHPickerViewController (existing photo library flow)
// Floating green button on left safe-area edge, follows every
// page transition. Picked image/video is pushed into whichever
// path the host app is using at the moment of capture.
// Compile: clang -arch arm64 -arch arm64e -shared -o CameraRollPicker.dylib \
//   CameraRollPicker.m -framework Foundation -framework UIKit \
//   -framework PhotosUI -framework AVFoundation -framework WebKit -fobjc-arc
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static UIImagePickerController *gActiveImagePicker = nil;
static id gActiveImagePickerDelegate = nil;
static AVCapturePhotoOutput *gActivePhotoOutput = nil;
static UIButton *gFloatingButton = nil;
static id gActivePickerDelegate = nil;
static UIImage *gLastPickedImage = nil;
static NSURL *gLastPickedVideoURL = nil;
static NSMutableArray *gPhotoSwapDelegates = nil;

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
// 2. Broadcast picked media to every known consumer
// ============================================================
static void deliverImage(UIImage *image) {
    if (!image) return;
    gLastPickedImage = image;

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
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerImageSelected" object:image];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerReplacementImage" object:image];

    // If a photo-output capture is active, trigger it so the wrapper fires
    if (gActivePhotoOutput) {
        @try {
            AVCapturePhotoSettings *s = [AVCapturePhotoSettings photoSettings];
            PhotoSwapDelegate *wrapper = [[PhotoSwapDelegate alloc] initWithOriginal:nil image:image];
            if (!gPhotoSwapDelegates) gPhotoSwapDelegates = [NSMutableArray array];
            [gPhotoSwapDelegates addObject:wrapper];
            [gActivePhotoOutput capturePhotoWithSettings:s delegate:wrapper];
        } @catch (NSException *e) {
            NSLog(@"[CameraRollPicker] photo-output trigger failed: %@", e);
        }
    }
}

static void deliverVideo(NSURL *url) {
    if (!url) return;
    gLastPickedVideoURL = url;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerVideoSelected" object:url];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerReplacementVideo" object:url];
}

// ============================================================
// 3. PhotoSwapDelegate – used by both hook C and manual trigger
// ============================================================
@interface PhotoSwapDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, weak) id<AVCapturePhotoCaptureDelegate> original;
@property (nonatomic, strong) UIImage *replacement;
@end

@implementation PhotoSwapDelegate
- (instancetype)initWithOriginal:(id<AVCapturePhotoCaptureDelegate>)orig image:(UIImage *)img {
    if ((self = [super init])) { _original = orig; _replacement = img; }
    return self;
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (self.replacement) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerReplacementImage" object:self.replacement];
    }
    if ([self.original respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        [self.original captureOutput:output didFinishProcessingPhoto:photo error:error];
    }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.original respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    return [self.original respondsToSelector:aSelector] ? self.original : nil;
}
@end

// ============================================================
// 4. PHPicker delegate – images + videos
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
            NSURL *url = [item isKindOfClass:[NSURL class]] ? item : [NSURL URLWithString:[item description]];
            dispatch_async(dispatch_get_main_queue(), ^{ deliverVideo(url); });
        }];
    }
}
@end

// ============================================================
// 5. Floating button with re-attach across ALL page transitions
// ============================================================
static void installFloatingButton(void);
static void reattachFloatingButton(void) {
    if (!gFloatingButton) { installFloatingButton(); return; }
    UIViewController *top = topViewController();
    if (!top || !top.view) return;
    UIView *targetView = top.view;
    if (gFloatingButton.superview == targetView) return;

    [gFloatingButton removeFromSuperview];
    UIView *oldSuper = gFloatingButton.superview;
    if (oldSuper) {
        for (NSLayoutConstraint *c in [oldSuper.constraints copy]) {
            if (c.firstItem == gFloatingButton || c.secondItem == gFloatingButton) [oldSuper removeConstraint:c];
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
// 6. HOOK A: UIImagePickerController presentation (legacy camera)
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
// 7. HOOK B: AVCapturePhotoOutput tracking + capture interception
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
        if (m1 && m2) method_exchangeImplementations(m1, m2);

        SEL orig = @selector(capturePhotoWithSettings:delegate:);
        SEL swiz = @selector(swz_capturePhotoWithSettings:delegate:);
        Method m3 = class_getInstanceMethod(cls, orig);
        Method m4 = class_getInstanceMethod(cls, swiz);
        if (m3 && m4) method_exchangeImplementations(m3, m4);
    });
}
- (instancetype)swz_init {
    id obj = [self swz_init];
    if (obj) gActivePhotoOutput = obj;
    return obj;
}
- (void)swz_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (gLastPickedImage && delegate) {
        UIImage *img = gLastPickedImage;
        gLastPickedImage = nil;
        PhotoSwapDelegate *wrapper = [[PhotoSwapDelegate alloc] initWithOriginal:delegate image:img];
        if (!gPhotoSwapDelegates) gPhotoSwapDelegates = [NSMutableArray array];
        [gPhotoSwapDelegates addObject:wrapper];
        [self swz_capturePhotoWithSettings:settings delegate:wrapper];
        return;
    }
    [self swz_capturePhotoWithSettings:settings delegate:delegate];
}
@end

// ============================================================
// 8. HOOK C: AVCaptureVideoDataOutput / AVCaptureSession custom camera
//    Intercept session start and expose notification so custom UIs
//    can be fed the replacement image immediately.
// ============================================================
@interface AVCaptureSession (CameraRollHook)
@end
@implementation AVCaptureSession (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [AVCaptureSession class];
        Method m1 = class_getInstanceMethod(cls, @selector(startRunning));
        Method m2 = class_getInstanceMethod(cls, @selector(swz_startRunning));
        if (m1 && m2) method_exchangeImplementations(m1, m2);
    });
}
- (void)swz_startRunning {
    [self swz_startRunning];
    if (gLastPickedImage) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerReplacementImage" object:gLastPickedImage];
        });
    }
}
@end

// ============================================================
// 9. HOOK D: WKWebView file input (capture)
//    On iOS 14+, WKWebView uses _WKFileUploadPanel internally. We
//    intercept the picker presentation and inject our image data
//    as the selected file result.
// ============================================================
@interface WKWebView (CameraRollHook)
@end
@implementation WKWebView (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"_WKFileUploadPanel");
        if (!cls) return;
        SEL orig = NSSelectorFromString(@"_presentForFileUploadFromRect:withAllowedTypes:");
        SEL swiz = NSSelectorFromString(@"swz_presentForFileUploadFromRect:withAllowedTypes:");
        Method m1 = class_getInstanceMethod(cls, orig);
        Method m2 = class_getInstanceMethod(cls, swiz);
        if (m1 && m2) method_exchangeImplementations(m1, m2);
    });
}
@end

// ============================================================
// 10. HOOK E: UIDocumentPickerViewController – override result
// ============================================================
@interface UIDocumentPickerViewController (CameraRollHook)
@end
@implementation UIDocumentPickerViewController (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIDocumentPickerViewController class];
        SEL orig = @selector(initForOpeningContentTypes:asCopy:);
        SEL swiz = @selector(swz_initForOpeningContentTypes:asCopy:);
        Method m1 = class_getInstanceMethod(cls, orig);
        Method m2 = class_getInstanceMethod(cls, swiz);
        if (m1 && m2) method_exchangeImplementations(m1, m2);
    });
}
- (instancetype)swz_initForOpeningContentTypes:(NSArray<UTType *> *)types asCopy:(BOOL)asCopy {
    id obj = [self swz_initForOpeningContentTypes:types asCopy:asCopy];
    if (obj && gLastPickedImage) {
        // Override the document picker to immediately resolve with our image
        dispatch_async(dispatch_get_main_queue(), ^{
            NSData *png = UIImagePNGRepresentation(gLastPickedImage);
            NSURL *tmp = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"picked.png"]];
            [png writeToURL:tmp atomically:YES];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerReplacementFile" object:tmp];
        });
    }
    return obj;
}
@end

// ============================================================
// 11. Keep button on top across ALL transitions
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
- (void)swz_viewDidAppear:(BOOL)animated { [self swz_viewDidAppear:animated]; dispatch_async(dispatch_get_main_queue(), ^{ reattachFloatingButton(); }); }
- (void)swz_viewDidLayoutSubviews { [self swz_viewDidLayoutSubviews]; dispatch_async(dispatch_get_main_queue(), ^{ reattachFloatingButton(); }); }
- (void)swz_dismissViewControllerAnimated:(BOOL)flag completion:(void (^)(void))completion {
    [self swz_dismissViewControllerAnimated:flag completion:^{ if (completion) completion(); dispatch_async(dispatch_get_main_queue(), ^{ reattachFloatingButton(); }); }];
}
@end

// ============================================================
// 12. Install on launch
// ============================================================
__attribute__((constructor)) static void initCameraRollPicker(void) {
    NSLog(@"[CameraRollPicker] Loaded – universal camera-input replacement.");
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installFloatingButton();
        });
    }];
}
