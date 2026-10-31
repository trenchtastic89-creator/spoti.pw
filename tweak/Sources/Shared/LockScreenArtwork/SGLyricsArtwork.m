// The line being sung, drawn over the cover and handed to the lock screen as its animated artwork.
//
// The animated artwork key takes a video file and nothing else, so each line is drawn once and
// written as an MP4 holding that frame for the length of the line. When the line changes a new clip
// is written under a new artwork id and the now playing dictionary is sent again, which is what
// makes the system ask for it.
//
// The frame is Apple Music's: the artwork softened to a wash of its own colour, dimmed hard, and the
// line centred in the upper half with the ones after it under it. Nothing of the photo survives but
// the colour, which is what keeps white text readable over any cover.
//
// The star: Chroma's star on the lock screen is iOS's like button, so the mod listens on the like
// command and swaps between the line and the track's own artwork instead of liking the song.
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import "Core/SGCore.h"
#import "LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

NSString *const SGLyricsArtworkKey = @"spotifyglass.lockscreen.lyricsartwork";
NSString *const SGLyricsStarKey = @"spotifyglass.lockscreen.modestar";

static const NSTimeInterval kTick = 0.3;
// A line is on screen for at least this long, so a clip is never empty.
static const NSTimeInterval kShortest = 1.2;
// Past this a clip is cut short; the system loops it and a still has nowhere to go.
static const NSTimeInterval kLongest = 10.0;
// How many lines after the one being sung are drawn under it.
static const NSUInteger kFollowing = 2;

static dispatch_queue_t sg_queue;
static NSString *sg_want;   // track|line the last clip was asked for
static NSUInteger sg_generation;
static BOOL sg_ownArtwork;  // the star has been tapped: show the track's artwork, not the line

static NSURL *clipURL(NSString *identifier) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *directory = [NSURL fileURLWithPath:[caches stringByAppendingPathComponent:@"spoti.pw/LyricsArtwork"]];
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    return [directory URLByAppendingPathComponent:[identifier stringByAppendingPathExtension:@"mp4"]];
}

// The cover Spotify put in the now playing dictionary, at the size asked for.
static UIImage *coverImage(CGSize size) {
    id artwork = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo[MPMediaItemPropertyArtwork];
    if ([artwork isKindOfClass:UIImage.class]) return artwork;
    if (![artwork respondsToSelector:@selector(imageWithSize:)]) return nil;
    UIImage *image = [artwork imageWithSize:size];
    if (!image && [artwork respondsToSelector:@selector(bounds)]) image = [artwork imageWithSize:[artwork bounds].size];
    return image;
}

// The cover at a twenty-sixth of the size it is drawn at. Scaled back up, it carries the colours and
// none of the detail, which is the whole look: a still of the album rather than a photograph.
static UIImage *washImage(UIImage *cover, CGSize size) {
    if (!cover || cover.size.width < 1 || cover.size.height < 1) return nil;
    CGSize small = CGSizeMake(MAX(16, round(size.width / 26)), MAX(16, round(size.height / 26)));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:small format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(small.width / cover.size.width, small.height / cover.size.height);
        CGSize filled = CGSizeMake(cover.size.width * scale, cover.size.height * scale);
        [cover drawInRect:CGRectMake((small.width - filled.width) / 2, (small.height - filled.height) / 2,
                                     filled.width, filled.height)];
    }];
}

static CGImageRef renderFrame(NSString *line, NSArray<NSString *> *following, CGSize size) {
    UIImage *cover = coverImage(size);
    UIImage *wash = washImage(cover, size);

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;

    UIImage *drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        [[UIColor blackColor] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        if (wash) [wash drawInRect:CGRectMake(0, 0, size.width, size.height)];

        // Dark enough that white reads at any screen brightness, and darker toward the bottom where
        // the controls sit, so the two never fight.
        [[UIColor colorWithWhite:0 alpha:0.50] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *stops = @[(id)[UIColor colorWithWhite:0 alpha:0.15].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.70].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)stops, NULL);
        if (gradient) {
            CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
            CGGradientRelease(gradient);
        }
        CGColorSpaceRelease(space);

        CGFloat side = size.width * 0.10;
        CGFloat width = size.width - side * 2;
        UIFont *lead = [UIFont systemFontOfSize:size.width * 0.058 weight:UIFontWeightBold];
        UIFont *under = [UIFont systemFontOfSize:size.width * 0.042 weight:UIFontWeightSemibold];

        NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithObject:line ?: @""];
        NSMutableArray<UIFont *> *fonts = [NSMutableArray arrayWithObject:lead];
        NSMutableArray<UIColor *> *colours = [NSMutableArray arrayWithObject:UIColor.whiteColor];
        NSMutableArray<NSNumber *> *gaps = [NSMutableArray arrayWithObject:@(size.height * 0.022)];
        for (NSString *next in following) {
            [texts addObject:next];
            [fonts addObject:under];
            [colours addObject:[UIColor colorWithWhite:1 alpha:0.48]];
            [gaps addObject:@(size.height * 0.010)];
        }

        // Measured first, so the block hangs from its own centre rather than off the top.
        CGFloat total = 0;
        NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
        for (NSUInteger at = 0; at < texts.count; at++) {
            CGRect box = [texts[at] boundingRectWithSize:CGSizeMake(width, size.height)
                                                 options:NSStringDrawingUsesLineFragmentOrigin
                                              attributes:@{NSFontAttributeName: fonts[at]}
                                                 context:nil];
            CGFloat height = ceil(box.size.height);
            [heights addObject:@(height)];
            total += height + gaps[at].doubleValue;
        }

        CGFloat y = size.height * 0.38 - total / 2;
        for (NSUInteger at = 0; at < texts.count; at++) {
            NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
            paragraph.alignment = NSTextAlignmentCenter;
            paragraph.lineBreakMode = NSLineBreakByWordWrapping;
            CGFloat height = heights[at].doubleValue;
            [texts[at] drawInRect:CGRectMake(side, y, width, height + 2) withAttributes:@{
                NSFontAttributeName: fonts[at],
                NSForegroundColorAttributeName: colours[at],
                NSParagraphStyleAttributeName: paragraph,
            }];
            y += height + gaps[at].doubleValue;
        }
    }];
    return CGImageRetain(drawn.CGImage);
}

// Two frames of the same picture: the first holds for `seconds`, the second closes the file. A
// single-frame MP4 is legal but some players drop it, and a clip with nowhere to end never loops.
static BOOL writeClip(CGImageRef image, NSTimeInterval seconds, NSURL *url) {
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) {
        SGLog(@"lyrics artwork: writer: %@", error.localizedDescription);
        return NO;
    }
    size_t w = CGImageGetWidth(image) & ~1UL;
    size_t h = CGImageGetHeight(image) & ~1UL;
    if (w < 2 || h < 2) return NO;
    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(w),
        AVVideoHeightKey: @(h),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(w * h),
            AVVideoMaxKeyFrameIntervalKey: @1,
        },
    };
    AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:settings];
    input.expectsMediaDataInRealTime = NO;
    NSDictionary *attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(w),
        (id)kCVPixelBufferHeightKey: @(h),
    };
    AVAssetWriterInputPixelBufferAdaptor *adaptor =
        [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                                          sourcePixelBufferAttributes:attributes];
    if (![writer canAddInput:input]) return NO;
    [writer addInput:input];
    if (![writer startWriting]) {
        SGLog(@"lyrics artwork: start: %@", writer.error.localizedDescription);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    CVPixelBufferRef buffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer);
    if (!buffer) {
        [writer cancelWriting];
        return NO;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), w, h, 8,
        CVPixelBufferGetBytesPerRow(buffer), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    if (context) {
        CGContextDrawImage(context, CGRectMake(0, 0, w, h), image);
        CGContextRelease(context);
    }
    CGColorSpaceRelease(space);
    CVPixelBufferUnlockBaseAddress(buffer, 0);

    // The second frame lands just short of the end, so the first one carries the whole line and the
    // file still ends on a sample with a duration of its own.
    CMTime end = CMTimeMakeWithSeconds(seconds, 600);
    CMTime tail = CMTimeMakeWithSeconds(MAX(seconds - 0.05, 0.05), 600);
    BOOL first = [adaptor appendPixelBuffer:buffer withPresentationTime:kCMTimeZero];
    BOOL last = [adaptor appendPixelBuffer:buffer withPresentationTime:tail];
    CFRelease(buffer);
    [input markAsFinished];
    [writer endSessionAtSourceTime:end];

    __block BOOL finished = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        finished = writer.status == AVAssetWriterStatusCompleted;
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!first || !last || !finished) {
        SGLog(@"lyrics artwork: finish %ld %@", (long)writer.status, writer.error.localizedDescription);
        return NO;
    }
    return YES;
}

static BOOL switchedOn(void) {
    return SGFlag(SGKeyLockScreenArtwork, YES) && SGFlag(SGLyricsArtworkKey, YES);
}

static void tick(void);

// The star was tapped: the other one of the two now owns the lock screen's artwork.
static void swapMode(void) {
    sg_ownArtwork = !sg_ownArtwork;
    sg_want = nil;
    sg_generation++;
    SGArtworkReload();
    if (!sg_ownArtwork) tick();
    SGLog(@"lyrics artwork: %@", sg_ownArtwork ? @"the track's own artwork" : @"back to the line");
}

static void render(NSArray<SGKaraokeLine *> *lines, NSInteger index, NSString *track) {
    NSString *line = SGKaraokeLineText(lines[index]);
    NSMutableArray<NSString *> *following = [NSMutableArray array];
    for (NSInteger at = index + 1; at < (NSInteger)lines.count && following.count < kFollowing; at++) {
        NSString *text = SGKaraokeLineText(lines[at]);
        if (text.length) [following addObject:text];
    }

    NSInteger span = SGKaraokeSungEnd(lines[index]) - lines[index].start;
    if (span <= 0) span = 4000;
    NSTimeInterval seconds = MIN(MAX(span / 1000.0, kShortest), kLongest);

    CGFloat aspect = 0;
    if (!SGAnimatedArtworkKey(&aspect) || aspect <= 0) return;
    CGSize size = CGSizeMake(round(1920 * aspect), 1920);

    NSUInteger generation = ++sg_generation;
    NSString *identifier = [NSString stringWithFormat:@"lyr-%@-%ld-%lu", track, (long)index, (unsigned long)generation];
    NSURL *file = clipURL(identifier);

    dispatch_async(sg_queue, ^{
        @autoreleasepool {
            CGImageRef image = renderFrame(line, following, size);
            if (!image) return;
            BOOL wrote = writeClip(image, seconds, file);
            UIImage *still = wrote ? [UIImage imageWithCGImage:image] : nil;
            CGImageRelease(image);
            if (!wrote) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != sg_generation || sg_ownArtwork) return;
                if (![SGKaraokePlayingTrack() isEqualToString:track]) return;
                SGLog(@"lyrics artwork: line %ld of %@ (%.1fs)", (long)index, track, seconds);
                SGArtworkApplyLocal(identifier, file, still);
            });
        }
    });
}

static void tick(void) {
    if (sg_ownArtwork) return;
    if (!switchedOn()) return;
    NSString *track = SGKaraokePlayingTrack();
    if (!track.length) return;
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(track);
    if (!lines) {
        SGKaraokeRequestLyrics(track);
        return;
    }
    if (SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) return;
    NSInteger position = SGKaraokePositionMs();
    if (position < 0) return;
    NSInteger index = SGKaraokeLeadLine(lines, position);
    if (index < 0 || index >= (NSInteger)lines.count) return;
    NSString *text = SGKaraokeLineText(lines[index]);
    if (!text.length) return;
    NSString *want = [NSString stringWithFormat:@"%@|%ld", track, (long)index];
    if ([want isEqualToString:sg_want]) return;
    sg_want = want;
    render(lines, index, track);
}

__attribute__((constructor)) static void SGLyricsArtworkStart(void) {
    if (!SGAnimatedArtworkAvailable()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    // The rows are read with these defaults, so an untouched install shows what the mod does.
    if ([defaults objectForKey:SGLyricsArtworkKey] == nil) [defaults setBool:YES forKey:SGLyricsArtworkKey];
    if ([defaults objectForKey:SGLyricsStarKey] == nil) [defaults setBool:NO forKey:SGLyricsStarKey];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_queue = dispatch_queue_create("com.spotipw.lyricsartwork", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_get_main_queue(), ^{
            // The star on the lock screen is the like command; first in, so a tap lands here before
            // Spotify's own handler and never likes the track.
            MPRemoteCommand *like = MPRemoteCommandCenter.sharedCommandCenter.likeCommand;
            if (like) {
                [like addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
                    if (!SGFlag(SGLyricsStarKey, NO)) return MPRemoteCommandHandlerStatusCommandFailed;
                    swapMode();
                    return MPRemoteCommandHandlerStatusSuccess;
                }];
            }
            NSTimer *timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *t) { tick(); }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
            SGLog(@"lyrics artwork: on");
        });
    });
}
