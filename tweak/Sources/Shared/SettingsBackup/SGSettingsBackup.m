#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import "Core/SGCore.h"
#import "SGSettingsBackup.h"

// The keychain item. Its access group is the app's signing identity, so a re-signed build of the same
// bundle id reads the same item, while the container it was installed into is irrelevant.
static NSString *const kBackupService = @"com.spotipw.settings";
static NSString *const kBackupAccount = @"backup";
// Outside the "spotifyglass." sweep Reset all settings runs, so a reset is backed up like anything else
// rather than being undone by the next install.
static NSString *const kRestoredKey = @"spotipw.backup.restored";

static const NSTimeInterval kSaveDelay = 1.5;
static NSUInteger sg_saveGeneration;

// Everything the mod owns, and nothing of Spotify's: the two prefixes the settings pages write under.
static BOOL backed_up_key(NSString *key) {
    if (![key isKindOfClass:NSString.class]) return NO;
    if ([key hasPrefix:@"spotipw.backup."]) return NO;
    return [key hasPrefix:@"spotifyglass."] || [key hasPrefix:@"spotipw."];
}

// JSON has no dates and no blobs, and the settings only ever hold strings, numbers and the odd array.
// Anything else is dropped rather than thrown over: a single unencodable default would otherwise take
// the whole save, and the app with it.
static id json_safe(id value) {
    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) return value;
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *out = [NSMutableArray array];
        for (id item in value) {
            id safe = json_safe(item);
            if (safe) [out addObject:safe];
        }
        return out;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [value enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL *stop) {
            if (![key isKindOfClass:NSString.class]) return;
            id safe = json_safe(item);
            if (safe) out[key] = safe;
        }];
        return out;
    }
    return nil;
}

static NSDictionary *snapshot(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    if (!bundle.length) return nil;
    NSDictionary *domain = [store persistentDomainForName:bundle];
    if (![domain isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithCapacity:domain.count];
    for (NSString *key in domain) {
        if (!backed_up_key(key)) continue;
        id safe = json_safe(domain[key]);
        if (safe) values[key] = safe;
    }
    return values;
}

static NSData *encoded(NSDictionary *values) {
    if (![NSJSONSerialization isValidJSONObject:values]) return nil;
    return [NSJSONSerialization dataWithJSONObject:values options:NSJSONWritingSortedKeys error:NULL];
}

static NSDictionary *decoded(NSData *data) {
    if (!data.length) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSDictionary *item_query(void) {
    return @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kBackupService,
        (__bridge id)kSecAttrAccount: kBackupAccount,
    };
}

static NSData *read_backup(OSStatus *outStatus) {
    NSMutableDictionary *query = [item_query() mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (outStatus) *outStatus = status;
    if (status != errSecSuccess || !result) return nil;
    return CFBridgingRelease(result);
}

static BOOL write_backup(NSData *data) {
    SecItemDelete((__bridge CFDictionaryRef)item_query());
    NSMutableDictionary *item = [item_query() mutableCopy];
    item[(__bridge id)kSecValueData] = data;
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) {
        // A signing identity the keychain will not take for this item is the one case where the
        // backup silently stops working, so it is worth finding in the log rather than guessing at.
        SGLog(@"settings backup: keychain refused the write (%d)", (int)status);
        return NO;
    }
    return YES;
}

static NSUInteger restore_into(NSUserDefaults *store, NSDictionary *saved) {
    NSUInteger applied = 0;
    for (NSString *key in saved) {
        id value = saved[key];
        if (!backed_up_key(key) || !value || [value isKindOfClass:NSNull.class]) continue;
        [store setObject:value forKey:key];
        applied++;
    }
    return applied;
}

// The first launch after an install: the defaults are empty, the keychain is not.
static BOOL restore_if_needed(void) {
    @try {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        if ([store objectForKey:kRestoredKey] != nil) return NO;
        OSStatus status = errSecSuccess;
        NSData *blob = read_backup(&status);
        // Only "there is nothing there" is an answer. Anything else means the keychain could not be
        // asked yet, and the marker is left unset so the next launch does get to read it.
        if (!blob && status != errSecItemNotFound && status != errSecSuccess) {
            SGLog(@"settings backup: keychain not readable at launch (%d), trying again next time", (int)status);
            return NO;
        }
        NSDictionary *saved = decoded(blob);
        NSUInteger applied = saved ? restore_into(store, saved) : 0;
        [store setBool:YES forKey:kRestoredKey];
        [store synchronize];
        SGLog(@"settings backup: %@", saved ? [NSString stringWithFormat:@"put back %lu settings", (unsigned long)applied]
                                            : @"nothing saved on this phone yet");
        return applied > 0;
    } @catch (NSException *exception) {
        // Nothing here is worth a launch: if the defaults or the keychain refuse, the mod simply
        // starts from the build's own defaults like it would without any of this.
        SGLog(@"settings backup: restore threw %@", exception.reason);
        return NO;
    }
}

NSString *SGSettingsBackupSummary(void) {
    @try {
        NSDictionary *saved = decoded(read_backup(NULL));
        if (!saved) return @"Nothing saved yet";
        NSUInteger count = 0;
        for (NSString *key in saved) if (backed_up_key(key)) count++;
        NSNumber *at = saved[@"_savedAt"];
        if (![at isKindOfClass:NSNumber.class] || at.doubleValue <= 0) {
            return [NSString stringWithFormat:@"%lu settings", (unsigned long)count];
        }
        static NSDateFormatter *stamp;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            stamp = [NSDateFormatter new];
            stamp.dateFormat = @"d MMM, HH:mm";
        });
        return [NSString stringWithFormat:@"%lu settings · %@", (unsigned long)count,
                [stamp stringFromDate:[NSDate dateWithTimeIntervalSince1970:at.doubleValue]]];
    } @catch (NSException *exception) {
        return @"Unavailable";
    }
}

BOOL SGSettingsBackupSave(void) {
    @try {
        NSDictionary *values = snapshot();
        if (!values) return NO;
        NSData *plain = encoded(values);
        if (!plain) return NO;
        // The timestamp moves on every save, so the comparison is made against the settings alone: a
        // notification storm from Spotify's own writes then costs one dictionary compare, not a
        // keychain round trip.
        static NSData *last;
        if (last && [last isEqualToData:plain]) return YES;

        NSMutableDictionary *stamped = [values mutableCopy];
        stamped[@"_savedAt"] = @(NSDate.date.timeIntervalSince1970);
        NSData *data = encoded(stamped);
        if (!data || !write_backup(data)) return NO;
        last = plain;
        return YES;
    } @catch (NSException *exception) {
        SGLog(@"settings backup: save threw %@", exception.reason);
        return NO;
    }
}

void SGSettingsBackupRestore(void) {
    NSDictionary *saved = decoded(read_backup(NULL));
    if (!saved) return;
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    NSUInteger applied = restore_into(store, saved);
    [store setBool:YES forKey:kRestoredKey];
    [store synchronize];
    SGLog(@"settings backup: put back %lu settings by hand", (unsigned long)applied);
    SGRestartSpotify();
}

void SGSettingsBackupForget(void) {
    SecItemDelete((__bridge CFDictionaryRef)item_query());
    SGLog(@"settings backup: forgotten");
}

#pragma mark - when it runs

// A constructor, not +load: +load runs while the images are still being loaded, and anything that
// waits on another process there — the keychain, a preferences daemon — can deadlock against a main
// thread that has not started its run loop yet. Nothing in here is allowed to block.
__attribute__((constructor)) static void SGSettingsBackupStart(void) {
    @autoreleasepool {
        // The restore waits for the app to finish putting itself together. Two seconds in, the run
        // loop is up and the settings pages are still a tap away.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ restore_if_needed(); });

        // Whatever is saved is saved again the moment it changes: the settings pages all write through
        // NSUserDefaults, so one notification covers every switch, list and flag override there is.
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                        object:nil
                                                         queue:nil
                                                    usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSUInteger generation = ++sg_saveGeneration;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSaveDelay * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (generation != sg_saveGeneration) return;
                    SGSettingsBackupSave();
                });
            });
        }];
        // The app can be killed while suspended without another run loop turn, so the last few seconds
        // of switches are flushed on the way out.
        NSString *background = UIApplicationDidEnterBackgroundNotification;
        if (background.length) {
            [NSNotificationCenter.defaultCenter addObserverForName:background
                                                            object:nil
                                                             queue:nil
                                                        usingBlock:^(NSNotification *note) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    sg_saveGeneration++;
                    SGSettingsBackupSave();
                });
            }];
        }
    }
}
