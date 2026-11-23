// ============================================================
// CameraRollPicker.m
// Purpose: Intercepts any UIImagePickerController (camera source)
// and presents a PHPickerViewController (photo library) instead,
// allowing selection from the camera roll wherever the app
// requests the camera.
// Compile: clang -arch arm64 -arch arm64e -shared -o CameraRollPicker.dylib CameraRollPicker.m \
//   -framework Foundation -framework UIKit -framework PhotosUI -fobjc-arc
// Inject: optool install -c load -p "@executable_path/CameraRollPicker.dylib" -t AppBinary
// ============================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <PhotosUI/PhotosUI.h>
#import <objc/runtime.h>

// ============================================================
// 1. Global storage for the intercepted picker's delegate/callback
// ============================================================
static UIImagePickerController *gInterceptedPicker = nil;
static id gOriginalDelegate = nil;

// ============================================================
// 2. Helper: find the top-most view controller to present from
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
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].keyWindow;
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) {
        vc = vc.presentedViewController;
    }
    return vc;
}

// ============================================================
// 3. PHPickerViewControllerDelegate implementation
// ============================================================
@interface CameraRollInterceptDelegate : NSObject <PHPickerViewControllerDelegate>
@property (nonatomic, strong) UIImagePickerController *originalPicker;
@end

@implementation CameraRollInterceptDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];

    if (results.count == 0) {
        if (gOriginalDelegate &&
            [gOriginalDelegate respondsToSelector:@selector(imagePickerControllerDidCancel:)]) {
            [(id<UIImagePickerControllerDelegate>)gOriginalDelegate imagePickerControllerDidCancel:gInterceptedPicker];
        }
        return;
    }

    PHPickerResult *result = results.firstObject;
    NSItemProvider *provider = result.itemProvider;

    if ([provider canLoadObjectOfClass:[UIImage class]]) {
        [provider loadObjectOfClass:[UIImage class] completionHandler:^(UIImage *image, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (image && gInterceptedPicker &&
                    [gOriginalDelegate respondsToSelector:@selector(imagePickerController:didFinishPickingMediaWithInfo:)]) {
                    NSDictionary *info = @{
                        UIImagePickerControllerOriginalImage: image,
                        UIImagePickerControllerMediaType: @"public.image"
                    };
                    [(id<UIImagePickerControllerDelegate>)gOriginalDelegate
                        imagePickerController:gInterceptedPicker
                        didFinishPickingMediaWithInfo:info];
                }
            });
        }];
    }
}

@end

// ============================================================
// 4. Swizzled presentViewController:animated:completion:
//    Detects UIImagePickerController with camera source,
//    replaces it with PHPickerViewController.
// ============================================================
@interface UIViewController (CameraRollIntercept)
@end

@implementation UIViewController (CameraRollIntercept)

+ (void)load {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = [UIViewController class];
        SEL origSEL = @selector(presentViewController:animated:completion:);
        SEL swizSEL = @selector(swz_presentViewController:animated:completion:);
        Method orig = class_getInstanceMethod(cls, origSEL);
        Method swiz = class_getInstanceMethod(cls, swizSEL);
        method_exchangeImplementations(orig, swiz);
    });
}

- (void)swz_presentViewController:(UIViewController *)viewControllerToPresent
                         animated:(BOOL)flag
                       completion:(void (^)(void))completion {

    if ([viewControllerToPresent isKindOfClass:[UIImagePickerController class]]) {
        UIImagePickerController *picker = (UIImagePickerController *)viewControllerToPresent;
        if (picker.sourceType == UIImagePickerControllerSourceTypeCamera) {

            gInterceptedPicker = picker;
            gOriginalDelegate = picker.delegate;

            PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
            config.filter = [PHPickerFilter imagesFilter];
            config.selectionLimit = 1;

            PHPickerViewController *phpicker = [[PHPickerViewController alloc] initWithConfiguration:config];
            CameraRollInterceptDelegate *delegate = [[CameraRollInterceptDelegate alloc] init];
            delegate.originalPicker = picker;
            phpicker.delegate = delegate;

            objc_setAssociatedObject(phpicker, @selector(delegate), delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            [self swz_presentViewController:phpicker animated:flag completion:completion];
            return;
        }
    }

    [self swz_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

@end

// ============================================================
// 5. Constructor – log load
// ============================================================
__attribute__((constructor)) static void initCameraRollPicker(void) {
    NSLog(@"[CameraRollPicker] Loaded – camera prompts redirected to photo library.");
}
