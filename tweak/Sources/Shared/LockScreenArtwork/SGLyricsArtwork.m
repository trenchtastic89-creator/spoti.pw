// The line being sung, drawn over the cover and handed to the lock screen as its animated artwork.
//
// The animated artwork key takes a video file and nothing else, so each line is drawn once and
// written as an MP4 holding that frame for the length of the line. When the line changes a new clip
// is written under a new artwork id and the now playing dictionary is sent again, which is what
// makes the system ask for it.
//
// Nothing here runs unless Animated lock screen is on and the track has timed lyrics.
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import "Core/SGCore.h"
#import "LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

static const NSTimeInterval kTick = 0.3;
// A line is on screen for at least this long, so a clip is never empty.
static const NSTimeInterval kShortest = 1.2;
// Past this a clip is cut short; the system loops it and a still has nowhere to go.
static const NSTimeInterval kLongest = 10.0;

static dispatch_queue_t sg_queue;
static NSString *sg_want;   // track|line the last clip was asked for
static NSUInteger sg_generation;

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

static void drawText(NSString *text, CGRect rect, UIFont *font, UIColor *colour) {
    if (!text.length) return;
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByWordWrapping;
    [text drawInRect:rect withAttributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: colour,
        NSParagraphStyleAttributeName: paragraph,
    }];
}

// The cover filled to the size, darkened, the line large and the next one dim under it.
static CGImageRef renderFrame(NSString *line, NSString *next, CGSize size) {
    UIImage *cover = coverImage(size);
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage *drawn = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        [[UIColor blackColor] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        if (cover.size.width > 0 && cover.size.height > 0) {
            CGFloat scale = MAX(size.width / cover.size.width, size.height / cover.size.height);
            CGSize filled = CGSizeMake(cover.size.width * scale, cover.size.height * scale);
            [cover drawInRect:CGRectMake((size.width - filled.width) / 2, (size.height - filled.height) / 2,
                                         filled.width, filled.height)];
        }
        [[UIColor colorWithWhite:0 alpha:0.45] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        CGFloat band = size.height * 0.42;
        [[UIColor colorWithWhite:0 alpha:0.35] setFill];
        CGContextFillRect(c, CGRectMake(0, size.height - band, size.width, band));

        CGFloat side = size.width * 0.08;
        CGFloat width = size.width - side * 2;
        UIFont *lead = [UIFont systemFontOfSize:size.width * 0.082 weight:UIFontWeightBold];
        UIFont *under = [UIFont systemFontOfSize:size.width * 0.052 weight:UIFontWeightSemibold];
        drawText(line, CGRectMake(side, size.height * 0.60, width, size.height * 0.17), lead, UIColor.whiteColor);
        drawText(next, CGRectMake(side, size.height * 0.79, width, size.height * 0.10), under,
                 [UIColor colorWithWhite:1 alpha:0.55]);
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
    BOOL first = [adaptor appendPixelBuffer:buffer atPresentationTime:kCMTimeZero];
    BOOL last = [adaptor appendPixelBuffer:buffer atPresentationTime:tail];
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

static void render(NSArray<SGKaraokeLine *> *lines, NSInteger index, NSString *track) {
    NSString *line = SGKaraokeLineText(lines[index]);
    NSString *next = index + 1 < (NSInteger)lines.count ? SGKaraokeLineText(lines[index + 1]) : nil;
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
            CGImageRef image = renderFrame(line, next, size);
            if (!image) return;
            BOOL wrote = writeClip(image, seconds, file);
            UIImage *still = wrote ? [UIImage imageWithCGImage:image] : nil;
            CGImageRelease(image);
            if (!wrote) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != sg_generation) return;
                if (![SGKaraokePlayingTrack() isEqualToString:track]) return;
                SGLog(@"lyrics artwork: line %ld of %@ (%.1fs)", (long)index, track, seconds);
                SGArtworkApplyLocal(identifier, file, still);
            });
        }
    });
}

static void tick(void) {
    if (!SGFlag(SGKeyLockScreenArtwork, YES)) return;
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
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sg_queue = dispatch_queue_create("com.spotipw.lyricsartwork", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSTimer *timer = [NSTimer timerWithTimeInterval:kTick repeats:YES block:^(NSTimer *t) { tick(); }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
            SGLog(@"lyrics artwork: on");
        });
    });
}
