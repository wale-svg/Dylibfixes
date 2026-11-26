// ============================================================
// CameraRollPicker.m
// Universal camera-input replacement for iOS sideloaded apps.
//
// Confirmed working path: the host app uses a custom
// AVCaptureSession with an AVCaptureVideoDataOutput whose
// delegate is Persona2.SelfieVisionHandler. This build wraps
// that delegate with a proxy that substitutes the live
// CMSampleBuffer with a CMSampleBuffer built from the image
// picked via the floating green button (PHPicker).
//
// Also retains diagnostic logging for the other pipeline
// types (UIImagePickerController, AVCapturePhotoOutput,
// WKWebView, UIDocumentPicker) so you can see in the log
// which paths are active.
//
// Compile: clang -arch arm64 -arch arm64e -shared -o CameraRollPicker.dylib \
//   CameraRollPicker.m -framework Foundation -framework UIKit \
//   -framework PhotosUI -framework AVFoundation -framework WebKit \
//   -framework UniformTypeIdentifiers -fobjc-arc
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

// ============================================================
// LOG FILE SETUP (Documents -> Library/Logs -> tmp -> absolute)
// ============================================================
static NSString *gLogPath = nil;
static NSLock *gLogLock = nil;

static void initLogPath(void) {
    if (gLogPath) return;
    gLogLock = [[NSLock alloc] init];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docs = docPaths.firstObject;
    BOOL wrote = NO;

    if (docs) {
        NSString *p = [docs stringByAppendingPathComponent:@"CameraRollPicker.log"];
        if (![fm fileExistsAtPath:p]) wrote = [fm createFileAtPath:p contents:[NSData data] attributes:nil];
        else wrote = YES;
        if (wrote) gLogPath = p;
    }
    if (!wrote) {
        NSArray *libPaths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
        NSString *lib = libPaths.firstObject;
        if (lib) {
            NSString *logsDir = [lib stringByAppendingPathComponent:@"Logs"];
            [fm createDirectoryAtPath:logsDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *p = [logsDir stringByAppendingPathComponent:@"CameraRollPicker.log"];
            if (![fm fileExistsAtPath:p]) wrote = [fm createFileAtPath:p contents:[NSData data] attributes:nil];
            else wrote = YES;
            if (wrote) gLogPath = p;
        }
    }
    if (!wrote) {
        NSString *p = [NSTemporaryDirectory() stringByAppendingPathComponent:@"CameraRollPicker.log"];
        if (![fm fileExistsAtPath:p]) [fm createFileAtPath:p contents:[NSData data] attributes:nil];
        gLogPath = p;
    }
    NSLog(@"[CameraRollPicker] LOG PATH = %@", gLogPath);
    fprintf(stderr, "[CameraRollPicker] LOG PATH = %s\n", gLogPath.UTF8String);
}

static void CRLog(NSString *format, ...) {
    initLogPath();
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date].description, msg];
    [gLogLock lock];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:gLogPath];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    [gLogLock unlock];
    NSLog(@"[CameraRollPicker] %@", msg);
    fprintf(stderr, "[CameraRollPicker] %s\n", msg.UTF8String);
}

// ============================================================
// GLOBALS
// ============================================================
static UIImagePickerController *gActiveImagePicker = nil;
static id gActiveImagePickerDelegate = nil;
static AVCapturePhotoOutput *gActivePhotoOutput = nil;
static AVCaptureSession *gActiveSession = nil;
static AVCaptureVideoDataOutput *gActiveVideoOutput = nil;
static UIButton *gFloatingButton = nil;
static id gActivePickerDelegate = nil;
static UIImage *gLastPickedImage = nil;

// ============================================================
// Top-most view controller
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
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

// ============================================================
// Sample-buffer factory: UIImage -> CMSampleBuffer (BGRA)
// ============================================================
static CMSampleBufferRef CRSampleBufferFromImage(UIImage *image) {
    if (!image) return NULL;
    CGImageRef cg = image.CGImage;
    if (!cg) return NULL;
    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);

    NSDictionary *attrs = @{
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    CVPixelBufferRef px = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                        kCVPixelFormatType_32BGRA,
                        (__bridge CFDictionaryRef)attrs, &px);
    if (!px) return NULL;

    CVPixelBufferLockBaseAddress(px, 0);
    void *base = CVPixelBufferGetBaseAddress(px);
    size_t bpr = CVPixelBufferGetBytesPerRow(px);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CVPixelBufferUnlockBaseAddress(px, 0);

    CMVideoFormatDescriptionRef fmt = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, px, &fmt);

    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock()),
        .decodeTimeStamp = kCMTimeInvalid
    };
    CMSampleBufferRef sbuf = NULL;
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, px, true,
                                       NULL, NULL, fmt, &timing, &sbuf);
    CVPixelBufferRelease(px);
    if (fmt) CFRelease(fmt);
    return sbuf;
}

// ============================================================
// Video pipeline proxy: substitutes the camera frame with the
// picked image. Installed via AVCaptureVideoDataOutput hook.
// ============================================================
@class CRVideoProxy;

@interface CRVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> original;
@property (atomic, strong) UIImage *replacement;
@end

@implementation CRVideoProxy
- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
    UIImage *img = self.replacement;
    if (img) {
        CMSampleBufferRef fake = CRSampleBufferFromImage(img);
        if (fake) {
            if ([self.original respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.original captureOutput:output
                        didOutputSampleBuffer:fake
                             fromConnection:connection];
            }
            CFRelease(fake);
            return;
        }
    }
    if ([self.original respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.original captureOutput:output
                didOutputSampleBuffer:sampleBuffer
                     fromConnection:connection];
    }
}
- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.original respondsToSelector:aSelector];
}
- (id)forwardingTargetForSelector:(SEL)aSelector {
    return [self.original respondsToSelector:aSelector] ? self.original : nil;
}
@end

static CRVideoProxy *gVideoProxy = nil;

// ============================================================
// Resize helper (matches session resolution)
// ============================================================
static UIImage *CRResize(UIImage *img, CGSize target) {
    if (!img) return nil;
    UIGraphicsBeginImageContextWithOptions(target, NO, 1.0);
    [img drawInRect:CGRectMake(0, 0, target.width, target.height)];
    UIImage *out = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return out ?: img;
}

// ============================================================
// Deliver picked image into ALL channels
// ============================================================
static void deliverImage(UIImage *image) {
    if (!image) return;
    gLastPickedImage = image;

    // 1) Inject into live video pipeline if active
    if (gVideoProxy) {
        gVideoProxy.replacement = CRResize(image, CGSizeMake(1179, 2556));
        CRLog(@"PICKER injected image into video pipeline (resized 1179x2556)");
    }

    // 2) Forward to UIImagePickerController delegate (if any)
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

    // 3) Broadcast notifications for any custom consumer
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerImageSelected" object:image];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerReplacementImage" object:image];

    CRLog(@"PICKER returned image size=%.0fx%.0f", image.size.width, image.size.height);
}

// ============================================================
// PHPicker delegate
// ============================================================
@interface CameraRollOverlayDelegate : NSObject <PHPickerViewControllerDelegate>
@end
@implementation CameraRollOverlayDelegate
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        CRLog(@"PHPicker cancelled");
        return;
    }
    NSItemProvider *provider = results.firstObject.itemProvider;
    if ([provider canLoadObjectOfClass:[UIImage class]]) {
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *img, NSError *err) {
            if (img) dispatch_async(dispatch_get_main_queue(), ^{ deliverImage(img); });
        }];
    } else if ([provider hasItemConformingToTypeIdentifier:@"public.movie"]) {
        [provider loadItemForTypeIdentifier:@"public.movie" options:nil completionHandler:^(id item, NSError *err) {
            NSURL *url = [item isKindOfClass:[NSURL class]] ? item : [NSURL URLWithString:[item description]];
            CRLog(@"PHPicker returned video URL=%@", url);
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CameraRollPickerVideoSelected" object:url];
        }];
    }
}
@end

// ============================================================
// Floating button
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
        CRLog(@"Floating button tapped – opening PHPicker");
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
// HOOK A: UIImagePickerController
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
        CRLog(@"DETECTED UIImagePickerController presented sourceType=%ld", (long)p.sourceType);
        if (p.sourceType == UIImagePickerControllerSourceTypeCamera) {
            gActiveImagePicker = p;
            gActiveImagePickerDelegate = p.delegate;
        }
    }
    [self swz_presentViewController:vc animated:a completion:c];
}
@end

// ============================================================
// HOOK B: AVCapturePhotoOutput
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
    if (obj) {
        gActivePhotoOutput = obj;
        CRLog(@"DETECTED AVCapturePhotoOutput init");
    }
    return obj;
}
- (void)swz_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    CRLog(@"DETECTED AVCapturePhotoOutput capturePhotoWithSettings delegate=%@", delegate);
    [self swz_capturePhotoWithSettings:settings delegate:delegate];
}
@end

// ============================================================
// HOOK C: AVCaptureSession
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

        Method m3 = class_getInstanceMethod(cls, @selector(addOutput:));
        Method m4 = class_getInstanceMethod(cls, @selector(swz_addOutput:));
        if (m3 && m4) method_exchangeImplementations(m3, m4);
    });
}
- (void)swz_startRunning {
    gActiveSession = self;
    CRLog(@"DETECTED AVCaptureSession startRunning (session=%@)", self);
    [self swz_startRunning];
}
- (void)swz_addOutput:(AVCaptureOutput *)output {
    CRLog(@"DETECTED AVCaptureSession addOutput class=%@", NSStringFromClass([output class]));
    [self swz_addOutput:output];
}
@end

// ============================================================
// HOOK D: AVCaptureVideoDataOutput – install proxy delegate
// ============================================================
@interface AVCaptureVideoDataOutput (CameraRollHook)
@end
@implementation AVCaptureVideoDataOutput (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [AVCaptureVideoDataOutput class];
        Method m1 = class_getInstanceMethod(cls, @selector(setSampleBufferDelegate:queue:));
        Method m2 = class_getInstanceMethod(cls, @selector(swz_setSampleBufferDelegate:queue:));
        if (m1 && m2) method_exchangeImplementations(m1, m2);

        Method m3 = class_getInstanceMethod(cls, @selector(init));
        Method m4 = class_getInstanceMethod(cls, @selector(swz_init));
        if (m3 && m4) method_exchangeImplementations(m3, m4);
    });
}
- (instancetype)swz_init {
    id obj = [self swz_init];
    if (obj) {
        gActiveVideoOutput = obj;
        CRLog(@"DETECTED AVCaptureVideoDataOutput init");
    }
    return obj;
}
- (void)swz_setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    CRLog(@"DETECTED AVCaptureVideoDataOutput setSampleBufferDelegate delegate=%@", delegate);
    if (!gVideoProxy) gVideoProxy = [[CRVideoProxy alloc] init];
    gVideoProxy.original = delegate;
    [self swz_setSampleBufferDelegate:gVideoProxy queue:queue];
}
@end

// ============================================================
// HOOK E: WKWebView file upload
// ============================================================
@interface WKWebView (CameraRollHook)
@end
@implementation WKWebView (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"_WKFileUploadPanel");
        if (!cls) {
            CRLog(@"NOTE _WKFileUploadPanel not present in this runtime");
            return;
        }
        SEL orig = NSSelectorFromString(@"_presentForFileUploadFromRect:withAllowedTypes:");
        SEL swiz = NSSelectorFromString(@"swz_presentForFileUploadFromRect:withAllowedTypes:");
        Method m1 = class_getInstanceMethod(cls, orig);
        Method m2 = class_getInstanceMethod(cls, swiz);
        if (m1 && m2) {
            method_exchangeImplementations(m1, m2);
            CRLog(@"HOOK E installed on _WKFileUploadPanel");
        }
    });
}
@end

// ============================================================
// HOOK F: UIDocumentPickerViewController
// ============================================================
@interface UIDocumentPickerViewController (CameraRollHook)
@end
@implementation UIDocumentPickerViewController (CameraRollHook)
+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIDocumentPickerViewController class];
        Method m1 = class_getInstanceMethod(cls, @selector(initForOpeningContentTypes:asCopy:));
        Method m2 = class_getInstanceMethod(cls, @selector(swz_initForOpeningContentTypes:asCopy:));
        if (m1 && m2) method_exchangeImplementations(m1, m2);
    });
}
- (instancetype)swz_initForOpeningContentTypes:(NSArray<UTType *> *)types asCopy:(BOOL)asCopy {
    CRLog(@"DETECTED UIDocumentPickerViewController init types=%@", types);
    return [self swz_initForOpeningContentTypes:types asCopy:asCopy];
}
@end

// ============================================================
// FloatingButtonFollow – keep button on top across transitions
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
// Entry
// ============================================================
__attribute__((constructor)) static void initCameraRollPicker(void) {
    CRLog(@"=== CameraRollPicker UNIVERSAL BUILD loaded ===");
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            installFloatingButton();
        });
    }];
}
