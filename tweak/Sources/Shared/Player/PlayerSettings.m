// The player's settings that do not depend on the look: the lock screen widget's flags, and the two
// rows the full-screen lyric artwork answers to.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "PlayerSettings.h"
#import "Shared/LockScreenArtwork/LockScreenArtwork.h"

UIViewController *SGLockScreenWidgetPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Lock screen widget" intro:SGRestartNote sections:@[
        SGSection(@"Controls", @[
            SGFlagRow(@"Like and dislike buttons", @"ios-feature-lockscreen.like_dislike_enabled"),
            SGFlagRow(@"Skip button on podcasts", @"ios-feature-lockscreen.skip_button_on_podcasts"),
            SGFlagRow(@"Chapter skip controls", @"ios-feature-lockscreen.enable_chapter_skip_controls"),
            SGFlagRow(@"Burst skip", @"ios-feature-lockscreen.burst_skip_enabled"),
        ]),
        SGSection(@"Artwork", [SGAnimatedArtworkRows() arrayByAddingObject:
            SGFlagRow(@"Companion content", @"ios-feature-lockscreen.companion_content_enabled")]),
        // The line drawn over the artwork is made by the mod rather than fetched, so it has switches
        // of its own; Shared/LockScreenArtwork/SGLyricsArtwork reads both.
        SGSection(@"Full-screen lyrics", @[
            SGSwitchRow(@"Draw the line over the artwork", @"A clip is made for every line, for as long as the lock screen is awake", SGLyricsArtworkKey),
            SGSwitchRow(@"Star button switches", @"Tap the like star on the lock screen to go between the line and the artwork", SGLyricsStarKey),
        ]),
    ] footer:nil];
}
