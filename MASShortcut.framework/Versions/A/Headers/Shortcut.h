//
//  Shortcut.h
//  MASShortcut (local reconstruction for offline build)
//
//  Minimal but complete interface matching the symbols present in the
//  MASShortcut.framework binary bundled with AutoRaise.app.
//  Only the APIs used by AutoRaise's launcher are declared; every selector
//  below was verified against the shipped binary via otool -oV.
//

#ifndef MASShortcut_Shortcut_h
#define MASShortcut_Shortcut_h

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface MASShortcut : NSObject <NSCopying, NSCoding>

- (instancetype)initWithKeyCode:(NSInteger)keyCode modifierFlags:(NSUInteger)modifierFlags;
+ (instancetype)shortcutWithKeyCode:(NSInteger)keyCode modifierFlags:(NSUInteger)modifierFlags;

@property (nonatomic, readonly) NSInteger keyCode;
@property (nonatomic, readonly) NSUInteger modifierFlags;
@property (nonatomic, readonly, copy) NSString *keyEquivalent;

@end


@interface MASShortcutView : NSView

@property (nonatomic, strong, nullable) MASShortcut *shortcutValue;
@property (nonatomic, copy, nullable) NSString *associatedUserDefaultsKey;
@property (nonatomic, copy, nullable) NSString *shortcutPlaceholder;
@property (nonatomic, strong, nullable) id shortcutValidator;
@property (nonatomic, assign) NSInteger style;
@property (nonatomic, assign, getter=isRecording) BOOL recording;
@property (nonatomic, copy, nullable) void (^shortcutValueChange)(MASShortcutView *sender);

- (void)setAssociatedUserDefaultsKey:(NSString *)key withTransformerName:(NSString *)name;

@end


@interface MASShortcutMonitor : NSObject

+ (instancetype)sharedMonitor;

- (BOOL)registerShortcut:(nullable MASShortcut *)shortcut withAction:(void (^)(void))action;
- (void)unregisterShortcut:(MASShortcut *)shortcut;
- (void)unregisterAllShortcuts;
- (BOOL)isShortcutRegistered:(MASShortcut *)shortcut;

@end

NS_ASSUME_NONNULL_END

#endif /* MASShortcut_Shortcut_h */
