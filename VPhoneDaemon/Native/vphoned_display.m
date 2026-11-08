/*
 * vphoned_display — enumerate the display pipeline as the guest sees it.
 *
 * The depth-capped registry walk `device.ioreg` offers stops above `gfx`,
 * where a paravirt display stack publishes its controllers, so whether the
 * guest bound one display or two has been unobservable right where the Duo
 * work needs it (SpringBoard's two-always-connected-displays gate). A flat
 * IOService match over the whole plane has no depth to stop at; this file
 * filters it to display-ish classes and reports each object's small
 * properties — the identity and geometry answers backboardd builds its
 * display set from.
 */

#import "Include/VphonedNative.h"

#include <IOKit/IOKitLib.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>
#include <time.h>

// Private headers describe possible selectors, not the ABI in this guest.
// Record the runtime encoding before invoking a selector or reading it by KVC.
static NSMethodSignature *vpDisplaySignature(Class cls, BOOL classMethod, NSString *name,
                                            const char *returnType, NSArray<NSString *> *arguments,
                                            NSMutableDictionary *runtime) {
    SEL selector = NSSelectorFromString(name);
    Method method = classMethod ? class_getClassMethod(cls, selector) : class_getInstanceMethod(cls, selector);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    NSString *identity = [NSString stringWithFormat:@"%c[%s %@]", classMethod ? '+' : '-',
                          cls ? class_getName(cls) : "unavailable", name];
    NSMutableDictionary *detail = [NSMutableDictionary dictionaryWithDictionary:@{
        @"available": @(method != NULL), @"encoding": encoding ? @(encoding) : NSNull.null,
        @"abi_verified": @NO,
    }];
    runtime[@"methods"][identity] = detail;
    if (!encoding) return nil;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding];
    NSMutableArray *types = [NSMutableArray array];
    for (NSUInteger i = 0; i < signature.numberOfArguments; i++) {
        [types addObject:@([signature getArgumentTypeAtIndex:i])];
    }
    detail[@"return_type"] = @(signature.methodReturnType);
    detail[@"argument_types"] = types;
    if (signature.numberOfArguments != arguments.count + 2) return nil;
    if (strcmp([signature getArgumentTypeAtIndex:0], @encode(id)) != 0
        || strcmp([signature getArgumentTypeAtIndex:1], @encode(SEL)) != 0) return nil;
    if (returnType && strcmp(signature.methodReturnType, returnType) != 0) return nil;
    if (!returnType) {
        const char *type = signature.methodReturnType;
        BOOL scalar = type[0] && !type[1] && strchr("cCsSiIlLqQfdB", type[0]) != NULL;
        if (!scalar && strcmp(type, @encode(id)) != 0 && strcmp(type, @encode(CGRect)) != 0) return nil;
    }
    for (NSUInteger i = 0; i < arguments.count; i++) {
        if (strcmp([signature getArgumentTypeAtIndex:i + 2], arguments[i].UTF8String) != 0) return nil;
    }
    detail[@"abi_verified"] = @YES;
    return signature;
}

static NSMethodSignature *vpDisplayObjectSignature(id object, NSString *name, const char *returnType,
                                                  NSArray<NSString *> *arguments,
                                                  NSMutableDictionary *runtime) {
    BOOL classMethod = object_isClass(object);
    Class cls = classMethod ? object : object_getClass(object);
    return vpDisplaySignature(cls, classMethod, name, returnType, arguments, runtime);
}

static id vpDisplayObject(id object, NSString *name, NSMutableDictionary *runtime) {
    if (!object || !vpDisplayObjectSignature(object, name, @encode(id), @[], runtime)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static NSMethodSignature *vpDisplayBlockGetterSignature(Class cls, NSString *name, NSMutableDictionary *runtime) {
    NSMethodSignature *signature = vpDisplaySignature(cls, NO, name, "@?", @[], runtime);
    return signature ?: vpDisplaySignature(cls, NO, name, @encode(id), @[], runtime);
}

typedef struct {
    bool (*hasSignature)(void *);
    const char *(*signature)(void *);
    Class blockClass;
} VPDisplayBlockAPI;

static VPDisplayBlockAPI vpDisplayBlockAPI(void) {
    static VPDisplayBlockAPI api;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Apple libclosure owns descriptor formats and pointer authentication.
        api.hasSignature = (bool (*)(void *))dlsym(RTLD_DEFAULT, "_Block_has_signature");
        api.signature = (const char *(*)(void *))dlsym(RTLD_DEFAULT, "_Block_signature");
        api.blockClass = objc_lookUpClass("NSBlock");
    });
    return api;
}

static NSDictionary *vpDisplayBlockAPIMetadata(void) {
    VPDisplayBlockAPI api = vpDisplayBlockAPI();
    return @{
        @"has_signature_api": @(api.hasSignature != NULL),
        @"signature_api": @(api.signature != NULL), @"nsblock_class": @(api.blockClass != Nil),
        @"lookup": @"once_per_process",
    };
}

static NSDictionary *vpDisplayBlockMetadata(id object, NSString *getter, NSMutableDictionary *runtime) {
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithDictionary:@{
        @"signature_available": @NO, @"state": @"getter_unavailable_or_abi_mismatch",
    }];
    if (!object) { result[@"state"] = @"object_unavailable"; return result; }
    NSMethodSignature *getterSignature = vpDisplayBlockGetterSignature(object_getClass(object), getter, runtime);
    if (!getterSignature) return result;
    result[@"getter_return_type"] = @(getterSignature.methodReturnType);
    @try {
        id value = ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(getter));
        if (!value) { result[@"state"] = @"nil"; return result; }
        VPDisplayBlockAPI api = vpDisplayBlockAPI();
        BOOL isBlock = NO;
        for (Class cls = object_getClass(value); cls; cls = class_getSuperclass(cls)) {
            if (api.blockClass && cls == api.blockClass) { isBlock = YES; break; }
        }
        result[@"is_nsblock"] = @(isBlock);
        if (!isBlock) { result[@"state"] = @"not_verified_nsblock"; return result; }
        if (!api.hasSignature || !api.signature) { result[@"state"] = @"descriptor_api_unavailable"; return result; }
        bool hasSignature = api.hasSignature((__bridge void *)value);
        result[@"has_signature"] = @(hasSignature);
        if (!hasSignature) { result[@"state"] = @"no_compiler_signature"; return result; }
        const char *encoding = api.signature((__bridge void *)value);
        if (!encoding) { result[@"state"] = @"signature_unavailable"; return result; }
        size_t length = strnlen(encoding, 1025);
        if (!length || length > 1024) { result[@"state"] = @"signature_length_unsupported"; return result; }
        NSString *signature = [[NSString alloc] initWithBytes:encoding length:length encoding:NSUTF8StringEncoding];
        if (!signature) { result[@"state"] = @"signature_invalid_utf8"; return result; }
        result[@"state"] = @"compiler_signature";
        result[@"signature_available"] = @YES;
        result[@"encoding"] = signature;
    } @catch (NSException *exception) {
        result[@"state"] = @"getter_exception";
        result[@"reason"] = exception.reason ?: exception.name;
    }
    return result;
}

static id vpDisplayValue(id object, NSString *key, NSMutableDictionary *runtime) {
    if (!object) return nil;
    NSMethodSignature *signature = vpDisplayObjectSignature(object, key, NULL, @[], runtime);
    if (!signature) return nil;
    @try {
        id value = [object valueForKey:key];
        return value == NSNull.null ? nil : value;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

static NSNumber *vpDisplayNumber(id object, NSString *key, NSMutableDictionary *runtime) {
    id value = vpDisplayValue(object, key, runtime);
    if (![value isKindOfClass:NSNumber.class]
        || CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        || !isfinite([value doubleValue])) return nil;
    return value;
}

static NSString *vpDisplayString(id object, NSString *key, NSUInteger maximumLength, NSMutableDictionary *runtime) {
    id value = vpDisplayValue(object, key, runtime);
    if (![value isKindOfClass:NSString.class] || [value length] > maximumLength) return nil;
    return value;
}

static NSString *vpDisplayUUID(id object, NSString *key, NSMutableDictionary *runtime) {
    id value = vpDisplayValue(object, key, runtime);
    if ([value isKindOfClass:NSUUID.class]) return [(NSUUID *)value UUIDString];
    if (![value isKindOfClass:NSString.class] || [value length] > 128) return nil;
    return [[NSUUID alloc] initWithUUIDString:value].UUIDString;
}

static NSDictionary *vpDisplayRect(id object, NSString *key, NSMutableDictionary *runtime) {
    id value = vpDisplayValue(object, key, runtime);
    if (![value isKindOfClass:NSValue.class] || strcmp([(NSValue *)value objCType], @encode(CGRect)) != 0) return nil;
    CGRect rect;
    [(NSValue *)value getValue:&rect size:sizeof(rect)];
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y)
        || !isfinite(rect.size.width) || !isfinite(rect.size.height)
        || !isfinite(CGRectGetMaxX(rect)) || !isfinite(CGRectGetMaxY(rect))
        || rect.size.width <= 0 || rect.size.height <= 0) return nil;
    return @{
        @"x": @(rect.origin.x), @"y": @(rect.origin.y),
        @"width": @(rect.size.width), @"height": @(rect.size.height),
    };
}

static NSNumber *vpDisplayBoolean(id object, NSString *key, NSMutableDictionary *runtime) {
    id value = vpDisplayValue(object, key, runtime);
    return [value isKindOfClass:NSNumber.class] ? @([value boolValue]) : nil;
}

static NSDictionary *vpDisplayScene(id element, NSMutableDictionary *runtime) {
    NSMutableDictionary *scene = [NSMutableDictionary dictionary];
    NSString *bundleID = vpDisplayString(element, @"bundleIdentifier", 255, runtime);
    NSString *identifier = vpDisplayString(element, @"identifier", 255, runtime);
    NSDictionary *frame = vpDisplayRect(element, @"frame", runtime);
    if (bundleID) scene[@"bundle_id"] = bundleID;
    if (identifier) scene[@"identifier"] = identifier;
    if (frame) scene[@"frame"] = frame;
    NSDictionary *referenceFrame = vpDisplayRect(element, @"referenceFrame", runtime);
    if (referenceFrame) scene[@"reference_frame"] = referenceFrame;
    NSNumber *focused = vpDisplayBoolean(element, @"hasKeyboardFocus", runtime);
    if (focused) scene[@"keyboard_focus"] = focused;
    NSNumber *application = vpDisplayBoolean(element, @"isUIApplicationElement", runtime);
    if (application) scene[@"application"] = application;
    NSNumber *role = vpDisplayNumber(element, @"layoutRole", runtime);
    if (role) scene[@"layout_role"] = role;
    NSNumber *level = vpDisplayNumber(element, @"level", runtime);
    if (level) scene[@"level"] = level;
    return scene;
}

static NSDictionary *vpDisplayLayoutRow(id monitor, NSString *frontmostBundleID, NSMutableDictionary *runtime) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    row[@"monitor_source"] = @"default_main";
    row[@"geometry_available"] = @NO;
    id layout = vpDisplayObject(monitor, @"currentLayout", runtime);
    if (!layout) {
        row[@"available"] = @NO;
        row[@"reason"] = @"Monitor or ABI unavailable, or FrontBoard returned no initial layout";
        return row;
    }
    row[@"available"] = @YES;
    NSDictionary *bounds = vpDisplayRect(layout, @"bounds", runtime);
    if (bounds) row[@"bounds"] = bounds;
    NSDictionary *referenceBounds = vpDisplayRect(layout, @"referenceBounds", runtime);
    if (referenceBounds) row[@"reference_bounds"] = referenceBounds;
    NSNumber *orientation = vpDisplayNumber(layout, @"interfaceOrientation", runtime);
    if (orientation) row[@"interface_orientation"] = orientation;
    BOOL supportedOrientation = orientation && orientation.doubleValue >= 1 && orientation.doubleValue <= 4
        && orientation.doubleValue == orientation.integerValue;
    NSNumber *layoutDisplayType = vpDisplayNumber(layout, @"displayType", runtime);
    if (layoutDisplayType) row[@"display_type"] = layoutDisplayType;

    id configuration = vpDisplayValue(layout, @"displayConfiguration", runtime);
    if (configuration) {
        NSString *name = vpDisplayString(configuration, @"name", 128, runtime);
        NSString *deviceName = vpDisplayString(configuration, @"deviceName", 128, runtime);
        NSNumber *scale = vpDisplayNumber(configuration, @"pointScale", runtime);
        if (name) row[@"display_name"] = name;
        if (deviceName) row[@"device_name"] = deviceName;
        NSString *hardwareIdentifier = vpDisplayUUID(configuration, @"hardwareIdentifier", runtime);
        if (hardwareIdentifier) row[@"hardware_identifier"] = hardwareIdentifier;
        if (scale && isfinite(scale.doubleValue) && scale.doubleValue > 0) row[@"point_scale"] = scale;
        id identity = vpDisplayValue(configuration, @"identity", runtime);
        NSNumber *displayID = vpDisplayNumber(identity, @"displayID", runtime);
        if (!displayID) displayID = vpDisplayNumber(configuration, @"displayID", runtime);
        if (displayID) row[@"display_id"] = displayID;
    }
    NSNumber *scale = row[@"point_scale"], *displayID = row[@"display_id"];
    BOOL validID = displayID && displayID.doubleValue > 0 && displayID.doubleValue <= UINT32_MAX
        && floor(displayID.doubleValue) == displayID.doubleValue;
    row[@"geometry_available"] = @(bounds && referenceBounds && scale.doubleValue > 0 && validID && supportedOrientation);
    if (![row[@"geometry_available"] boolValue]) row[@"reason"] = @"Active display geometry is incomplete or unsupported";

    id elements = vpDisplayValue(layout, @"elements", runtime);
    if (![elements isKindOfClass:NSArray.class]) {
        row[@"elements_available"] = @NO;
        return row;
    }
    row[@"elements_available"] = @YES;
    NSMutableArray *scenes = [NSMutableArray array];
    if (frontmostBundleID.length) {
        NSUInteger inspected = 0;
        for (id element in elements) {
            if (++inspected > 128) break;
            NSString *bundleID = vpDisplayString(element, @"bundleIdentifier", 255, runtime);
            if (![bundleID isEqualToString:frontmostBundleID]) continue;
            [scenes addObject:vpDisplayScene(element, runtime)];
            if (scenes.count == 8) break;
        }
    }
    row[@"matched_scene_count"] = @(scenes.count);
    row[@"foreground_scenes"] = scenes;
    return row;
}

static NSMutableDictionary *vpDisplayRuntime(void) {
    NSMutableDictionary *runtime = [NSMutableDictionary dictionaryWithDictionary:@{
        @"classes": [NSMutableDictionary dictionary], @"methods": [NSMutableDictionary dictionary],
    }];
    for (NSString *name in @[@"CADisplay", @"FBSDisplayLayoutMonitor", @"FBSDisplayLayoutMonitorConfiguration",
                            @"FBSDisplayLayout", @"FBSDisplayLayoutElement"]) {
        runtime[@"classes"][name] = @(objc_lookUpClass(name.UTF8String) != Nil);
    }
    Class displayClass = objc_lookUpClass("CADisplay");
    Class monitorClass = objc_lookUpClass("FBSDisplayLayoutMonitor");
    Class configurationClass = objc_lookUpClass("FBSDisplayLayoutMonitorConfiguration");
    vpDisplaySignature(displayClass, YES, @"displays", @encode(id), @[], runtime);
    vpDisplaySignature(monitorClass, YES, @"sharedMonitorForDisplayType:", @encode(id), @[@(@encode(long long))], runtime);
    vpDisplaySignature(monitorClass, YES, @"monitorWithConfiguration:", @encode(id), @[@(@encode(id))], runtime);
    vpDisplaySignature(configurationClass, YES, @"configurationForDefaultMainDisplayMonitor", @encode(id), @[], runtime);
    vpDisplayBlockGetterSignature(configurationClass, @"transitionHandler", runtime);
    vpDisplayBlockGetterSignature(monitorClass, @"handler", runtime);
    runtime[@"block_signature_api"] = vpDisplayBlockAPIMetadata();
    vpDisplaySignature(monitorClass, NO, @"currentLayout", @encode(id), @[], runtime);
    vpDisplaySignature(monitorClass, NO, @"invalidate", @encode(void), @[], runtime);
    for (NSString *key in @[@"bounds", @"referenceBounds", @"interfaceOrientation", @"displayType",
                           @"displayConfiguration", @"elements"]) {
        vpDisplaySignature(objc_lookUpClass("FBSDisplayLayout"), NO, key, NULL, @[], runtime);
    }
    for (NSString *key in @[@"bundleIdentifier", @"identifier", @"frame", @"referenceFrame",
                           @"hasKeyboardFocus", @"isUIApplicationElement", @"layoutRole", @"level"]) {
        vpDisplaySignature(objc_lookUpClass("FBSDisplayLayoutElement"), NO, key, NULL, @[], runtime);
    }
    return runtime;
}

static NSDictionary *vpDisplayUnavailable(NSString *reason, NSString *state) {
    return @{
        @"available": @NO, @"geometry_available": @NO, @"reason": reason,
        @"frontmost_bundle_id": NSNull.null, @"monitors": @[], @"cadisplays": @[],
        @"runtime": vpDisplayRuntime(),
        @"thread": @{@"caller_is_main": @(NSThread.isMainThread), @"capture_state": state},
    };
}

static NSDictionary *vpDisplayCapture(NSString *frontmostBundleID, NSMutableDictionary *capture) {
    // main.swift runs RunLoop.main in the daemon worker. A scripting session
    // exits before that startup and must not call these APIs on its main thread.
    CFStringRef mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain());
    BOOL safeThread = NSThread.isMainThread && mode != NULL;
    if (mode) CFRelease(mode);
    if (!safeThread) return vpDisplayUnavailable(@"An active main run loop is required", @"unsafe_thread");
    NSMutableDictionary *runtime = capture[@"runtime"];
    @try {
        if (!runtime) {
            dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
            dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY | RTLD_LOCAL);
            runtime = vpDisplayRuntime();
            capture[@"runtime"] = runtime;
            Class displayClass = objc_lookUpClass("CADisplay");
            Class monitorClass = objc_lookUpClass("FBSDisplayLayoutMonitor");
            Class configurationClass = objc_lookUpClass("FBSDisplayLayoutMonitorConfiguration");
            id displayObjects = vpDisplayObject(displayClass, @"displays", runtime);
            NSMutableArray *inventory = [NSMutableArray array];
            if ([displayObjects isKindOfClass:NSArray.class]) {
                for (id display in displayObjects) {
                    NSMutableDictionary *item = [NSMutableDictionary dictionary];
                    for (NSString *key in @[@"displayId", @"displayType", @"pointScale"]) {
                        NSNumber *value = vpDisplayNumber(display, key, runtime);
                        if (value && isfinite(value.doubleValue)) item[key] = value;
                    }
                    for (NSString *key in @[@"name", @"deviceName"]) {
                        NSString *value = vpDisplayString(display, key, 128, runtime);
                        if (value) item[key] = value;
                    }
                    for (NSString *key in @[@"currentOrientation", @"nativeOrientation"]) {
                        NSNumber *number = vpDisplayNumber(display, key, runtime);
                        id value = number ?: vpDisplayString(display, key, 32, runtime);
                        if (value) item[key] = value;
                    }
                    NSDictionary *bounds = vpDisplayRect(display, @"bounds", runtime);
                    if (bounds) item[@"bounds"] = bounds;
                    NSString *uniqueID = vpDisplayUUID(display, @"uniqueId", runtime);
                    if (uniqueID) item[@"uniqueId"] = uniqueID;
                    [inventory addObject:item];
                    if (inventory.count == 16) break;
                }
            }
            capture[@"cadisplays"] = inventory;
            // CADisplay and FrontBoard display-type enum values are not proven
            // equivalent. Only query the independent default-main monitor.
            id configuration = vpDisplayObject(configurationClass, @"configurationForDefaultMainDisplayMonitor", runtime);
            capture[@"callback_metadata"] = @{
                @"factory_configuration_transition_handler": vpDisplayBlockMetadata(configuration, @"transitionHandler", runtime),
                @"monitor_handler": @{
                    @"state": @"not_read", @"reason": @"Deprecated getter requires a mutable monitor; this monitor is factory-configured",
                },
                @"monitor_configuration": @{
                    @"state": @"unavailable", @"reason": @"No source-verified configuration accessor; private ivars are not read",
                },
            };
            if (configuration
                && vpDisplaySignature(monitorClass, YES, @"monitorWithConfiguration:", @encode(id), @[@(@encode(id))], runtime)
                && vpDisplaySignature(monitorClass, NO, @"invalidate", @encode(void), @[], runtime)) {
                id ownedMonitor = ((id (*)(id, SEL, id))objc_msgSend)(monitorClass,
                    sel_registerName("monitorWithConfiguration:"), configuration);
                if (ownedMonitor) capture[@"owned_monitor"] = ownedMonitor;
            }
        }
        NSArray *rows = @[vpDisplayLayoutRow(capture[@"owned_monitor"], frontmostBundleID, runtime)];
        BOOL available = NO;
        BOOL geometryAvailable = NO;
        for (NSDictionary *row in rows) {
            available |= [row[@"available"] boolValue];
            geometryAvailable |= [row[@"geometry_available"] boolValue];
        }
        return @{
            @"available": @(available), @"geometry_available": @(geometryAvailable),
            @"reason": available ? @"" : @"No current FrontBoard layout was available",
            @"frontmost_bundle_id": frontmostBundleID ?: NSNull.null,
            @"runtime": runtime, @"monitors": rows, @"cadisplays": capture[@"cadisplays"] ?: @[],
            @"callback_metadata": capture[@"callback_metadata"] ?: @{},
            @"thread": @{@"capture_is_main": @YES, @"main_run_loop_active": @YES, @"capture_state": @"completed"},
            @"layout_contract": @"One owned monitor sampled asynchronously for initial currentLayout; no private callback ABI is assumed",
            @"display_binding": @"CADisplay inventory is independent; display type does not uniquely identify a panel",
            @"shared_monitor_query": @"Not invoked; FrontBoard display-type enum semantics are unverified",
        };
    } @catch (NSException *exception) {
        capture[@"failed"] = @YES;
        return @{
            @"available": @NO, @"geometry_available": @NO,
            @"reason": exception.reason ?: @"FrontBoard layout query failed",
            @"frontmost_bundle_id": NSNull.null, @"monitors": @[], @"cadisplays": @[],
            @"runtime": runtime ?: vpDisplayRuntime(),
            @"thread": @{@"capture_is_main": @YES, @"capture_state": @"exception"},
        };
    }
}

static double vpDisplayMonotonicTime(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

static void vpDisplayFinish(NSMutableDictionary *capture, NSMutableDictionary *report,
                           void (^completion)(NSDictionary *)) {
    id ownedMonitor = capture[@"owned_monitor"];
    @try {
        if (ownedMonitor) {
            if (!vpDisplayObjectSignature(ownedMonitor, @"invalidate", @encode(void), @[], capture[@"runtime"])) {
                report[@"available"] = @NO;
                report[@"geometry_available"] = @NO;
                report[@"frontmost_bundle_id"] = NSNull.null;
                report[@"monitors"] = @[];
                report[@"reason"] = @"Owned monitor cleanup ABI is unavailable";
            } else {
                ((void (*)(id, SEL))objc_msgSend)(ownedMonitor, sel_registerName("invalidate"));
            }
        }
    } @catch (NSException *exception) {
        report[@"available"] = @NO;
        report[@"geometry_available"] = @NO;
        report[@"frontmost_bundle_id"] = NSNull.null;
        report[@"monitors"] = @[];
        report[@"reason"] = exception.reason ?: @"Owned monitor cleanup failed";
    } @finally {
        // Drop the owned reference on main, after invalidate has returned.
        [capture removeObjectForKey:@"owned_monitor"];
        ownedMonitor = nil;
    }
    completion(report);
}

static void vpDisplaySample(NSString *frontmostBundleID, NSMutableDictionary *capture,
                           BOOL (^cancelled)(void), void (^completion)(NSDictionary *)) {
    // Every sample and owned-monitor cleanup runs on main. dispatch_after
    // yields to its run loop so the service can deliver its initial state.
    if (cancelled()) {
        vpDisplayFinish(capture, [vpDisplayUnavailable(@"Layout observation cancelled", @"cancelled") mutableCopy], completion);
        return;
    }
    double elapsed = vpDisplayMonotonicTime() - [capture[@"started_at"] doubleValue];
    NSUInteger samples = [capture[@"sample_count"] unsignedIntegerValue];
    BOOL expired = samples > 0 && elapsed >= 1.2;
    NSMutableDictionary *report;
    if (expired) {
        report = [capture[@"last_report"] mutableCopy];
    } else {
        report = [vpDisplayCapture(frontmostBundleID, capture) mutableCopy];
        capture[@"last_report"] = report;
        capture[@"sample_count"] = @(++samples);
        elapsed = vpDisplayMonotonicTime() - [capture[@"started_at"] doubleValue];
    }
    BOOL available = [report[@"available"] boolValue];
    BOOL canObserve = capture[@"owned_monitor"] && ![capture[@"failed"] boolValue];
    if (!available && canObserve && elapsed < 1.2 && !cancelled()) {
        int64_t delay = (int64_t)(fmin(0.05, 1.2 - elapsed) * NSEC_PER_SEC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_main_queue(), ^{
            @autoreleasepool { vpDisplaySample(frontmostBundleID, capture, cancelled, completion); }
        });
        return;
    }
    NSString *state = available ? @"available" : canObserve ? @"initial_layout_deadline" : @"unavailable";
    report[@"observation"] = @{
        @"state": state, @"sample_count": @(samples), @"elapsed_ms": @(elapsed * 1000),
        @"limit_ms": @1200, @"sample_interval_ms": @50,
    };
    if (!available && canObserve) report[@"reason"] = @"No initial FrontBoard layout observed before the observation deadline";
    vpDisplayFinish(capture, report, completion);
}

NSDictionary<NSString *, id> *vp_display_layout(NSString *frontmostBundleID) {
    dispatch_time_t entered = dispatch_time(DISPATCH_TIME_NOW, 0);
    dispatch_time_t completionDeadline = dispatch_time(entered, 1500 * NSEC_PER_MSEC);
    if (NSThread.isMainThread) {
        return vpDisplayUnavailable(@"Asynchronous layout observation requires a background caller", @"main_thread_caller");
    }
    static dispatch_semaphore_t slot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ slot = dispatch_semaphore_create(1); });
    // Briefly serialize ordinary event/RPC overlap without extending the
    // single overall response deadline or waiting on the main thread.
    if (dispatch_semaphore_wait(slot, dispatch_time(entered, 300 * NSEC_PER_MSEC)) != 0) {
        return vpDisplayUnavailable(@"Layout capture admission deadline exceeded", @"busy");
    }
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL started = NO;
    __block BOOL cancelled = NO;
    __block NSDictionary *result = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [lock lock];
        if (cancelled) {
            [lock unlock];
            dispatch_semaphore_signal(slot);
            return;
        }
        started = YES;
        [lock unlock];
        @autoreleasepool {
            NSMutableDictionary *capture = [NSMutableDictionary dictionaryWithObject:@(vpDisplayMonotonicTime()) forKey:@"started_at"];
            vpDisplaySample(frontmostBundleID, capture, ^BOOL {
                [lock lock];
                BOOL value = cancelled;
                [lock unlock];
                return value;
            }, ^(NSDictionary *report) {
                [lock lock];
                result = report;
                [lock unlock];
                dispatch_semaphore_signal(done);
                dispatch_semaphore_signal(slot);
            });
        }
    });
    // Only this background queue/completion wait is bounded. It cannot bound
    // the caller's foreground reads. Direct main-thread callers are rejected.
    // Once a private call starts it cannot be forcibly cancelled; keep the slot
    // occupied until that capture finishes.
    if (dispatch_semaphore_wait(done, completionDeadline) != 0) {
        [lock lock];
        cancelled = YES;
        BOOL running = started;
        [lock unlock];
        return vpDisplayUnavailable(running ? @"Layout capture exceeded the response deadline; private call may still be running"
                                            : @"Main run loop did not accept the capture before the deadline; queued capture cancelled",
                                    running ? @"timed_out_running" : @"cancelled_before_start");
    }
    [lock lock];
    NSDictionary *capture = result;
    [lock unlock];
    return capture;
}

static NSDictionary *vpModeDescription(id mode) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"width", @"height", @"refreshRate", @"isVirtual", @"preferredUIScale", @"pointScale"]) {
        if (![mode respondsToSelector:NSSelectorFromString(key)]) continue;
        id value = [mode valueForKey:key];
        if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) result[key] = value;
    }
    return result;
}

NSDictionary<NSString *, id> *vp_display_modes(void) {
    @try {
        dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY | RTLD_LOCAL);
        Class cls = objc_getClass("CADisplay");
        SEL enumerate = sel_registerName("displays");
        if (![cls respondsToSelector:enumerate]) return @{@"available": @NO, @"reason": @"CADisplay.displays unavailable"};
        SEL refresh = sel_registerName("updateDisplays");
        if ([cls respondsToSelector:refresh]) ((void (*)(id, SEL))objc_msgSend)(cls, refresh);
        id displays = ((id (*)(id, SEL))objc_msgSend)(cls, enumerate);
        if (![displays isKindOfClass:NSArray.class]) return @{@"available": @NO, @"reason": @"unexpected display collection"};
        NSMutableArray *rows = [NSMutableArray array];
        for (id display in displays) {
            NSMutableDictionary *row = [NSMutableDictionary dictionary];
            for (NSString *key in @[@"name", @"deviceName", @"displayId", @"displayType", @"allowsVirtualModes",
                                    @"isSupported", @"isExternal", @"isReference", @"isCloningSupported",
                                    @"isCloning", @"isCloned", @"pointScale", @"minimumLogicalScale",
                                    @"maximumLogicalScale", @"tag", @"seed", @"connectionSeed"]) {
                if (![display respondsToSelector:NSSelectorFromString(key)]) continue;
                id value = [display valueForKey:key];
                if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) row[key] = value;
            }
            for (NSString *key in @[@"bounds", @"nativeSize", @"currentOrientation", @"nativeOrientation", @"logicalScale", @"uniqueId"]) {
                if ([display respondsToSelector:NSSelectorFromString(key)]) row[key] = [[display valueForKey:key] description] ?: @"";
            }
            if ([display respondsToSelector:sel_registerName("currentMode")]) row[@"current_mode"] = vpModeDescription([display valueForKey:@"currentMode"]);
            if ([display respondsToSelector:sel_registerName("availableModes")]) {
                NSMutableArray *modes = [NSMutableArray array];
                for (id mode in [display valueForKey:@"availableModes"]) {
                    [modes addObject:vpModeDescription(mode)];
                    if (modes.count == 64) break;
                }
                row[@"available_modes"] = modes;
            }
            row[@"can_set_mode"] = @([display respondsToSelector:sel_registerName("setCurrentMode:")]);
            row[@"can_allow_virtual_modes"] = @([display respondsToSelector:sel_registerName("setAllowsVirtualModes:")]);
            if ([display respondsToSelector:sel_registerName("stateControl")]) {
                id state = [display valueForKey:@"stateControl"];
                NSMutableDictionary *values = [NSMutableDictionary dictionary];
                for (NSString *key in @[@"displayState", @"powerState", @"cloningState", @"targetDisplayState", @"targetPowerState"])
                    if ([state respondsToSelector:NSSelectorFromString(key)]) values[key] = [state valueForKey:key] ?: NSNull.null;
                row[@"state"] = values;
            }
            [rows addObject:row];
            if (rows.count == 16) break;
        }
        return @{@"available": @YES, @"displays": rows};
    } @catch (NSException *exception) {
        return @{@"available": @NO, @"reason": exception.reason ?: exception.name};
    }
}

/// Property keys worth reporting whole; everything else of a printable
/// scalar kind is reported by kind, and blobs are skipped.
static id valueForReport(id value) {
    if ([value isKindOfClass:NSNumber.class] || [value isKindOfClass:NSString.class]) {
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] > 96) {
            return nil;
        }
        return value;
    }
    if ([value isKindOfClass:NSData.class] && [(NSData *)value length] <= 16) {
        return [value description];
    }
    return nil;
}

NSArray *vp_display_probe(void) {
    NSMutableArray *found = [NSMutableArray array];
    // First the boot display handoff iBoot left in the device tree's
    // /chosen: the geometry early userspace inherits before any driver
    // re-reports it, and the outer size a stale one would pin UI to.
    io_registry_entry_t chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen");
    if (chosen != MACH_PORT_NULL) {
        io_name_t chosenName = {0};
        IORegistryEntryGetName(chosen, chosenName);
        NSMutableDictionary *chosenRow = [NSMutableDictionary dictionary];
        chosenRow[@"class"] = @"IODeviceTree:/chosen";
        chosenRow[@"name"] = [NSString stringWithUTF8String:chosenName] ?: @"chosen";
        CFMutableDictionaryRef chosenProps = NULL;
        if (IORegistryEntryCreateCFProperties(chosen, &chosenProps, kCFAllocatorDefault, kNilOptions)
            == KERN_SUCCESS && chosenProps) {
            NSMutableDictionary *reported = [NSMutableDictionary dictionary];
            NSDictionary *all = (__bridge NSDictionary *)chosenProps;
            for (NSString *key in all) {
                id value = valueForReport(all[key]);
                if (value) {
                    reported[key] = value;
                }
            }
            CFRelease(chosenProps);
            chosenRow[@"properties"] = reported;
        }
        IOObjectRelease(chosen);
        [found addObject:chosenRow];
    }
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOService"), &iterator)
        != KERN_SUCCESS) {
        return @[@{@"error": @"IOService enumeration failed"}];
    }
    io_object_t entry;
    while ((entry = IOIteratorNext(iterator))) {
        io_name_t cls = {0};
        if (IOObjectGetClass(entry, cls) != KERN_SUCCESS) {
            IOObjectRelease(entry);
            continue;
        }
        NSString *className = [NSString stringWithUTF8String:cls] ?: @"";
        NSString *lower = className.lowercaseString;
        bool displayish = [lower containsString:@"display"] || [lower containsString:@"framebuffer"]
            || [lower containsString:@"appleclcd"] || [lower containsString:@"gpu"];
        if (!displayish) {
            IOObjectRelease(entry);
            continue;
        }
        io_name_t name = {0};
        IORegistryEntryGetName(entry, name);
        NSMutableDictionary *row = [NSMutableDictionary dictionary];
        row[@"class"] = className;
        row[@"name"] = [NSString stringWithUTF8String:name] ?: @"";
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, kNilOptions)
            == KERN_SUCCESS && properties) {
            NSMutableDictionary *reported = [NSMutableDictionary dictionary];
            NSDictionary *all = (__bridge NSDictionary *)properties;
            for (NSString *key in all) {
                id value = valueForReport(all[key]);
                if (value) {
                    reported[key] = value;
                }
            }
            CFRelease(properties);
            row[@"properties"] = reported;
        }
        [found addObject:row];
        IOObjectRelease(entry);
        if (found.count >= 64) {
            IOObjectRelease(iterator);
            return found;
        }
    }
    IOObjectRelease(iterator);
    return found;
}
