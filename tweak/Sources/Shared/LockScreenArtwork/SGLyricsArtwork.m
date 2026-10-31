// The line being sung, drawn over the cover and handed to the lock screen as its animated artwork.
//
// The animated artwork key takes a video file and nothing else, so a line is drawn once and written
// as an MP4 holding that frame for the length of the line. The system reloads the clip whenever the
// now playing dictionary changes, and that reload is a visible blink, so the clip for the next line
// is written while the current one is still up and applied the moment the line changes.
//
// The frame is Apple Music's: the artwork softened to a wash of its own colour, dimmed, vignetted,
// and the line centred in the upper half with the ones after it under it.
//
// The star: Chroma's star on the lock screen is iOS's like button, so the mod listens on the like
// command and swaps between the line and the track's own artwork instead of liking the song.
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import "Core/SGCore.h"
#import "LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

NSString *const SGLyricsArtworkKey = @"spotifyglass.lockscreen.lyricsartwork";
NSString *const SGLyricsStarKey = @"spotifyglass.lockscreen.modestar";

// Files are named with this, so a clip written by an older renderer is never shown again.
static NSString *const kClipTag = @"lyr3";

static const NSTimeInterval kTick = 0.3;
// A line is on screen for at least this long, so a clip is never empty.
static const NSTimeInterval kShortest = 1.2;
// Past this a clip is cut short; the system loops it and a still has nowhere to go.
static const NSTimeInterval kLongest = 10.0;
// How many lines after the one being sung are drawn under it.
static const NSUInteger kFollowing = 2;

static dispatch_queue_t sg_queue;
static NSString *sg_want;    // track|line the lock screen is showing
static NSString *sg_track;   // the track the cache belongs to
static NSUInteger sg_generation;
static BOOL sg_ownArtwork;   // the star has been tapped: show the track's artwork, not the line
static NSMutableDictionary<NSString *, NSDictionary *> *sg_cache;

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

// The cover filled to the frame, blurred hard and warmed up. A real gaussian rather than a small copy
// scaled back up: the copy left square blocks where the sleeve had detail, and the lock screen is
// looked at closely enough to see them.
static UIImage *washImage(UIImage *cover, CGSize size) {
    if (!cover || cover.size.width < 1 || cover.size.height < 1) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *filled = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat scale = MAX(size.width / cover.size.width, size.height / cover.size.height);
        CGSize drawn = CGSizeMake(cover.size.width * scale, cover.size.height * scale);
        [cover drawInRect:CGRectMake((size.width - drawn.width) / 2, (size.height - drawn.height) / 2,
                                     drawn.width, drawn.height)];
    }];

    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CIImage *input = [CIImage imageWithCGImage:filled.CGImage];

    CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];
    [clamp setValue:input forKey:kCIInputImageKey];
    [clamp setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:kCIInputTransformKey];

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:clamp.outputImage forKey:kCIInputImageKey];
    [blur setValue:@(size.width * 0.055) forKey:kCIInputRadiusKey];

    CIFilter *controls = [CIFilter filterWithName:@"CIColorControls"];
    [controls setValue:blur.outputImage forKey:kCIInputImageKey];
    [controls setValue:@1.55 forKey:kCIInputSaturationKey];
    [controls setValue:@0.02 forKey:kCIInputBrightnessKey];

    CIImage *out = controls.outputImage;
    if (!out) return filled;
    CGImageRef image = [context createCGImage:out fromRect:input.extent];
    if (!image) return filled;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result ?: filled;
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

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        // The artwork's colour at the top, gone by the bottom, so the controls sit on black.
        [[UIColor colorWithWhite:0 alpha:0.38] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        NSArray *stops = @[(id)[UIColor colorWithWhite:0 alpha:0.10].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.78].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)stops, NULL);
        if (gradient) {
            CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
            CGGradientRelease(gradient);
        }
        // Edges fall away, which is what stops the wash reading as a photograph again.
        NSArray *edges = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.62].CGColor];
        CGGradientRef vignette = CGGradientCreateWithColors(space, (__bridge CFArrayRef)edges, NULL);
        if (vignette) {
            CGPoint centre = CGPointMake(size.width / 2, size.height * 0.42);
            CGContextDrawRadialGradient(c, vignette, centre, size.width * 0.12, centre, size.height * 0.72, 0);
            CGGradientRelease(vignette);
        }
        CGColorSpaceRelease(space);

        // The redesign's own lyrics view sets every line at one size (SGRKaraokeView: 30pt on a 390pt
        // page, 24pt margins, 24pt between lines) and lights the sung line only: the rest sit at 30%
        // white. Copying those numbers is what makes this read as the same feature rather than a
        // caption, so none of them are invented here.
        CGFloat side = size.width * (24.0 / 390.0);
        CGFloat width = size.width - side * 2;
        UIFont *font = [UIFont systemFontOfSize:size.width * (30.0 / 390.0) weight:UIFontWeightBold];

        NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithObject:line ?: @""];
        NSMutableArray<UIFont *> *fonts = [NSMutableArray arrayWithObject:font];
        NSMutableArray<UIColor *> *colours = [NSMutableArray arrayWithObject:UIColor.whiteColor];
        NSMutableArray<NSNumber *> *gaps = [NSMutableArray arrayWithObject:@(size.height * (24.0 / 844.0))];
        for (NSString *next in following) {
            [texts addObject:next];
            [fonts addObject:font];
            [colours addObject:[UIColor colorWithWhite:1 alpha:0.3]];
            [gaps addObject:@(size.height * (24.0 / 844.0))];
        }

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

// The clip for one line, drawn and encoded, or nil. Cached by track and line, in memory and on disk:
// the same line in the same track always looks the same, so it is only ever made once.
static NSDictionary *makeClip(NSArray<SGKaraokeLine *> *lines, NSInteger index, NSString *track, CGSize size) {
    if (index < 0 || index >= (NSInteger)lines.count) return nil;
    NSString *line = SGKaraokeLineText(lines[index]);
    if (!line.length) return nil;

    NSInteger span = SGKaraokeSungEnd(lines[index]) - lines[index].start;
    if (span <= 0) span = 4000;
    NSTimeInterval seconds = MIN(MAX(span / 1000.0, kShortest), kLongest);

    NSMutableArray<NSString *> *following = [NSMutableArray array];
    for (NSInteger at = index + 1; at < (NSInteger)lines.count && following.count < kFollowing; at++) {
        NSString *text = SGKaraokeLineText(lines[at]);
        if (text.length) [following addObject:text];
    }

    NSURL *file = clipURL([NSString stringWithFormat:@"%@-%@-%ld", kClipTag, track, (long)index]);
    BOOL have = [NSFileManager.defaultManager fileExistsAtPath:file.path];
    CGImageRef image = renderFrame(line, following, size);
    if (!image) return nil;
    UIImage *still = [UIImage imageWithCGImage:image];
    if (!have) have = writeClip(image, seconds, file);
    CGImageRelease(image);
    if (!have) return nil;
    return @{@"file": file, @"still": still};
}

// What the lock screen shows now: a rendered clip, under a fresh id so the system takes it.
static void applyClip(NSDictionary *entry, NSString *track) {
    if (!entry || sg_ownArtwork) return;
    if (![SGKaraokePlayingTrack() isEqualToString:track]) return;
    NSString *identifier = [NSString stringWithFormat:@"lyr-%@-%lu", track, (unsigned long)++sg_generation];
    SGArtworkApplyLocal(identifier, entry[@"file"], entry[@"still"]);
}

static void build(NSArray<SGKaraokeLine *> *lines, NSInteger index, NSString *track, CGSize size, BOOL show) {
    NSString *key = [NSString stringWithFormat:@"%@|%ld", track, (long)index];
    dispatch_async(sg_queue, ^{
        @autoreleasepool {
            NSDictionary *entry = makeClip(lines, index, track, size);
            if (!entry) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (![track isEqualToString:sg_track ?: @""]) return;
                sg_cache[key] = entry;
                if (show && [key isEqualToString:sg_want]) {
                    SGLog(@"lyrics artwork: line %ld of %@", (long)index, track);
                    applyClip(entry, track);
                }
            });
        }
    });
}

static void tick(void);

static void swapMode(void) {
    sg_ownArtwork = !sg_ownArtwork;
    sg_want = nil;
    sg_generation++;
    SGArtworkReload();
    if (!sg_ownArtwork) tick();
    SGLog(@"lyrics artwork: %@", sg_ownArtwork ? @"the track's own artwork" : @"back to the line");
}

static void tick(void) {
    if (sg_ownArtwork) return;
    if (!switchedOn()) return;
    NSString *track = SGKaraokePlayingTrack();
    if (!track.length) return;
    if (![track isEqualToString:sg_track ?: @""]) {
        sg_track = [track copy];
        sg_cache = [NSMutableDictionary dictionary];
        sg_want = nil;
    }
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

    CGFloat aspect = 0;
    if (!SGAnimatedArtworkKey(&aspect) || aspect <= 0) return;
    CGSize size = CGSizeMake(round(1920 * aspect), 1920);

    NSString *key = [NSString stringWithFormat:@"%@|%ld", track, (long)index];
    if (![key isEqualToString:sg_want ?: @""]) {
        sg_want = key;
        NSDictionary *ready = sg_cache[key];
        if (ready) {
            SGLog(@"lyrics artwork: line %ld of %@ (ready)", (long)index, track);
            applyClip(ready, track);
        } else {
            build(lines, index, track, size, YES);
        }
    }
    // The next one is drawn while this one is on screen, so the swap lands with the line and the
    // system has the file the moment it asks.
    NSString *ahead = [NSString stringWithFormat:@"%@|%ld", track, (long)index + 1];
    if (!sg_cache[ahead] && index + 1 < (NSInteger)lines.count) build(lines, index + 1, track, size, NO);
}

__attribute__((constructor)) static void SGLyricsArtworkStart(void) {
    if (!SGAnimatedArtworkAvailable()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
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
