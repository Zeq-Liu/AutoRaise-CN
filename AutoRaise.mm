/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Some pieces of the code are based on
 * metamove by jmgao as part of XFree86
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// g++ -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -o AutoRaise AutoRaise.mm \
//   -framework AppKit && ./AutoRaise

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <libproc.h>

#define AUTORAISE_VERSION "6.1"
#define STACK_THRESHOLD 20

#ifdef EXPERIMENTAL_FOCUS_FIRST
#if SKYLIGHT_AVAILABLE
// Focus first is an experimental feature that can break easily across different OSX
// versions. It relies on the private Skylight api. As such, there are absolutely no
// guarantees that this feature will keep on working in future versions of AutoRaise.
#define FOCUS_FIRST
#else
#pragma message "Skylight api is unavailable, Focus First is disabled"
#endif
#endif

// It seems OSX Monterey introduced a transparent 3 pixel border around each window. This
// means that when two windows are visually precisely connected and not overlapping, in
// reality they are. Consequently one has to move the mouse 3 pixels further out of the
// visual area to make the connected window raise. This new OSX 'feature' also introduces
// unwanted raising of windows when visually connected to the top menu bar. To solve this
// we correct the mouse position before determining which window is underneath the mouse.
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
#define SCREEN_EDGE_CORRECTION 1 // 1 <= value <= WINDOW_CORRECTION
// If the mouse position is within WINDOW_CORRECTION pixels of a screen edge,
// treat it as if it is SCREEN_EDGE_CORRECTION pixels removed from that edge.
static CGPoint oldCorrectedPoint = {0, 0};

// An activate delay of about 10 microseconds is just high enough to ensure we always
// find the latest focused (main)window. This value should be kept as low as possible.
#define ACTIVATE_DELAY_MS 10

#define SCALE_DELAY_MS 400 // The moment the mouse scaling should start, feel free to modify.
#define SCALE_DURATION_MS (SCALE_DELAY_MS+600) // Mouse scale duration, feel free to modify.
#define TASK_SWITCHER_MODIFIER_KEY kCGEventFlagMaskCommand // kCGEventFlagMaskControl, ...

#ifdef FOCUS_FIRST
#define kCPSUserGenerated 0x200
extern "C" CGError SLPSPostEventRecordTo(ProcessSerialNumber *psn, uint8_t *bytes);
extern "C" CGError _SLPSSetFrontProcessWithOptions(
  ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);

/* -----------Could these be a replacement for GetProcessForPID?-----------
extern "C" int SLSMainConnectionID(void);
extern "C" CGError SLSGetWindowOwner(int cid, uint32_t wid, int *wcid);
extern "C" CGError SLSGetConnectionPSN(int cid, ProcessSerialNumber *psn);
int element_connection;
SLSGetWindowOwner(SLSMainConnectionID(), window_id, &element_connection);
SLSGetConnectionPSN(element_connection, &window_psn);
-------------------------------------------------------------------------*/
#endif

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

#ifdef FOCUS_FIRST
static int raiseDelayCount = 0;
static pid_t lastFocusedWindow_pid;
static AXUIElementRef _lastFocusedWindow = NULL;
// 延迟回调（onWindowFocused:）用窗口 id 而不是指针做身份比对。
// 原实现把 _lastFocusedWindow 的指针值塞进 NSNumber 延迟 raiseDelay*poll 毫秒，
// 延迟期间 onTick 完全可能 CFRelease 掉旧元素并把 _lastFocusedWindow 指向新窗口：
// 旧指针值若被 AX 框架复用，回调会对已释放的引用 raiseAndActivate（UAF）；
// 指针不等时静默丢 raise。id 在窗口存续期内是稳定的，用它比对没有这些问题。
static CGWindowID lastFocusedWindow_id = kCGNullWindowID;
static pid_t lastFocusedWindow_pid_for_raise = 0;
#endif

static AXObserverRef axObserver = NULL;
static uint64_t lastDestroyedMouseWindow_id = kCGNullWindowID;
// 销毁标记的过期时刻（CFAbsoluteTime 秒）。
// CGWindowID 会被 WindowServer 复用：某个窗口销毁后，系统把同一个 id 分给新窗口，
// 此时 mouseWindow_id == lastDestroyedMouseWindow_id 成立，mouseWindowPresent 被判 false，
// 新窗口永远进不了提升分支。原实现只在「鼠标换到别的 id」时才清标记，
// 而一旦卡在复用场景，鼠标下面一直是同一个 id，标记永远清不掉 —— 永久卡死且无自愈。
// 加时效：标记只在短窗口内有效，过了就作废。
static CFTimeInterval lastDestroyedExpiry = 0;
static const CFTimeInterval destroyedMarkTTL = 1.0;

static CFMachPortRef eventTap = NULL;
static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static AXUIElementRef _dock_app = NULL;
static NSArray * ignoreApps = NULL;
static NSArray * ignoreTitles = NULL;
static NSArray * stayFocusedBundleIds = NULL;
static NSArray * const mainWindowAppsWithoutTitle =@[
    @"System Settings",
    @"System Information",
    @"Photos",
    @"Calculator",
    @"Podcasts",
    @"Stickies Pro",
    @"Reeder"
];
// 上面那份白名单按「应用显示名」匹配，而显示名是本地化的：
// 中文系统上 System Settings 叫「系统设置」、Photos 叫「照片」，
// 于是 7 项里有 6 项在中国区系统上必然失配（只有 Reeder/Stickies Pro
// 这类第三方应用名不随语言变）。这里补一份 bundle id 白名单，
// bundle id 不随语言和地区变化，两份取并集即可，不会漏判。
static NSArray * const mainWindowBundleIds =@[
    @"com.apple.systempreferences",   // 系统设置（macOS 13+ 仍沿用此 id）
    @"com.apple.SystemProfiler",      // 系统信息
    @"com.apple.Photos",              // 照片
    @"com.apple.calculator",          // 计算器
    @"com.apple.podcasts",            // 播客
    @"com.apple.Stickies",            // 便笺（原白名单写的 Third-party "Stickies Pro"）
];
// 需要「前缀」匹配的 bundle id：Reeder 的版本后缀不固定
//（com.reederapp / com.reederapp.mac 等），只能按前缀认。
// 其余项一律精确匹配 —— 用 hasPrefix 会把 com.apple.PhotosAgent、
// com.apple.calculator.widget 这类同厂子进程/小组件一并放行，范围过宽。
static NSArray * const mainWindowBundlePrefixes =@[
    @"com.reederapp",
];
static NSArray * pwas = @[
    @"Chrome",
    @"Chromium",
    @"Vivaldi",
    @"Brave",
    @"Opera",
    @"edgemac",
    @"helium"
];
static NSArray * AppsRaisingOnFocus = @[@"IntelliJ IDEA", @"PyCharm", @"WebStorm", @"Arc", @"Dia"];
static NSString * const DockBundleId = @"com.apple.dock";
static NSString * const FinderBundleId = @"com.apple.finder";
static NSString * const LittleSnitchBundleId = @"at.obdev.littlesnitch";
static NSString * const AssistiveControl = @"AssistiveControl";
static NSString * const MissionControl = @"Mission Control";
static NSString * const BartenderBar = @"Bartender Bar";
static NSString * const AppStoreSearchResults = @"Search results";
static NSString * const Untitled = @"Untitled"; // OSX Email search
static NSString * const Zim = @"Zim";
static NSString * const XQuartz = @"XQuartz";
static NSString * const Finder = @"Finder";
static NSString * const Pake = @"pake";
static NSString * const NoTitle = @"";
static CGPoint desktopOrigin = {0, 0};
static CGPoint oldPoint = {0, 0};
static bool propagateMouseMoved = false;
static bool requireMouseStop = true;
static bool requireMultipleScreens = false;
static bool requireScreenChange = false;
static bool ignoreSpaceChanged = false;
static bool invertDisableKey = false;
static bool invertIgnoreApps = false;
static bool spaceHasChanged = false;
static bool appWasActivated = false;
static bool altTaskSwitcher = false;
static bool warpMouse = false;
static bool warpOnlyAcrossScreens = false;
static bool verbose = false;
static float warpX = 0.5;
static float warpY = 0.5;
static float oldScale = 1;
static float cursorScale = 2;
static float mouseDelta = 0;
static int ignoreTimes = 0;
static int raiseTimes = 0;
static int delayTicks = 0;
static int delayCount = 0;
static int pollMillis = 0;
static int disableKey = 0;

//----------------------------------------yabai focus only methods------------------------------------------

#ifdef FOCUS_FIRST
// The two methods below, starting with "window_manager" were copied from
// https://github.com/koekeishiya/yabai and slightly modified. See also:
// https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
void window_manager_make_key_window(ProcessSerialNumber * _window_psn, uint32_t window_id) {
    uint8_t * bytes = (uint8_t *) malloc(0xf8);
    memset(bytes, 0, 0xf8);

    bytes[0x04] = 0xf8;
    bytes[0x3a] = 0x10;

    memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
    memset(bytes + 0x20, 0xFF, 0x10);

    bytes[0x08] = 0x01;
    SLPSPostEventRecordTo(_window_psn, bytes);

    bytes[0x08] = 0x02;
    SLPSPostEventRecordTo(_window_psn, bytes);
    free(bytes);
}

void window_manager_focus_window_without_raise(
    ProcessSerialNumber * _window_psn, uint32_t window_id,
    ProcessSerialNumber * _focused_window_psn, uint32_t focused_window_id
) {
    if (verbose) { NSLog(@"Focus"); }
    if (_focused_window_psn) {
        Boolean same_process;
        SameProcess(_window_psn, _focused_window_psn, &same_process);
        if (same_process) {
            if (verbose) { NSLog(@"Same process"); }
            uint8_t * bytes = (uint8_t *) malloc(0xf8);
            memset(bytes, 0, 0xf8);
            bytes[0x04] = 0xf8;
            bytes[0x08] = 0x0d;

            bytes[0x8a] = 0x02;
            memcpy(bytes + 0x3c, &focused_window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_focused_window_psn, bytes);

            // @hack
            // Artificially delay the activation by 1ms. This is necessary
            // because some applications appear to be confused if both of
            // the events appear instantaneously.
            usleep(10000);

            bytes[0x8a] = 0x01;
            memcpy(bytes + 0x3c, &window_id, sizeof(uint32_t));
            SLPSPostEventRecordTo(_window_psn, bytes);
            free(bytes);
        }
    }

    _SLPSSetFrontProcessWithOptions(_window_psn, window_id, kCPSUserGenerated);
    window_manager_make_key_window(_window_psn, window_id);
}
#endif

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#ifdef OLD_ACTIVATION_METHOD
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#else
    // Note activateWithOptions does not work properly on OSX 11.1
    [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
        activateWithOptions: 0];
#endif
}

inline void raiseAndActivate(AXUIElementRef _window, pid_t window_pid) {
    if (verbose) { NSLog(@"Raise"); }
    // kAXRaiseAction 是「应用内」动作：它只能把窗口提到同一应用的其他窗口之上。
    // 跨应用上位靠的是 activate()。所以 raise 失败只说明该 app 内部重排没成功，
    // 不代表不该激活这个 app —— 原实现把 activate 锁在 raise 成功分支里，
    // 一旦 raise 失败（过渡态里很常见）就连激活都不做，整个 tick 白跑且无补偿。
    AXError error = AXUIElementPerformAction(_window, kAXRaiseAction);
    if (error != kAXErrorSuccess && verbose) {
        NSLog(@"Raise failed with AXError %d, activating anyway", error);
    }
    activate(window_pid);
}

inline void logWindowTitle(NSString * prefix, AXUIElementRef _window) {
    CFStringRef _windowTitle = NULL;
    AXUIElementCopyAttributeValue(_window, kAXTitleAttribute, (CFTypeRef *) &_windowTitle);
    if (_windowTitle) {
        NSLog(@"%@: `%@`", prefix, _windowTitle);
        CFRelease(_windowTitle);
    } else {
        pid_t pid;
        NSString * _appName = NULL;
        if (AXUIElementGetPid(_window, &pid) == kAXErrorSuccess) {
            _appName = [NSRunningApplication runningApplicationWithProcessIdentifier: pid].localizedName;
        }
        if (_appName) { NSLog(@"%@ (app name): `%@`", prefix, _appName); }
        else { NSLog(@"%@: null", prefix); }
    }
}

// TODO: does not take into account different languages
inline bool titleEquals(AXUIElementRef _element, NSArray * _titles, NSArray * _patterns = NULL, bool logTitle = false) {
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    if (logTitle) { NSLog(@"element title: `%@`", _elementTitle); }
    if (_elementTitle) {
        NSString * _title = (__bridge NSString *) _elementTitle;
        equal = [_titles containsObject: _title];
        if (!equal && _patterns) {
            for (NSString * _pattern in _patterns) {
                equal = [_title rangeOfString: _pattern options: NSRegularExpressionSearch].location != NSNotFound;
                if (equal) { break; }
            }
        }
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

inline bool dock_active() {
    bool active = false;
    AXUIElementRef _focusedUIElement = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focusedUIElement);
    if (_focusedUIElement) {
        active = true;
        if (verbose) { NSLog(@"Dock is active"); }
        CFRelease(_focusedUIElement);
    }
    return active;
}

inline bool mc_active() {
    bool active = false;
    CFArrayRef _children = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXChildrenAttribute, (CFTypeRef *) &_children);
    if (_children) {
        CFIndex count = CFArrayGetCount(_children);
        for (CFIndex i=0;!active && i != count;i++) {
            CFStringRef _element_role = NULL;
            AXUIElementRef _element = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            if (_element_role) {
                active = CFEqual(_element_role, kAXGroupRole) && titleEquals(_element, @[MissionControl]);
                CFRelease(_element_role);
            }
        }
        CFRelease(_children);
    }

    if (verbose && active) { NSLog(@"Mission Control is active"); }
    return active;
}

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }

        NSRect window_bounds = NSMakeRect(
            [window_bounds_dict[@"X"] intValue],
            [window_bounds_dict[@"Y"] intValue],
            [window_bounds_dict[@"Width"] intValue],
            [window_bounds_dict[@"Height"] intValue]);

        if (NSPointInRect(NSPointFromCGPoint(point), window_bounds)) {
            top_window = window;
            break;
        }
    }

    return top_window;
}

AXUIElementRef fallback(CGPoint point) {
    if (verbose) { NSLog(@"Fallback"); }
    AXUIElementRef _window = NULL;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = NULL;
        pid_t pid = [top_window[(__bridge id) kCGWindowOwnerPID] intValue];
        AXUIElementRef _window_owner = AXUIElementCreateApplication(pid);
        AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(__bridge id) kCGWindowNumber] intValue];
            if (top_window_id) {
                for (id application_window in application_windows) {
                    CGWindowID application_window_id;
                    AXUIElementRef application_window_ax =
                        (__bridge AXUIElementRef) application_window;
                    if (_AXUIElementGetWindow(
                        application_window_ax,
                        &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == top_window_id) {
                            _window = application_window_ax;
                            CFRetain(_window);
                            break;
                        }
                    }
                }
            }
            // 空数组也要激活：app 刚关完所有窗口时 kAXWindowsAttribute 会返回
            // 空数组而不是 NULL，原实现只处理 NULL 的情况，空数组会遍历零次
            // 然后静默返回 NULL —— 既不返回窗口也不激活，与主 bug 同类的过渡态盲区。
            if (!_window && application_windows.count == 0) {
                activate(pid);
            }
        } else {
            activate(pid);
        }
    }

    return _window;
}

AXUIElementRef get_raisable_window(AXUIElementRef _element, CGPoint point, int count) {
    AXUIElementRef _window = NULL;
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            if (verbose) {
                NSLog(@"Stack threshold reached");
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    proc_pidpath(application_pid, pathBuffer, sizeof(pathBuffer));
                    NSLog(@"Application path: %s", pathBuffer);
                }
            }
            CFRelease(_element);
        } else {
            CFStringRef _element_role = NULL;
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            bool check_attributes = !_element_role;
            if (_element_role) {
                if (CFEqual(_element_role, kAXDockItemRole) ||
                    CFEqual(_element_role, kAXMenuItemRole) ||
                    CFEqual(_element_role, kAXMenuRole) ||
                    CFEqual(_element_role, kAXMenuBarRole) ||
                    CFEqual(_element_role, kAXMenuBarItemRole)) {
                    CFRelease(_element_role);
                    CFRelease(_element);
                } else if (
                    CFEqual(_element_role, kAXWindowRole) ||
                    CFEqual(_element_role, kAXSheetRole) ||
                    CFEqual(_element_role, kAXDrawerRole)) {
                    CFRelease(_element_role);
                    _window = _element;
                } else if (CFEqual(_element_role, kAXApplicationRole)) {
                    CFRelease(_element_role);
                    if (titleEquals(_element, @[XQuartz])) {
                        pid_t application_pid;
                        if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                            pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                                frontmostApplication] processIdentifier];
                            if (application_pid != frontmost_pid) {
                                // Focus and/or raising is the responsibility of XQuartz.
                                // As such AutoRaise features (delay/warp) do not apply.
                                activate(application_pid);
                            }
                        }
                        CFRelease(_element);
                    } else { check_attributes = true; }
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                bool no_parent = !_window;
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    if (!_window && no_parent) { _window = fallback(point); }
                }
                CFRelease(_element);
            }
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);

    AXUIElementRef _window = NULL;
    if (_element) {
        _window = get_raisable_window(_element, point, 0);
    } else if (error == kAXErrorCannotComplete || error == kAXErrorNotImplemented) {
        // fallback, happens for apps that do not support the Accessibility API
        if (verbose) { NSLog(@"Copy element: no accessibility support"); }
        _window = fallback(point);
    } else if (error == kAXErrorIllegalArgument) {
        // fallback, happens for Progressive Web Apps (PWAs)
        if (verbose) { NSLog(@"Copy element: illegal argument"); }
        _window = fallback(point);
    } else if (error == kAXErrorNoValue) {
        // fallback, happens sometimes when switching to another app (with cmd-tab)
        if (verbose) { NSLog(@"Copy element: no value"); }
        _window = fallback(point);
    } else if (error == kAXErrorAttributeUnsupported) {
        // no fallback, happens when hovering into volume/WiFi menubar window
        if (verbose) { NSLog(@"Copy element: attribute unsupported"); }
    } else if (error == kAXErrorFailure) {
        // no fallback, happens when hovering over the menubar itself
        if (verbose) { NSLog(@"Copy element: failure"); }
    } else if (error == kAXErrorAPIDisabled) {
        // No fallback, and reported even when not verbose: every accessibility call
        // fails from here on, so AutoRaise does nothing at all. Rebuilding changes the
        // ad hoc signature, which can leave a stale Accessibility entry behind.
        static bool reported = false;
        if (!reported) {
            reported = true;
            NSLog(@"Accessibility permission is not working, AutoRaise can not do anything. "
                "If you rebuilt AutoRaise, remove it under System Settings > Privacy & "
                "Security > Accessibility and add it again.");
        }
    } else if (verbose) {
        NSLog(@"Copy element: AXError %d", error);
    }

    if (verbose) {
        if (_window) { logWindowTitle(@"Mouse window", _window); }
        else { NSLog(@"No raisable window"); }
    }

    return _window;
}

inline bool windowPosition(AXUIElementRef _window, CGPoint * position) {
    bool found = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        found = AXValueGetValue(_pos, kAXValueTypeCGPoint, position);
        CFRelease(_pos);
    }

    return found;
}

inline bool windowSize(AXUIElementRef _window, CGSize * size) {
    bool found = false;
    AXValueRef _size = NULL;
    AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
    if (_size) {
        found = AXValueGetValue(_size, kAXValueTypeCGSize, size);
        CFRelease(_size);
    }

    return found;
}

CGPoint get_mousepoint(AXUIElementRef _window) {
    CGPoint mousepoint = {0, 0};
    CGSize cg_size;
    CGPoint cg_pos;
    if (windowSize(_window, &cg_size) && windowPosition(_window, &cg_pos)) {
        mousepoint.x = cg_pos.x + (cg_size.width * warpX);
        mousepoint.y = cg_pos.y + (cg_size.height * warpY);
    }

    return mousepoint;
}

bool contained_within(AXUIElementRef _window1, AXUIElementRef _window2) {
    bool contained = false;
    CGSize cg_size1;
    CGSize cg_size2;
    CGPoint cg_pos1;
    CGPoint cg_pos2;

    if (windowSize(_window1, &cg_size1) && windowPosition(_window1, &cg_pos1) &&
        windowSize(_window2, &cg_size2) && windowPosition(_window2, &cg_pos2)) {
        contained = cg_pos1.x > cg_pos2.x && cg_pos1.y > cg_pos2.y &&
            cg_pos1.x + cg_size1.width < cg_pos2.x + cg_size2.width &&
            cg_pos1.y + cg_size1.height < cg_pos2.y + cg_size2.height;
    }

    return contained;
}

void findDockApplication() {
    NSArray * _apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication * app in _apps) {
        if ([app.bundleIdentifier isEqual: DockBundleId]) {
            _dock_app = AXUIElementCreateApplication(app.processIdentifier);
            break;
        }
    }

    if (verbose && !_dock_app) { NSLog(@"Dock application isn't running"); }
}

// The accessibility API reports positions from the top left of the main screen with
// y growing downward, NSScreen frames start at their own bottom left with y growing
// upward. This is the top left corner of a screen in accessibility coordinates.
inline CGPoint screen_origin(NSScreen * screen) {
    return CGPointMake(NSMinX(screen.frame),
        NSMaxY(NSScreen.screens[0].frame) - NSMaxY(screen.frame));
}

void findDesktopOrigin() {
    for (NSScreen * screen in [NSScreen screens]) {
        CGPoint origin = screen_origin(screen);
        if (origin.y < desktopOrigin.y) { desktopOrigin.y = origin.y; }
        if (origin.x < desktopOrigin.x) { desktopOrigin.x = origin.x; }
    }

    if (verbose) { NSLog(@"Desktop origin (%f, %f)", desktopOrigin.x, desktopOrigin.y); }
}

inline NSScreen * findScreen(CGPoint point) {
    for (NSScreen * screen in [NSScreen screens]) {
        CGPoint origin = screen_origin(screen);
        NSRect screen_bounds = NSMakeRect(
            origin.x,
            origin.y,
            NSWidth(screen.frame),
            NSHeight(screen.frame)
        );
        if (NSPointInRect(NSPointFromCGPoint(point), screen_bounds)) {
            return screen;
        }
    }
    return NULL;
}

// Take the centre rather than the top left corner: a window straddling two screens
// belongs to the one it is mostly on, not the one its corner happens to land in.
inline NSScreen * findScreenByWindow(AXUIElementRef _window) {
    CGPoint cg_pos;
    CGSize cg_size;
    if (windowPosition(_window, &cg_pos) && windowSize(_window, &cg_size)) {
        return findScreen(CGPointMake(cg_pos.x + cg_size.width / 2,
                                      cg_pos.y + cg_size.height / 2));
    }

    return NULL;
}

// Tiling window managers park windows of inactive workspaces almost fully
// offscreen, leaving only the few pixels macOS insists on. Raising such a sliver
// switches workspace and parks the previous window in its place, which without
// this check makes the two raise each other indefinitely.
#define MIN_VISIBLE 4
inline bool is_offscreen_window(AXUIElementRef _window, CGPoint point) {
    bool offscreen = false;
    NSScreen * screen = findScreen(point);
    CGSize cg_size;
    CGPoint cg_pos;
    if (screen && windowSize(_window, &cg_size) && windowPosition(_window, &cg_pos)) {
        CGPoint origin = screen_origin(screen);
        NSRect visible = NSIntersectionRect(
            NSMakeRect(origin.x, origin.y,
                NSWidth(screen.frame), NSHeight(screen.frame)),
            NSMakeRect(cg_pos.x, cg_pos.y, cg_size.width, cg_size.height));
        offscreen = NSWidth(visible) < MIN_VISIBLE || NSHeight(visible) < MIN_VISIBLE;
    }

    if (verbose && offscreen) { NSLog(@"Offscreen window"); }
    return offscreen;
}

inline bool is_desktop_window(AXUIElementRef _window) {
    CGPoint cg_pos;
    bool desktop_window = windowPosition(_window, &cg_pos) &&
        NSEqualPoints(NSPointFromCGPoint(cg_pos), NSPointFromCGPoint(desktopOrigin));

    if (verbose && desktop_window) { NSLog(@"Desktop window"); }
    return desktop_window;
}

inline bool is_full_screen(AXUIElementRef _window) {
    bool full_screen = false;
    CGPoint cg_pos;
    CGSize cg_size;
    if (windowPosition(_window, &cg_pos)) {
        NSScreen * screen = findScreen(cg_pos);
        if (screen && windowSize(_window, &cg_size)) {
            float menuBarHeight =
                fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
            CGPoint origin = screen_origin(screen);
            full_screen = cg_pos.x == origin.x &&
                          cg_pos.y == origin.y + menuBarHeight &&
                          cg_size.width == NSWidth(screen.frame) &&
                          cg_size.height == NSHeight(screen.frame) - menuBarHeight;
        }
    }

    if (verbose && full_screen) { NSLog(@"Full screen window"); }
    return full_screen;
}

inline bool is_main_window(AXUIElementRef _app, AXUIElementRef _window, bool chrome_app) {
    bool main_window = false;
    CFBooleanRef _result = NULL;

    // 用 bundleIdentifier 判断是不是访达。
    // 原实现用 titleEquals(_app, @[Finder])，读的是应用名（本地化）：
    // 中文系统上访达叫「访达」而不是「Finder」，匹配必然失败，
    // 于是下面所有访达豁免逻辑（无标题放行、全屏判断）在中文系统上全部失效。
    // bundle id 是 com.apple.finder，不随语言变化。
    pid_t app_pid_for_finder = 0;
    bool finder_app = false;
    NSString * app_bundle_id = nil;
    if (AXUIElementGetPid(_app, &app_pid_for_finder) == kAXErrorSuccess) {
        app_bundle_id = [NSRunningApplication
            runningApplicationWithProcessIdentifier: app_pid_for_finder].bundleIdentifier;
        finder_app = [app_bundle_id isEqual: FinderBundleId];
    }
    if (!finder_app) { finder_app = titleEquals(_app, @[Finder]); }

    // 白名单同样改成 bundle id 优先：中文系统上应用显示名全部本地化，
    // 按名字匹配等于没写（详见 mainWindowBundleIds 处注释）。
    // 两份取并集：bundle id 命中即算；没命中再退回原来的名字匹配，
    // 这样第三方应用（名字不本地化）和老行为都不受影响。
    bool whitelisted_app = false;
    if (app_bundle_id) {
        // 精确匹配优先：避免同厂子进程（PhotosAgent 等）被 hasPrefix 误放行。
        whitelisted_app = [mainWindowBundleIds containsObject: app_bundle_id];
        if (!whitelisted_app) {
            for (NSString * prefix in mainWindowBundlePrefixes) {
                if ([app_bundle_id hasPrefix: prefix]) { whitelisted_app = true; break; }
            }
        }
    }
    if (!whitelisted_app) { whitelisted_app = titleEquals(_app, mainWindowAppsWithoutTitle); }

    // kAXMainAttribute 的语义陷阱：它只对「当前前台应用」的窗口为 true。
    // 应用在后台时其主窗口 AXMain=false —— 但那不代表它不是正经主窗口。
    // 原实现据此判定，导致后台的无标题主窗口（系统设置/计算器/照片等
    // mainWindowAppsWithoutTitle 白名单应用）永远无法被提升，白名单形同虚设。
    // 这里改为：AXMain 仅作为「有值」时的参考，不再能否决；
    // 真正的浮层/对话框由 subrole 判断。
    bool ax_main_true = false;
    AXUIElementCopyAttributeValue(_window, kAXMainAttribute, (CFTypeRef *) &_result);
    if (_result) {
        ax_main_true = CFEqual(_result, kCFBooleanTrue);
        CFRelease(_result);
    }

    CFStringRef _element_sub_role = NULL;
    AXUIElementCopyAttributeValue(_window, kAXSubroleAttribute, (CFTypeRef *) &_element_sub_role);
    bool is_dialog = false;
    if (_element_sub_role) {
        is_dialog = CFEqual(_element_sub_role, kAXDialogSubrole);
        CFRelease(_element_sub_role);
    }

    // 对话框只在「它就是前台主窗口」时才排除；后台窗口是对话框也无所谓，
    // 因为后台 app 的窗口本来就该允许被提升。
    if (ax_main_true && is_dialog) {
        if (verbose) { NSLog(@"Dialog window"); }
        return false;
    }

    // 有标题的窗口直接放行；无标题的需要进一步确认。
    main_window = chrome_app || finder_app ||
        !titleEquals(_window, @[NoTitle]) ||
        whitelisted_app;

    // 无标题且不在白名单里：此时才参考 AXMain，但不因此否决后台窗口。
    if (!main_window && ax_main_true) { main_window = true; }

    main_window = main_window || (!finder_app && is_full_screen(_window));

    if (verbose && !main_window) { NSLog(@"Not a main window"); }
    return main_window;
}

inline bool is_pwa(NSString * bundleIdentifier) {
    NSArray * components = [bundleIdentifier componentsSeparatedByString: @"."];
    bool pake = components.count == 3 && [components[1] isEqual: Pake];
    // browser channels (canary, beta, dev) insert one component before "app"
    bool pwa = pake || (components.count > 4 && [pwas containsObject: components[2]] &&
        ([components[3] isEqual: @"app"] ||
        (components.count > 5 && [components[4] isEqual: @"app"])));
    if (verbose && pwa) { NSLog(@"PWA: %@", components[2]); }
    return pwa;
}

//-----------------------------------------------notifications----------------------------------------------

void spaceChanged();
bool appActivated();
void onTick();

@interface MDWorkspaceWatcher:NSObject {}
- (id)init;
@end

static MDWorkspaceWatcher * workspaceWatcher = NULL;

@implementation MDWorkspaceWatcher
- (id)init {
    if ((self = [super init])) {
        NSNotificationCenter * center =
            [[NSWorkspace sharedWorkspace] notificationCenter];
        [center
            addObserver: self
            selector: @selector(spaceChanged:)
            name: NSWorkspaceActiveSpaceDidChangeNotification
            object: nil];
        if (warpMouse) {
            [center
                addObserver: self
                selector: @selector(appActivated:)
                name: NSWorkspaceDidActivateApplicationNotification
                object: nil];
            if (verbose) { NSLog(@"Registered app activated selector"); }
        }
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver: self];
}

- (void)spaceChanged:(NSNotification *)notification {
    if (verbose) { NSLog(@"Space changed"); }
    spaceChanged();
}

- (void)appActivated:(NSNotification *)notification {
    if (verbose) { NSLog(@"App activated, waiting %0.3fs", ACTIVATE_DELAY_MS/1000.0); }
    [self performSelector: @selector(onAppActivated) withObject: nil afterDelay: ACTIVATE_DELAY_MS/1000.0];
}

- (void)onAppActivated {
    if (appActivated() && cursorScale != oldScale) {
        if (verbose) { NSLog(@"Set cursor scale after %0.3fs", SCALE_DELAY_MS/1000.0); }
        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: cursorScale]
            afterDelay: SCALE_DELAY_MS/1000.0];

        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: oldScale]
            afterDelay: SCALE_DURATION_MS/1000.0];
    }
}

- (void)onSetCursorScale:(NSNumber *)scale {
    if (verbose) { NSLog(@"Set cursor scale: %@", scale); }
    CGSSetCursorScale(CGSMainConnectionID(), scale.floatValue);
}

- (void)onTick:(NSNumber *)timerInterval {
    [self performSelector: @selector(onTick:)
        withObject: timerInterval
        afterDelay: timerInterval.floatValue];
    onTick();
}

#ifdef FOCUS_FIRST
- (void)windowFocused:(AXUIElementRef)_window {
    if (verbose) { NSLog(@"Window focused, waiting %0.3fs", raiseDelayCount*pollMillis/1000.0); }
    [self performSelector: @selector(onWindowFocused:)
        withObject: [NSNumber numberWithUnsignedLong: (uint64_t) lastFocusedWindow_id]
        afterDelay: raiseDelayCount*pollMillis/1000.0];
}

- (void)onWindowFocused:(NSNumber *)_window {
    // 按 id 比对（见 lastFocusedWindow_id 处注释）。pid 快照同步携带，
    // 避免依赖延迟期间可能已变化的全局 lastFocusedWindow_pid。
    if (_window.unsignedLongValue == (uint64_t) lastFocusedWindow_id &&
        lastFocusedWindow_id != kCGNullWindowID) {
        raiseAndActivate(_lastFocusedWindow, lastFocusedWindow_pid_for_raise);
    } else if (verbose) { NSLog(@"Ignoring window focused event"); }
}
#endif
@end // MDWorkspaceWatcher

//----------------------------------------------configuration-----------------------------------------------

const NSString *kDelay = @"delay";
const NSString *kWarpX = @"warpX";
const NSString *kWarpY = @"warpY";
const NSString *kScale = @"scale";
const NSString *kVerbose = @"verbose";
const NSString *kAltTaskSwitcher = @"altTaskSwitcher";
const NSString *kRequireMouseStop = @"requireMouseStop";
const NSString *kRequireMultipleScreens = @"requireMultipleScreens";
const NSString *kRequireScreenChange = @"requireScreenChange";
const NSString *kWarpOnlyAcrossScreens = @"warpOnlyAcrossScreens";
const NSString *kIgnoreSpaceChanged = @"ignoreSpaceChanged";
const NSString *kStayFocusedBundleIds = @"stayFocusedBundleIds";
const NSString *kInvertDisableKey = @"invertDisableKey";
const NSString *kInvertIgnoreApps = @"invertIgnoreApps";
const NSString *kIgnoreApps = @"ignoreApps";
const NSString *kIgnoreTitles = @"ignoreTitles";
const NSString *kMouseDelta = @"mouseDelta";
const NSString *kPollMillis = @"pollMillis";
const NSString *kDisableKey = @"disableKey";
#ifdef FOCUS_FIRST
const NSString *kFocusDelay = @"focusDelay";
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kWarpOnlyAcrossScreens,
    kVerbose, kAltTaskSwitcher, kFocusDelay, kRequireMouseStop, kRequireMultipleScreens, kRequireScreenChange,
    kIgnoreSpaceChanged, kInvertDisableKey, kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles,
    kStayFocusedBundleIds, kDisableKey, kMouseDelta, kPollMillis];
#else
NSArray *parametersDictionary = @[kDelay, kWarpX, kWarpY, kScale, kWarpOnlyAcrossScreens,
    kVerbose, kAltTaskSwitcher, kRequireMouseStop, kRequireMultipleScreens, kRequireScreenChange, kIgnoreSpaceChanged,
    kInvertDisableKey, kInvertIgnoreApps, kIgnoreApps, kIgnoreTitles, kStayFocusedBundleIds,
    kDisableKey, kMouseDelta, kPollMillis];
#endif
NSMutableDictionary *parameters = [[NSMutableDictionary alloc] init];

@interface ConfigClass:NSObject
- (NSString *) getFilePath:(NSString *) filename;
- (void) readConfig:(int) argc;
- (void) readHiddenConfig;
- (void) validateParameters;
@end

@implementation ConfigClass
- (NSString *) getFilePath:(NSString *) filename {
    filename = [NSString stringWithFormat: @"%@/%@", NSHomeDirectory(), filename];
    if (not [[NSFileManager defaultManager] fileExistsAtPath: filename]) { filename = NULL; }
    return filename;
}

- (void) readConfig:(int) argc {
    if (argc > 1) {
        // read NSArgumentDomain
        NSUserDefaults *arguments = [NSUserDefaults standardUserDefaults];

        for (id key in parametersDictionary) {
            id arg = [arguments objectForKey: key];
            if (arg != NULL) { parameters[key] = arg; }
        }
    } else {
        [self readHiddenConfig];
    }
    return;
}

- (void) readHiddenConfig {
    // search for dotfiles
    NSString * hiddenConfigFilePath = [self getFilePath: @".AutoRaise"];
    if (!hiddenConfigFilePath) { hiddenConfigFilePath = [self getFilePath: @".config/AutoRaise/config"]; }

    if (hiddenConfigFilePath) {
        NSError * error;
        NSString * configContent = [[NSString alloc]
            initWithContentsOfFile: hiddenConfigFilePath
            encoding: NSUTF8StringEncoding error: &error];

        NSArray * configLines = [configContent componentsSeparatedByString: @"\n"];
        NSString * trimmedLine, * trimmedKey, * trimmedValue, * noQuotesValue;
        NSArray * components;
        for (NSString * line in configLines) {
            trimmedLine = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            if (not [trimmedLine hasPrefix: @"#"]) {
                components = [trimmedLine componentsSeparatedByString: @"="];
                if ([components count] == 2) {
                    for (id key in parametersDictionary) {
                       trimmedKey = [components[0] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       trimmedValue = [components[1] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       noQuotesValue = [trimmedValue stringByReplacingOccurrencesOfString: @"\"" withString: @""];
                       if ([trimmedKey isEqual: key]) { parameters[key] = noQuotesValue; }
                    }
                }
            }
        }
    }
    return;
}

- (void) validateParameters {
    // validate and fix wrong/absent parameters
#ifdef FOCUS_FIRST
    if (!parameters[kFocusDelay] && !parameters[kDelay]) {
#else
    if (!parameters[kDelay]) {
#endif
        parameters[kDelay] = @"1";
    }
    if (!parameters[kRequireMouseStop]) { parameters[kRequireMouseStop] = @"true"; }
    if ([parameters[kPollMillis] intValue] < 20) { parameters[kPollMillis] = @"50"; }
    if ([parameters[kMouseDelta] floatValue] < 0) { parameters[kMouseDelta] = @"0"; }
    if ([parameters[kScale] floatValue] < 1) { parameters[kScale] = @"2.0"; }
    if (!parameters[kDisableKey]) { parameters[kDisableKey] = @"control"; }
    warpMouse =
        parameters[kWarpX] && [parameters[kWarpX] floatValue] >= 0 && [parameters[kWarpX] floatValue] <= 1 &&
        parameters[kWarpY] && [parameters[kWarpY] floatValue] >= 0 && [parameters[kWarpY] floatValue] <= 1;
#ifdef ALTERNATIVE_TASK_SWITCHER
    if (!parameters[kAltTaskSwitcher]) { parameters[kAltTaskSwitcher] = @"true"; }
#endif
#ifdef FOCUS_FIRST
    if (![parameters[kDelay] intValue] && !parameters[kFocusDelay]) { parameters[kFocusDelay] = @"1"; }
    if (!parameters[kDelay] && ![parameters[kFocusDelay] intValue]) { parameters[kDelay] = @"1"; }
#endif
    return;
}
@end // ConfigClass

//------------------------------------------where it all happens--------------------------------------------

void spaceChanged() {
    spaceHasChanged = true;
    oldPoint.x = oldPoint.y = 0;
}

bool appActivated() {
    if (verbose) { NSLog(@"App activated"); }
    if (!altTaskSwitcher) {
        if (!activated_by_task_switcher) { return false; }
        activated_by_task_switcher = false;
    }
    appWasActivated = true;

    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontmost_pid = frontmostApp.processIdentifier;

    AXUIElementRef _activatedWindow = NULL;
    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
    AXUIElementCopyAttributeValue(_frontmostApp,
        kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
    if (!_activatedWindow) {
        if (verbose) { NSLog(@"No main window, trying focused window"); }
        AXUIElementCopyAttributeValue(_frontmostApp,
            kAXFocusedWindowAttribute, (CFTypeRef *) &_activatedWindow);
    }
    CFRelease(_frontmostApp);

    if (verbose) { NSLog(@"BundleIdentifier: %@", frontmostApp.bundleIdentifier); }
    bool finder_app = [frontmostApp.bundleIdentifier isEqual: FinderBundleId];
    if (finder_app) {
        if (_activatedWindow) {
            if (is_desktop_window(_activatedWindow)) {
                CFRelease(_activatedWindow);
                _activatedWindow = _previousFinderWindow;
            } else {
                if (_previousFinderWindow) { CFRelease(_previousFinderWindow); }
                _previousFinderWindow = _activatedWindow;
            }
        } else { _activatedWindow = _previousFinderWindow; }
    }

    if (altTaskSwitcher) {
        CGEventRef _event = CGEventCreate(NULL);
        CGPoint mousePoint = CGEventGetLocation(_event);
        if (_event) { CFRelease(_event); }

        bool ignoreActivated = false;
        // TODO: is the uncorrected mousePoint good enough?
        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            if (!activated_by_task_switcher) {
                pid_t mouseWindow_pid;
                // Checking for mouse movement reduces the problem of the mouse being warped
                // when changing spaces and simultaneously moving the mouse to another screen
                ignoreActivated = fabs(mousePoint.x-oldPoint.x) > 0;
                ignoreActivated = ignoreActivated || fabs(mousePoint.y-oldPoint.y) > 0;
                // Check if the mouse is already hovering above the frontmost app. If
                // for example we only change spaces, we don't want the mouse to warp
                ignoreActivated = ignoreActivated || (AXUIElementGetPid(_mouseWindow,
                    &mouseWindow_pid) == kAXErrorSuccess && mouseWindow_pid == frontmost_pid);
            }
            CFRelease(_mouseWindow);
        } else { // dock or top menu
            // Comment the line below if clicking the dock icons should also
            // warp the mouse. Note this may introduce some unexpected warps
            ignoreActivated = true;
        }

        activated_by_task_switcher = false; // used in the previous code block

        if (ignoreActivated) {
            if (verbose) { NSLog(@"Ignoring app activated"); }
            if (!finder_app && _activatedWindow) { CFRelease(_activatedWindow); }
            return false;
        }
    }

    // The caller enlarges the cursor. That still happens when there was no window to
    // warp to, so you can find the pointer after a switch that did not move it, but
    // not when the warp was skipped on purpose: nothing moved and nothing is lost.
    bool scaleCursor = true;
    if (_activatedWindow) {
        bool sameScreen = false;
        if (warpOnlyAcrossScreens) {
            CGEventRef _event = CGEventCreate(NULL);
            CGPoint mousePoint = CGEventGetLocation(_event);
            if (_event) { CFRelease(_event); }
            sameScreen = findScreen(mousePoint) == findScreenByWindow(_activatedWindow);
        }

        if (sameScreen) {
            if (verbose) { NSLog(@"Not warping within the same screen"); }
            scaleCursor = false;
        } else {
            if (verbose) { NSLog(@"Warp mouse"); }
            CGWarpMouseCursorPosition(get_mousepoint(_activatedWindow));
        }
        if (!finder_app) { CFRelease(_activatedWindow); }
    }

    return scaleCursor;
}

void AXCallback(AXObserverRef observer, AXUIElementRef _element, CFStringRef notification, void * destroyedMouseWindow_id) {
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        lastDestroyedMouseWindow_id = (uint64_t) destroyedMouseWindow_id;
        // 与标记同时记录过期时刻，避免 CGWindowID 复用造成永久压制。
        lastDestroyedExpiry = CFAbsoluteTimeGetCurrent() + destroyedMarkTTL;
    }
}

void onTick() {
    // determine if mouseMoved
    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    float mouse_x_diff = mousePoint.x-oldPoint.x;
    float mouse_y_diff = mousePoint.y-oldPoint.y;
    oldPoint = mousePoint;

    bool mouseMoved = fabs(mouse_x_diff) > mouseDelta;
    mouseMoved = mouseMoved || fabs(mouse_y_diff) > mouseDelta;
    bool mouseStopped = !mouseMoved;
    mouseMoved = mouseMoved || propagateMouseMoved;
    propagateMouseMoved = false;

#ifdef FOCUS_FIRST
    // !delayCount && !raiseDelayCount -> warp only (no focus, no raise)
    if (altTaskSwitcher && !delayCount && !raiseDelayCount) { return; }
    bool focus_first = delayCount && raiseDelayCount != 1;
#else
    // !delayCount -> warp only (no raise)
    if (altTaskSwitcher && !delayCount) { return; }
#endif

    // delayTicks = 0 -> delay disabled
    // delayTicks = 1 -> delay finished
    // delayTicks = n -> delay started
    if (delayTicks > 1) { delayTicks--; }

    if (@available(macOS 12.00, *)) {
        // the correction should be applied before we return
        // under certain conditions in the code after it. This
        // ensures oldCorrectedPoint always has a recent value.
        if (mouseMoved) {
            NSScreen * screen = findScreen(mousePoint);
            if (verbose) {
                // a screen keeps its display id across a reconfiguration, its NSScreen
                // does not necessarily keep its address
                static CGDirectDisplayID loggedDisplay = kCGNullDirectDisplay;
                CGDirectDisplayID display = screen ? [screen.deviceDescription[
                    @"NSScreenNumber"] unsignedIntValue] : kCGNullDirectDisplay;
                if (display != loggedDisplay) {
                    loggedDisplay = display;
                    if (screen) {
                        CGPoint origin = screen_origin(screen);
                        NSLog(@"Mouse screen: %@, origin (%.0f, %.0f), mouse (%.1f, %.1f)",
                            screen.localizedName, origin.x, origin.y, mousePoint.x, mousePoint.y);
                    } else {
                        NSLog(@"Mouse screen: none, mouse (%.1f, %.1f)", mousePoint.x, mousePoint.y);
                    }
                }
            }
            mousePoint.x += mouse_x_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
            mousePoint.y += mouse_y_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
            if (screen) {
                CGPoint origin = screen_origin(screen);

                if (oldPoint.x > origin.x + NSWidth(screen.frame) - WINDOW_CORRECTION) {
                    if (verbose) { NSLog(@"Screen edge correction"); }
                    mousePoint.x = origin.x + NSWidth(screen.frame) - SCREEN_EDGE_CORRECTION;
                } else if (oldPoint.x < origin.x + WINDOW_CORRECTION - 1) {
                    if (verbose) { NSLog(@"Screen edge correction"); }
                    mousePoint.x = origin.x + SCREEN_EDGE_CORRECTION;
                }

                if (oldPoint.y > origin.y + NSHeight(screen.frame) - WINDOW_CORRECTION) {
                    if (verbose) { NSLog(@"Screen edge correction"); }
                    mousePoint.y = origin.y + NSHeight(screen.frame) - SCREEN_EDGE_CORRECTION;
                } else {
                    float menuBarHeight = fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                    if (mousePoint.y < origin.y + menuBarHeight + MENUBAR_CORRECTION) {
                        if (verbose) { NSLog(@"Menu bar correction"); }
                        mousePoint.y = origin.y;
                    }
                }
            }
            oldCorrectedPoint = mousePoint;
        } else {
            mousePoint = oldCorrectedPoint;
        }
    }

    if (ignoreTimes) {
        ignoreTimes--;
        return;
    } else if (appWasActivated) {
        appWasActivated = false;
        return;
    } else if (spaceHasChanged) {
        // spaceHasChanged has priority
        // over waiting for the delay
        if (mouseMoved) { return; }
        else if (!ignoreSpaceChanged) {
            raiseTimes = 3;
            delayTicks = 0;
        }
        spaceHasChanged = false;
    } else if (requireMouseStop && !mouseStopped && mouseMoved) {
        delayTicks = 0;
        // propagate the mouseMoved event
        // to restart the delay if needed
        propagateMouseMoved = true;
        return;
    }

    // mouseMoved: we have to decide if the window needs raising
    // delayTicks: count down as long as the mouse doesn't move
    // raiseTimes: the window needs raising a couple of times.
    if (mouseMoved || delayTicks || raiseTimes) {
        // don't raise for as long as something is being dragged (resizing a window for instance)
        bool abort = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
            CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
            dock_active() || mc_active() ||
            (requireMultipleScreens && NSScreen.screens.count < 2);

        if (!abort && disableKey) {
            CGEventRef _keyDownEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
            CGEventFlags flags = CGEventGetFlags(_keyDownEvent);
            if (_keyDownEvent) { CFRelease(_keyDownEvent); }
            abort = (flags & disableKey) == disableKey;
            abort = abort != invertDisableKey;
        }

        NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
        abort = abort || [stayFocusedBundleIds containsObject: frontmostApp.bundleIdentifier];

        if (abort) {
            if (verbose) { NSLog(@"Abort focus/raise"); }
            raiseTimes = 0;
            delayTicks = 0;
            return;
        }

        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            pid_t mouseWindow_pid;
            if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) == kAXErrorSuccess) {
                CGWindowID mouseWindow_id = kCGNullWindowID;
                // _AXUIElementGetWindow 失败时会把 out 参数写成 0（实测），
                // 而 kCGNullWindowID 本身就是 0。若不区分"失败"与"id 真是 0"，
                // 下面 mouseWindowPresent 的 != 比较会把取 id 失败误判成
                // "窗口刚被销毁"，needs_raise 归零后永久不再提升。
                bool mouseWindowIdValid =
                    _AXUIElementGetWindow(_mouseWindow, &mouseWindow_id) == kAXErrorSuccess;
                // 销毁标记过期后作废，避免 CGWindowID 复用导致永久压制（见 destroyedMarkTTL 处注释）。
                if (lastDestroyedMouseWindow_id != kCGNullWindowID &&
                    CFAbsoluteTimeGetCurrent() > lastDestroyedExpiry) {
                    lastDestroyedMouseWindow_id = kCGNullWindowID;
                    if (verbose) { NSLog(@"Destroyed window mark expired"); }
                }
                bool mouseWindowPresent = !mouseWindowIdValid ||
                    mouseWindow_id != lastDestroyedMouseWindow_id;
                if (mouseWindowPresent) {
                    static CGWindowID previous_id = kCGNullWindowID;
                    if (mouseWindow_id != previous_id) {
                        previous_id = mouseWindow_id;

                        lastDestroyedMouseWindow_id = kCGNullWindowID;
                        raiseTimes = 0;
                        delayTicks = 0;

                        if (axObserver) {
                            CFRelease(axObserver);
                            axObserver = NULL;
                        }

                        AXObserverCreate(
                            mouseWindow_pid,
                            AXCallback,
                            &axObserver
                        );

                        AXObserverAddNotification(
                            axObserver,
                            _mouseWindow,
                            kAXUIElementDestroyedNotification,
                            (void *) ((uint64_t) mouseWindow_id)
                        );

                        CFRunLoopAddSource(
                            CFRunLoopGetCurrent(),
                            AXObserverGetRunLoopSource(axObserver),
                            kCFRunLoopCommonModes
                        );
                    }
                } else if (verbose) { NSLog(@"Mouse window not present"); }

#ifdef FOCUS_FIRST
                bool workaround_for_apps_raising_on_focus = false;
#endif
                bool needs_raise = !invertIgnoreApps && mouseWindowPresent;
                AXUIElementRef _mouseWindowApp = AXUIElementCreateApplication(mouseWindow_pid);
                if (needs_raise && titleEquals(_mouseWindow, @[NoTitle, Untitled])) {
                    needs_raise = is_main_window(_mouseWindowApp, _mouseWindow, is_pwa(
                        [NSRunningApplication runningApplicationWithProcessIdentifier:
                        mouseWindow_pid].bundleIdentifier));
                    if (verbose && !needs_raise) { NSLog(@"Excluding window"); }
                } else if (needs_raise &&
                    titleEquals(_mouseWindow, @[BartenderBar, Zim, AppStoreSearchResults], ignoreTitles)) {
                    needs_raise = false;
                    if (verbose) { NSLog(@"Excluding window"); }
                } else if (mouseWindowPresent) {
                    if (titleEquals(_mouseWindowApp, ignoreApps)) {
                        needs_raise = invertIgnoreApps;
                        if (verbose) {
                            if (invertIgnoreApps) {
                                NSLog(@"Including app");
                            } else {
                                NSLog(@"Excluding app");
                            }
                        }
                    }
#ifdef FOCUS_FIRST
                    workaround_for_apps_raising_on_focus = titleEquals(_mouseWindowApp, AppsRaisingOnFocus);
#endif
                }
                // app 级黑名单必须独立于上面的 else-if 链再查一次。
                // 原实现把 ignoreApps 放在链尾的 `else if (mouseWindowPresent)` 分支里，
                // 而无标题窗口在第一支就被接走（is_main_window 判定），
                // 于是「用户拉黑了某 app，但它的窗口没有标题」时黑名单被整条绕过，
                // 照样被提升。这里补一次，对已判过的分支是幂等的。
                if (needs_raise && mouseWindowPresent && titleEquals(_mouseWindowApp, ignoreApps)) {
                    needs_raise = invertIgnoreApps;
                    if (verbose) {
                        NSLog(invertIgnoreApps ? @"Including app" : @"Excluding app (no-title path)");
                    }
                }
                CFRelease(_mouseWindowApp);
                if (needs_raise && is_offscreen_window(_mouseWindow, mousePoint)) {
                    needs_raise = false;
                    if (verbose) { NSLog(@"Excluding offscreen window"); }
                }
                CGWindowID focusedWindow_id = kCGNullWindowID;
#ifdef FOCUS_FIRST
                ProcessSerialNumber mouseWindow_psn;
                ProcessSerialNumber focusedWindow_psn;
                ProcessSerialNumber * _focusedWindow_psn = NULL;
#endif
                bool needs_raise_and_not_contained_within = false;
                if (needs_raise) {
                    pid_t frontmost_pid = frontmostApp.processIdentifier;
                    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
                    AXUIElementRef _focusedWindow = NULL;
                    AXUIElementCopyAttributeValue(
                        _frontmostApp,
                        kAXFocusedWindowAttribute,
                        (CFTypeRef *) &_focusedWindow);
                    if (_focusedWindow) {
                        if (verbose) { logWindowTitle(@"Focused window", _focusedWindow); }
                        _AXUIElementGetWindow(_focusedWindow, &focusedWindow_id);
                        needs_raise = mouseWindow_id != focusedWindow_id;
                        if (needs_raise && requireScreenChange &&
                            findScreenByWindow(_focusedWindow) == findScreen(mousePoint)) {
                            needs_raise = false;
                            if (verbose) { NSLog(@"Excluding same screen"); }
                        }
                        needs_raise_and_not_contained_within = needs_raise &&
                            !contained_within(_focusedWindow, _mouseWindow);
#ifdef FOCUS_FIRST
                        if (!focus_first) {
#endif
                            needs_raise = needs_raise_and_not_contained_within;
#ifdef FOCUS_FIRST
                        } else {
                            needs_raise = needs_raise && is_main_window(_frontmostApp, _focusedWindow,
                                is_pwa(frontmostApp.bundleIdentifier)) && ((mouseWindow_pid != frontmost_pid &&
                                !workaround_for_apps_raising_on_focus) || needs_raise_and_not_contained_within);
                            if (needs_raise) {
                                OSStatus error = GetProcessForPID(frontmost_pid, &focusedWindow_psn);
                                if (!error) { _focusedWindow_psn = &focusedWindow_psn; }
                            }
                        }
#endif
                        CFRelease(_focusedWindow);
                    } else {
                        if (verbose) { NSLog(@"No focused window"); }
                        // 原版：前台应用只要「有」AXMainWindow 就放弃提升。
                        // 但那只回答了"前台 app 有没有主窗口"，没回答
                        // "鼠标下这个窗口是不是已经是焦点"。关掉前台 app 的窗口后，
                        // 它的 AXMainWindow 仍可能读得到（或在别的 Space），
                        // 于是这里无条件 needs_raise=false，鼠标下真正该提升的窗口
                        // 永远等不到提升 —— 这就是「关窗后下层窗口永不激活」的主链路。
                        //
                        // 改成一致性判断：只有 AXMainWindow 就是鼠标下这个窗口时，
                        // 才算「系统状态已经对」，此时才放弃。
                        AXUIElementRef _activatedWindow = NULL;
                        AXUIElementCopyAttributeValue(_frontmostApp,
                            kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
                        if (_activatedWindow) {
                            CGWindowID activatedWindow_id = kCGNullWindowID;
                            _AXUIElementGetWindow(_activatedWindow, &activatedWindow_id);
                            needs_raise = mouseWindow_id != activatedWindow_id;
                            if (verbose && !needs_raise) {
                                NSLog(@"Activated window is the mouse window, nothing to do");
                            }
                            CFRelease(_activatedWindow);
                        }
                    }
                    CFRelease(_frontmostApp);
                }

                if (needs_raise) {
                    if (!delayTicks) {
                        // start the delay
                        delayTicks = delayCount;
                    }
                    if (raiseTimes || delayTicks == 1) {
                        delayTicks = 0; // disable delay

                        if (raiseTimes) { raiseTimes--; }
                        else { raiseTimes = 3; }
#ifdef FOCUS_FIRST
                        if (focus_first) {
                            OSStatus error = GetProcessForPID(mouseWindow_pid, &mouseWindow_psn);
                            if (!error) {
                                bool floating_window = false;
                                CFStringRef _element_sub_role = NULL;
                                AXUIElementCopyAttributeValue(
                                    _mouseWindow,
                                    kAXSubroleAttribute,
                                    (CFTypeRef *) &_element_sub_role);
                                if (_element_sub_role) {
                                    floating_window =
                                        CFEqual(_element_sub_role, kAXFloatingWindowSubrole) ||
                                        CFEqual(_element_sub_role, kAXSystemFloatingWindowSubrole) ||
                                        CFEqual(_element_sub_role, kAXUnknownSubrole);
                                    CFRelease(_element_sub_role);
                                }
                                if (!floating_window) {
                                    if (!workaround_for_apps_raising_on_focus || raiseDelayCount == 0) {
                                        // TODO: method below seems unable to focus floating windows
                                        window_manager_focus_window_without_raise(&mouseWindow_psn,
                                            mouseWindow_id, _focusedWindow_psn, focusedWindow_id);
                                    }
                                } else if (verbose) { NSLog(@"Unable to focus floating window"); }
                                if (_lastFocusedWindow) { CFRelease(_lastFocusedWindow); }
                                _lastFocusedWindow = _mouseWindow;
                                lastFocusedWindow_pid = mouseWindow_pid;
                                // 同步快照 id 与 pid，供延迟回调做身份比对与执行。
                                lastFocusedWindow_id = mouseWindowIdValid ? mouseWindow_id : kCGNullWindowID;
                                lastFocusedWindow_pid_for_raise = mouseWindow_pid;
                                if (raiseDelayCount && needs_raise_and_not_contained_within) {
                                    [workspaceWatcher windowFocused: _lastFocusedWindow];
                                }
                            }
                        } else {
#endif
                        raiseAndActivate(_mouseWindow, mouseWindow_pid);
#ifdef FOCUS_FIRST
                        }
#endif
                    }
                } else {
                    raiseTimes = 0;
                    delayTicks = 0;
                }
            }
#ifdef FOCUS_FIRST
            if (_mouseWindow != _lastFocusedWindow) {
#endif
                CFRelease(_mouseWindow);
#ifdef FOCUS_FIRST
            }
#endif
        }
    }
}

CGEventRef eventTapHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    CGEventFlags flags = CGEventGetFlags(event);
    bool commandPressed = (flags & TASK_SWITCHER_MODIFIER_KEY) == TASK_SWITCHER_MODIFIER_KEY;

    static bool commandTabPressed = false;
    if (!commandPressed && commandTabPressed) {
        commandTabPressed = false;
        activated_by_task_switcher = true;
        ignoreTimes = 3;
    }

    static bool commandGravePressed = false;
    if (!commandPressed && commandGravePressed) {
        commandGravePressed = false;
        activated_by_task_switcher = true;
        ignoreTimes = 3;
        [workspaceWatcher onAppActivated];
    }

    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            commandTabPressed = commandTabPressed || commandPressed;
        } else if (warpMouse && keycode == kVK_ANSI_Grave) {
            commandGravePressed = commandGravePressed || commandPressed;
        }
    } else if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (verbose) { NSLog(@"Got event tap disabled event, re-enabling..."); }
        CGEventTapEnable(eventTap, true);
    }

    return event;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        ConfigClass * config = [[ConfigClass alloc] init];
        [config readConfig: argc];
        [config validateParameters];

        delayCount         = [parameters[kDelay] intValue];
        warpX              = [parameters[kWarpX] floatValue];
        warpY              = [parameters[kWarpY] floatValue];
        cursorScale        = [parameters[kScale] floatValue];
        verbose            = [parameters[kVerbose] boolValue];
        altTaskSwitcher    = [parameters[kAltTaskSwitcher] boolValue];
        mouseDelta         = [parameters[kMouseDelta] floatValue];
        pollMillis         = [parameters[kPollMillis] intValue];
        requireMouseStop   = [parameters[kRequireMouseStop] boolValue];
        requireMultipleScreens = [parameters[kRequireMultipleScreens] boolValue];
        requireScreenChange = [parameters[kRequireScreenChange] boolValue];
        warpOnlyAcrossScreens = [parameters[kWarpOnlyAcrossScreens] boolValue];
        ignoreSpaceChanged = [parameters[kIgnoreSpaceChanged] boolValue];
        invertIgnoreApps   = [parameters[kInvertIgnoreApps] boolValue];
        invertDisableKey   = [parameters[kInvertDisableKey] boolValue];

        printf("\nv%s by sbmpost(c) 2026, usage:\n\nAutoRaise\n", AUTORAISE_VERSION);
        printf("  -pollMillis <20, 30, 40, 50, ...>\n");
        printf("  -delay <0=no-raise, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#ifdef FOCUS_FIRST
        printf("  -focusDelay <0=no-focus, 1=no-delay, 2=%dms, 3=%dms, ...>\n", pollMillis, pollMillis*2);
#endif
        printf("  -warpX <0.5> -warpY <0.5> -scale <2.0>\n");
        printf("  -warpOnlyAcrossScreens <true|false>\n");
        printf("  -altTaskSwitcher <true|false>\n");
        printf("  -requireMouseStop <true|false>\n");
        printf("  -requireMultipleScreens <true|false>\n");
        printf("  -requireScreenChange <true|false>\n");
        printf("  -ignoreSpaceChanged <true|false>\n");
        printf("  -invertDisableKey <true|false>\n");
        printf("  -invertIgnoreApps <true|false>\n");
        printf("  -ignoreApps \"<App1,App2,...>\"\n");
        printf("  -ignoreTitles \"<Regex1,Regex2,...>\"\n");
        printf("  -stayFocusedBundleIds \"<Id1,Id2,...>\"\n");
        printf("  -disableKey <control|option|disabled>\n");
        printf("  -mouseDelta <0.1>\n");
        printf("  -verbose <true|false>\n\n");

        printf("Started with:\n");
        printf("  * pollMillis: %dms\n", pollMillis);
        if (delayCount) {
            printf("  * delay: %dms\n", (delayCount-1)*pollMillis);
        } else {
            printf("  * delay: disabled\n");
        }
#ifdef FOCUS_FIRST
        if ([parameters[kFocusDelay] intValue]) {
            raiseDelayCount = delayCount;
            delayCount = [parameters[kFocusDelay] intValue];
            printf("  * focusDelay: %dms\n", (delayCount-1)*pollMillis);
        } else {
            raiseDelayCount = 1;
            printf("  * focusDelay: disabled\n");
        }
#endif

        if (warpMouse) {
            printf("  * warpX: %.1f, warpY: %.1f, scale: %.1f\n", warpX, warpY, cursorScale);
            printf("  * altTaskSwitcher: %s\n", altTaskSwitcher ? "true" : "false");
            printf("  * warpOnlyAcrossScreens: %s\n", warpOnlyAcrossScreens ? "true" : "false");
        }

        printf("  * requireMouseStop: %s\n", requireMouseStop ? "true" : "false");
        printf("  * requireMultipleScreens: %s\n", requireMultipleScreens ? "true" : "false");
        printf("  * requireScreenChange: %s\n", requireScreenChange ? "true" : "false");
        printf("  * ignoreSpaceChanged: %s\n", ignoreSpaceChanged ? "true" : "false");
        printf("  * invertDisableKey: %s\n", invertDisableKey ? "true" : "false");
        printf("  * invertIgnoreApps: %s\n", invertIgnoreApps ? "true" : "false");

        NSMutableArray * ignoreA;
        if (parameters[kIgnoreApps]) {
            ignoreA = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreApps] componentsSeparatedByString:@","]];
        } else { ignoreA = [[NSMutableArray alloc] init]; }

        for (id ignoreApp in ignoreA) {
            printf("  * ignoreApp: %s\n", [ignoreApp UTF8String]);
        }
        [ignoreA addObject: AssistiveControl];
        ignoreApps = [ignoreA copy];

        NSMutableArray * ignoreT;
        if (parameters[kIgnoreTitles]) {
            ignoreT = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreTitles] componentsSeparatedByString: @","]];
        } else { ignoreT = [[NSMutableArray alloc] init]; }

        for (id ignoreTitle in ignoreT) {
            printf("  * ignoreTitle: %s\n", [ignoreTitle UTF8String]);
        }
        ignoreTitles = [ignoreT copy];

        NSMutableArray * stayFocused;
        if (parameters[kStayFocusedBundleIds]) {
            stayFocused = [[NSMutableArray alloc] initWithArray:
                [parameters[kStayFocusedBundleIds] componentsSeparatedByString: @","]];
        } else { stayFocused = [[NSMutableArray alloc] init]; }

        for (id stayFocusedBundleId in stayFocused) {
            printf("  * stayFocusedBundleId: %s\n", [stayFocusedBundleId UTF8String]);
        }
        stayFocusedBundleIds = [stayFocused copy];

        if ([parameters[kDisableKey] isEqualToString: @"control"]) {
            printf("  * disableKey: control\n");
            disableKey = kCGEventFlagMaskControl;
        } else if ([parameters[kDisableKey] isEqualToString: @"option"]) {
            printf("  * disableKey: option\n");
            disableKey = kCGEventFlagMaskAlternate;
        } else { printf("  * disableKey: disabled\n"); }

        if (mouseDelta) { printf("  * mouseDelta: %.1f\n", mouseDelta); }

        printf("  * verbose: %s\n", verbose ? "true" : "false");
#if defined OLD_ACTIVATION_METHOD or defined FOCUS_FIRST or defined ALTERNATIVE_TASK_SWITCHER
        printf("\nCompiled with:\n");
#ifdef OLD_ACTIVATION_METHOD
        printf("  * OLD_ACTIVATION_METHOD\n");
#endif
#ifdef FOCUS_FIRST
        printf("  * EXPERIMENTAL_FOCUS_FIRST\n");
#endif
#ifdef ALTERNATIVE_TASK_SWITCHER
        printf("  * ALTERNATIVE_TASK_SWITCHER\n");
#endif
#endif
        printf("\n");

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
        if (verbose) { NSLog(@"AXIsProcessTrusted: %s", trusted ? "YES" : "NO"); }

        CGSGetCursorScale(CGSMainConnectionID(), &oldScale);
        if (verbose) { NSLog(@"System cursor scale: %f", oldScale); }

        CFRunLoopSourceRef runLoopSource = NULL;
        eventTap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            CGEventMaskBit(kCGEventKeyDown) |
            CGEventMaskBit(kCGEventFlagsChanged),
            eventTapHandler,
            NULL
        );
        if (eventTap) {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }
        if (verbose) { NSLog(@"Got run loop source: %s", runLoopSource ? "YES" : "NO"); }

        workspaceWatcher = [[MDWorkspaceWatcher alloc] init];
#ifdef FOCUS_FIRST
        if (altTaskSwitcher || raiseDelayCount || delayCount) {
#else
        if (altTaskSwitcher || delayCount) {
#endif
            [workspaceWatcher onTick: [NSNumber numberWithFloat: pollMillis/1000.0]];
        }

        findDockApplication();
        findDesktopOrigin();
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
