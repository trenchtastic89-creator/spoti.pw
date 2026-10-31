// Keeps the mod's settings across a reinstall. Everything a switch writes lives in NSUserDefaults, and
// the app's defaults are gone the moment SideStore replaces the app, so the same dictionary is kept in
// the keychain as well: keychain items belong to the app's signing identity rather than to its
// container, and outlive the container being emptied. On the first launch after an install the backup
// is written back before any feature reads a switch.
#import <Foundation/Foundation.h>

// What was restored, if anything, for the log: "12 settings from 31 Oct 17:20".
NSString *SGSettingsBackupSummary(void);

// The same dictionary, put in the keychain now. Called on every change, debounced by the caller.
BOOL SGSettingsBackupSave(void);

// The backup written back over the defaults, whether or not this launch has already restored once,
// and Spotify asked to restart so the hooks that read at launch see the values.
void SGSettingsBackupRestore(void);

// The backup gone: the next install starts from the build's own defaults.
void SGSettingsBackupForget(void);
