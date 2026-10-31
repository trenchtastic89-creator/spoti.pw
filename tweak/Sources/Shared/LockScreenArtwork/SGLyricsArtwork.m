// The line being sung, drawn over the cover and handed to the lock screen as its animated artwork.
//
// The animated artwork key takes a video file and nothing else, so the frame is drawn into an MP4.
// The system reloads the clip whenever the now playing dictionary changes, and that reload is a
// visible blink, so one clip covers a run of lines: the sweep, the scroll between lines and the
// dimming of the ones either side all happen inside the video, and the system is only asked for new
// artwork once a stanza.
//
// The frame is the redesign's own lyrics page (Redesigned/Lyrics/SGRKaraokeView.m) ported to a still:
// every line at 30pt on a 390pt page, 24pt margins and 24pt between lines, the sung line at full
// white with the word under the playhead fading in behind a 22pt feather, the rest at 30% white and
// blurred a little more the further they are from it. The page's own anchor is 28% of its height;
// here it sits at 36% so the lock screen's clock has room above the words.
//
// The star: Chroma's star on the lock screen is iOS's like button, so the mod listens on the like
// command and swaps between the line and the track's own artwork instead of liking the song.
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import "Core/SGCore.h"
#import "LockScreenArtwork.h"
#import "Shared/Lyrics/Lyrics.h"

NSString *const SGLyricsArtworkKey = @"spotifyglass.lockscreen.lyricsartwork";
NSString *const SGLyricsStarKey = @"spotifyglass.lockscreen.modestar";

// Files are named with this, so a clip written by an older renderer is never shown again.
static NSString *const kClipTag = @"lyr4";

// The redesign's lyrics page, in the points it was laid out in.
static const CGFloat kPageHeight = 844;
static const CGFloat kFontSize = 30, kMargin = 24, kLineGap = 24;
static const CGFloat kDimAlpha = 0.3, kFillEdge = 22, kLift = 2.5, kDimScale = 0.97;
static const CGFloat kBlurPerLine = 1.4, kMaxBlur = 4.2;
// Where the sung line's top rests: lower than the app's page, so the clock clears it.
static const CGFloat kAnchor = 0.36;
// How much room the blur has on each side of a line's own box.
static const CGFloat kPad = 16;

// A clip covers a run of lines, so the system is asked for new artwork once a stanza rather than
// once a line. Longer runs mean fewer blinks and a longer wait before the first one can be shown,
// but every frame is drawn at the screen's full height and the phone has to keep decoding audio
// while it does: a stanza that costs a whole second of solid CPU is what made the sound crackle
// when the screen was locked mid-render, so the run is kept short.
static const NSInteger kSpanLines = 3;
static const NSTimeInterval kFPS = 10;
static const NSTimeInterval kShortest = 1.5;
static const NSTimeInterval kLongest = 12;

static dispatch_queue_t sg_queue;
static NSString *sg_track;      // the track the cache belongs to
static NSInteger sg_spanFirst = -1, sg_spanCount = 0;   // the clip the lock screen is showing
static NSInteger sg_started;    // where that clip's first frame sits on the track
static CFTimeInterval sg_startedAt;   // and when it went up, so a seek can be caught
static NSInteger sg_lastPosition;
static CFTimeInterval sg_buildTime;   // how long the last clips took, so a late one can be placed
static NSMutableDictionary<NSString *, NSDictionary *> *sg_cache;
static NSMutableSet<NSString *> *sg_pending;   // clips being encoded, so one is never asked for twice
static BOOL sg_ownArtwork;      // the star has been tapped: show the track's artwork, not the line
static NSString *sg_driftFor;   // the track whose cover is being drawn instead of a Canvas
static CFTimeInterval sg_ownAt; // when the star was tapped, so the Canvas has a moment to land
static NSUInteger sg_generation;

// One word of a line, in page points: where its box sits, how far along the line's sweep it starts,
// and when it is sung.
typedef struct {
    CGFloat x, y, w, h;
    CGFloat flow;
    NSInteger start, end;
    NSUInteger index;
} SGWordBox;

// What the module has done lately, for the row in Mod Settings: the phone is the only place this can
// be watched from, and a clip that never lands looks the same as one that lands late.
static NSMutableArray<NSString *> *sg_log;

static NSObject *logLock(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static void note(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    SGLog(@"lyrics artwork: %@", text);
    static NSDateFormatter *stamp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stamp = [NSDateFormatter new];
        stamp.dateFormat = @"HH:mm:ss.SSS";
    });
    @synchronized (logLock()) {
        if (!sg_log) sg_log = [NSMutableArray array];
        [sg_log addObject:[NSString stringWithFormat:@"%@  %@", [stamp stringFromDate:NSDate.date], text]];
        while (sg_log.count > 400) [sg_log removeObjectAtIndex:0];
    }
}

NSString *SGLyricsArtworkLog(void) {
    @synchronized (logLock()) {
        return sg_log.count ? [sg_log componentsJoinedByString:@"\n"] : @"nothing logged yet";
    }
}

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

// The cover under the words: dimmed, darkened towards the bottom so the controls sit on black, and
// vignetted so the edges fall away instead of reading as a photograph.
static UIImage *backingImage(UIImage *wash, CGSize size) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        [[UIColor blackColor] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        if (wash) [wash drawInRect:CGRectMake(0, 0, size.width, size.height)];

        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        [[UIColor colorWithWhite:0 alpha:0.38] setFill];
        CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
        NSArray *stops = @[(id)[UIColor colorWithWhite:0 alpha:0.10].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.78].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)stops, NULL);
        if (gradient) {
            CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(0, size.height), 0);
            CGGradientRelease(gradient);
        }
        NSArray *edges = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                           (id)[UIColor colorWithWhite:0 alpha:0.62].CGColor];
        CGGradientRef vignette = CGGradientCreateWithColors(space, (__bridge CFArrayRef)edges, NULL);
        if (vignette) {
            CGPoint centre = CGPointMake(size.width / 2, size.height * 0.42);
            CGContextDrawRadialGradient(c, vignette, centre, size.width * 0.12, centre, size.height * 0.72, 0);
            CGGradientRelease(vignette);
        }
        CGColorSpaceRelease(space);
    }];
}

#pragma mark - the line, in the page's own numbers

// A line's words with times on them: the source's own where it timed the words, spread across the
// line by length where it only timed the line. Everything downstream then has one shape to read.
static NSArray<SGKaraokeWord *> *timedWords(SGKaraokeLine *line) {
    BOOL timed = NO;
    for (SGKaraokeWord *word in line.words) {
        if (word.end > word.start && word.text.length) { timed = YES; break; }
    }
    if (timed) return line.words;

    NSString *text = SGKaraokeLineText(line);
    if (!text.length) return @[];
    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    for (NSString *piece in [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (piece.length) [pieces addObject:piece];
    }
    NSInteger start = line.start;
    NSInteger end = SGKaraokeSungEnd(line);
    if (end <= start) end = start + 4000;
    NSUInteger total = 0;
    for (NSString *piece in pieces) total += MAX(piece.length, 1);

    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    NSInteger at = start;
    for (NSString *piece in pieces) {
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = piece;
        word.start = at;
        at += (NSInteger)((double)(end - start) * MAX(piece.length, 1) / MAX(total, 1));
        word.end = at;
        [words addObject:word];
    }
    return words;
}

// Lays the words into rows as wide as the page. Each box is in page points; `flow` runs the whole
// line end to end, so the feather's travel across a row break is the same arithmetic as within one.
static NSData *layoutWords(NSArray<SGKaraokeWord *> *words, UIFont *font, CGFloat width, CGFloat *outHeight) {
    NSMutableData *data = [NSMutableData data];
    CGFloat space = ceil([@" " sizeWithAttributes:@{NSFontAttributeName: font}].width);
    CGFloat row = ceil(font.lineHeight) - 2;
    CGFloat high = ceil(font.lineHeight);
    CGFloat x = 0, y = 0, flow = 0;
    for (NSUInteger i = 0; i < words.count; i++) {
        SGKaraokeWord *word = words[i];
        CGFloat w = ceil([word.text sizeWithAttributes:@{NSFontAttributeName: font}].width);
        if (w < 1) w = 1;
        CGFloat lead = (i == 0 || word.joined) ? 0 : space;
        if (i > 0 && x + lead + w > width) {
            flow += width - x;
            y += row;
            x = 0;
            lead = 0;
        }
        SGWordBox box;
        box.x = x + lead;
        box.y = y;
        box.w = w;
        box.h = high;
        box.flow = flow + x + lead;
        box.start = word.start;
        box.end = word.end;
        box.index = i;
        [data appendBytes:&box length:sizeof(box)];
        x += lead + w;
    }
    *outHeight = y + high;
    return data;
}

// How far a word has risen: a critically damped spring over the first five of its own lengths,
// exactly as SGRKaraokeWordView does it, so a sung word sits about 2.4pt above an unsung one.
static CGFloat liftAt(const SGWordBox *box, double ms) {
    if (ms <= box->start) return 0;
    double span = MAX((double)(box->end - box->start), 700.0);
    double x = MAX(0.0, (ms - box->start + 80.0) / span * 5.0);
    return kLift * (1.0 - (1.0 + x) * exp(-x));
}

// Where the feather's centre is along the line's flow at this instant. Before the first word it is
// off the line; after the last it is past its end, so nothing is left dim.
static CGFloat cursorAt(const SGWordBox *boxes, NSUInteger count, double ms) {
    if (!count) return -1e9;
    if (ms <= boxes[0].start) return -1e9;
    for (NSUInteger i = 0; i < count; i++) {
        double to = (i + 1 < count) ? (double)boxes[i + 1].start : (double)boxes[i].end;
        CGFloat toFlow = (i + 1 < count) ? boxes[i + 1].flow : boxes[i].flow + boxes[i].w + kFillEdge / 2;
        if (ms < to) {
            double from = boxes[i].start;
            if (to <= from) return toFlow;
            double p = (ms - from) / (to - from);
            return boxes[i].flow + (CGFloat)(toFlow - boxes[i].flow) * (CGFloat)p;
        }
    }
    return 1e9;
}

// A 22pt feather, white on the left and clear on the right, used as the mask the lit words are drawn
// through. One pixel tall: the clip scales it to whatever row it is put over.
static CGImageRef featherMask(void) {
    static CGImageRef mask;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t w = 64;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
        CGContextRef c = CGBitmapContextCreate(nil, w, 1, 8, w, space, (CGBitmapInfo)kCGImageAlphaNone);
        if (c) {
            CGFloat parts[] = {1, 1, 0, 1};
            CGGradientRef gradient = CGGradientCreateWithColorComponents(space, parts, NULL, 2);
            if (gradient) {
                CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 0), CGPointMake(w, 0), 0);
                CGGradientRelease(gradient);
            }
            mask = CGBitmapContextCreateImage(c);
            CGContextRelease(c);
        }
        CGColorSpaceRelease(space);
    });
    return mask;
}

// One line of the page, written into a context at the frame's scale. Only ever used to make a
// line's picture: the clip draws those pictures, it never sets type for the same line twice.
static void drawLineWords(CGContextRef c, NSData *boxes, NSArray<NSString *> *texts, UIFont *font,
                          CGFloat offsetX, CGFloat offsetY, CGFloat scale) {
    const SGWordBox *b = boxes.bytes;
    NSUInteger n = boxes.length / sizeof(SGWordBox);
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByClipping;
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: UIColor.whiteColor,
        NSParagraphStyleAttributeName: paragraph,
    };
    for (NSUInteger i = 0; i < n; i++) {
        [texts[b[i].index] drawInRect:CGRectMake(offsetX + b[i].x * scale, offsetY + b[i].y * scale,
                                                 b[i].w * scale + 2, b[i].h * scale + 2)
                       withAttributes:attributes];
    }
}

// A whole line drawn on its own at full white. `lineScale` is 1 for the line being sung and 0.97 for
// the ones either side, which the app steps back so the sung one reads as the page's focus.
static UIImage *lineImage(NSData *boxes, NSArray<NSString *> *texts, UIFont *font,
                          CGFloat pageWidth, CGFloat height, CGFloat scale, CGFloat pad,
                          CGFloat lineScale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    CGSize size = CGSizeMake(pageWidth * scale, height * scale + pad * 2 * scale);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGContextRef c = context.CGContext;
        CGContextTranslateCTM(c, kMargin * scale, pad * scale);
        CGContextScaleCTM(c, lineScale, lineScale);
        drawLineWords(c, boxes, texts, font, -kMargin * scale, 0, scale);
    }];
}

// A line onto a frame: dim underneath, and the lit copy above it through the playhead's feather.
// Every word is a copy of the line's picture, so a frame costs a dozen blits and no type at all.
static void drawSungLine(CGContextRef c, UIImage *sharp, NSData *boxes, CGFloat offsetY,
                         CGFloat scale, CGFloat cursor, CGImageRef feather, BOOL swept, CGFloat fade) {
    if (!sharp) return;
    CGRect rect = CGRectMake(0, offsetY, sharp.size.width, sharp.size.height);
    [sharp drawInRect:rect blendMode:kCGBlendModeNormal alpha:kDimAlpha];
    if (!swept) {
        if (fade > 0) [sharp drawInRect:rect blendMode:kCGBlendModeNormal alpha:fade];
        return;
    }
    const SGWordBox *b = boxes.bytes;
    NSUInteger n = boxes.length / sizeof(SGWordBox);
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat heard = cursor - b[i].flow;
        if (heard <= 0) continue;
        CGContextSaveGState(c);
        CGContextClipToRect(c, CGRectMake(b[i].x * scale, offsetY + (kPad + b[i].y) * scale,
                                          b[i].w * scale, b[i].h * scale));
        if (heard < b[i].w + kFillEdge / 2) {
            CGContextClipToMask(c, CGRectMake((b[i].x + heard - kFillEdge / 2) * scale,
                                              offsetY + (kPad + b[i].y) * scale,
                                              kFillEdge * scale, b[i].h * scale), feather);
        }
        [sharp drawInRect:rect blendMode:kCGBlendModeNormal alpha:1.0];
        CGContextRestoreGState(c);
    }
}

static UIImage *blurred(UIImage *image, CGFloat radius) {
    if (!image || radius <= 0.01) return image;
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CIImage *input = [CIImage imageWithCGImage:image.CGImage];
    CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];
    [clamp setValue:input forKey:kCIInputImageKey];
    [clamp setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:kCIInputTransformKey];
    CIFilter *filter = [CIFilter filterWithName:@"CIGaussianBlur"];
    [filter setValue:clamp.outputImage forKey:kCIInputImageKey];
    [filter setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *out = filter.outputImage;
    if (!out) return image;
    CGImageRef cg = [context createCGImage:out fromRect:input.extent];
    if (!cg) return image;
    UIImage *result = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return result ?: image;
}

#pragma mark - writing the clip

// Writes the frames of one clip. `draw` gets a context already turned the right way up, so it can
// lay out in UIKit coordinates from the top left. The file is written beside the real one and only
// moved into place when the writer says it is complete: an app that is suspended or killed halfway
// through would otherwise leave a clip the lock screen can open and never play.
static BOOL writeClip(NSURL *url, CGSize size, NSTimeInterval seconds, NSTimeInterval fps,
                      void (^draw)(CGContextRef c, NSTimeInterval t)) {
    NSURL *partial = [url URLByAppendingPathExtension:@"part"];
    [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:partial fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) {
        note(@"writer: %@", error.localizedDescription);
        return NO;
    }
    size_t w = (size_t)(size.width) & ~1UL;
    size_t h = (size_t)(size.height) & ~1UL;
    if (w < 2 || h < 2) return NO;

    NSDictionary *settings = @{
        AVVideoCodecKey: AVVideoCodecTypeH264,
        AVVideoWidthKey: @(w),
        AVVideoHeightKey: @(h),
        AVVideoCompressionPropertiesKey: @{
            AVVideoAverageBitRateKey: @(w * h * 0.6),
            AVVideoMaxKeyFrameIntervalKey: @(24),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
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
        note(@"writer start: %@", writer.error.localizedDescription);
        return NO;
    }
    [writer startSessionAtSourceTime:kCMTimeZero];

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(w, h) format:format];

    NSInteger frames = MAX(1, (NSInteger)llround(seconds * fps));
    BOOL ok = YES;
    for (NSInteger frame = 0; frame < frames && ok; frame++) {
        @autoreleasepool {
            NSTimeInterval t = frame / fps;
            UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
                draw(context.CGContext, t);
            }];
            CVPixelBufferRef buffer = NULL;
            if (adaptor.pixelBufferPool) CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &buffer);
            if (!buffer) {
                CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer);
            }
            if (!buffer) { ok = NO; break; }
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            CGContextRef c = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), w, h, 8,
                CVPixelBufferGetBytesPerRow(buffer), space, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
            if (c) {
                // Drawn straight in: a bitmap context already puts the image the right way up, and
                // turning it over here is what had the whole clip upside down on the lock screen.
                CGContextDrawImage(c, CGRectMake(0, 0, w, h), image.CGImage);
                CGContextRelease(c);
            }
            CGColorSpaceRelease(space);
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            if (![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMakeWithSeconds(t, 600)]) ok = NO;
            CVPixelBufferRelease(buffer);
            // Left as it is, this runs flat out on the render queue and starves the audio thread;
            // a couple of milliseconds between frames costs a fraction of a second over the clip.
            usleep(2000);
        }
    }

    [input markAsFinished];
    if (!ok) {
        [writer cancelWriting];
        note(@"a frame was dropped");
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [writer endSessionAtSourceTime:CMTimeMakeWithSeconds(seconds, 600)];

    __block BOOL finished = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        finished = writer.status == AVAssetWriterStatusCompleted;
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!finished) {
        note(@"writer finish %ld %@", (long)writer.status, writer.error.localizedDescription);
        [NSFileManager.defaultManager removeItemAtURL:partial error:nil];
        return NO;
    }
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    NSError *move = nil;
    if (![NSFileManager.defaultManager moveItemAtURL:partial toURL:url error:&move]) {
        note(@"could not put the clip in place: %@", move.localizedDescription);
        return NO;
    }
    return YES;
}

#pragma mark - the star's other side

// A track with no Canvas and no album cover on Apple Music leaves the lock screen holding a plain
// sleeve, which reads as the toggle doing nothing. Chroma answers that with artwork of its own, and
// so does this: the sleeve filled to the frame, breathing a few percent and drifting a hair, once
// round in twelve seconds so the loop has no seam. Only built when neither source had a clip.
static NSDictionary *makeDriftClip(NSString *track, CGSize size) {
    UIImage *cover = coverImage(size);
    if (!cover || cover.size.width < 1 || cover.size.height < 1) return nil;
    NSURL *file = clipURL([NSString stringWithFormat:@"drift-%@", track]);
    NSTimeInterval seconds = 12;
    BOOL have = [NSFileManager.defaultManager fileExistsAtPath:file.path];
    if (!have) {
        have = writeClip(file, size, seconds, kFPS, ^(CGContextRef c, NSTimeInterval t) {
            double turn = t / seconds * 2 * M_PI;
            CGFloat zoom = 1.05 + 0.035 * sin(turn - M_PI_2);
            CGFloat dx = size.width * 0.010 * sin(turn);
            CGFloat dy = size.height * 0.008 * sin(turn + 1.3);
            CGFloat scale = MAX(size.width / cover.size.width, size.height / cover.size.height) * zoom;
            CGSize drawn = CGSizeMake(cover.size.width * scale, cover.size.height * scale);
            [[UIColor blackColor] setFill];
            CGContextFillRect(c, CGRectMake(0, 0, size.width, size.height));
            [cover drawInRect:CGRectMake((size.width - drawn.width) / 2 + dx,
                                         (size.height - drawn.height) / 2 + dy,
                                         drawn.width, drawn.height)];

            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            NSArray *stops = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                               (id)[UIColor colorWithWhite:0 alpha:0.55].CGColor];
            CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)stops, NULL);
            if (gradient) {
                CGContextDrawLinearGradient(c, gradient, CGPointMake(0, size.height * 0.45),
                                            CGPointMake(0, size.height), 0);
                CGGradientRelease(gradient);
            }
            NSArray *edges = @[(id)[UIColor colorWithWhite:0 alpha:0].CGColor,
                               (id)[UIColor colorWithWhite:0 alpha:0.45].CGColor];
            CGGradientRef vignette = CGGradientCreateWithColors(space, (__bridge CFArrayRef)edges, NULL);
            if (vignette) {
                CGPoint centre = CGPointMake(size.width / 2, size.height * 0.45);
                CGContextDrawRadialGradient(c, vignette, centre, size.width * 0.20, centre, size.height * 0.60, 0);
                CGGradientRelease(vignette);
            }
            CGColorSpaceRelease(space);
        });
    }
    if (!have) return nil;
    return @{@"file": file, @"still": cover};
}

#pragma mark - one clip

// How many lines one clip covers: up to kSpanLines, but never so long that the wait before it can be
// shown outruns the prefetch.
static NSInteger spanCount(NSArray<SGKaraokeLine *> *lines, NSInteger first) {
    NSInteger count = 0;
    NSInteger start = lines[first].start;
    for (NSInteger i = first; i < (NSInteger)lines.count && count < kSpanLines; i++) {
        if (!SGKaraokeLineText(lines[i]).length) continue;
        if (count > 0 && SGKaraokeSungEnd(lines[i]) - start > kLongest * 1000) break;
        count++;
    }
    return MAX(count, 1);
}

// The first frame, small: the preview the system shows before the video starts, and the one thing
// kept in memory for a whole track.
static UIImage *smaller(UIImage *image, CGFloat width) {
    if (!image || image.size.width <= width) return image;
    CGFloat ratio = width / image.size.width;
    CGSize size = CGSizeMake(round(image.size.width * ratio), round(image.size.height * ratio));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
}

// The clip for one run of lines, drawn and encoded, or nil. Cached by track and first line: the same
// run always looks the same, so it is only ever made once. `fromMs` is where the clip's first frame
// sits on the track — the line's own start normally, or wherever the playhead was when a seek left
// the clip behind.
static NSDictionary *makeClip(NSArray<SGKaraokeLine *> *lines, NSInteger first, NSInteger fromMs,
                              NSString *track, CGSize size) {
    if (first < 0 || first >= (NSInteger)lines.count) return nil;
    NSInteger count = spanCount(lines, first);
    if (first + count > (NSInteger)lines.count) count = (NSInteger)lines.count - first;
    if (count < 1) return nil;

    NSInteger startMs = fromMs > 0 ? fromMs : lines[first].start;
    NSInteger endMs = SGKaraokeSungEnd(lines[first + count - 1]);
    if (endMs <= startMs) endMs = startMs + 4000;
    NSTimeInterval seconds = MIN(MAX((endMs - startMs) / 1000.0, kShortest), kLongest);

    CGFloat scale = size.height / kPageHeight;
    CGFloat pageWidth = size.width / scale;
    CGFloat width = pageWidth - kMargin * 2;
    // Laid out at the page's own size and drawn at the frame's: everything below is in page points
    // until it goes through `scale`, and only the font is made at the size it is finally set in.
    UIFont *font = [UIFont systemFontOfSize:kFontSize weight:UIFontWeightBold];
    UIFont *drawn = [UIFont systemFontOfSize:kFontSize * scale weight:UIFontWeightBold];

    // Every line of the page, laid out once: heights, and where each one's words go.
    NSMutableArray<NSData *> *layouts = [NSMutableArray arrayWithCapacity:lines.count];
    NSMutableArray<NSArray<NSString *> *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    NSMutableArray<NSNumber *> *heights = [NSMutableArray arrayWithCapacity:lines.count];
    NSMutableArray<NSNumber *> *tops = [NSMutableArray arrayWithCapacity:lines.count];
    CGFloat top = 0;
    for (SGKaraokeLine *line in lines) {
        NSArray<SGKaraokeWord *> *words = timedWords(line);
        CGFloat height = 0;
        NSData *boxes = layoutWords(words, font, width, &height);
        if (height < 1) height = ceil(font.lineHeight);
        NSMutableArray<NSString *> *lineTexts = [NSMutableArray arrayWithCapacity:words.count];
        for (SGKaraokeWord *word in words) [lineTexts addObject:word.text ?: @""];
        [layouts addObject:boxes];
        [texts addObject:lineTexts];
        [heights addObject:@(height)];
        [tops addObject:@(top)];
        top += height + kLineGap;
    }

    UIImage *wash = washImage(coverImage(size), size);
    UIImage *base = backingImage(wash, size);

    // The lines either side of the run, drawn while the clip is made: they never change inside it,
    // and blurring or setting type per frame would cost more than everything else put together.
    NSInteger low = MAX(0, first - 2), high = MIN((NSInteger)lines.count - 1, first + count + 2);
    NSMutableDictionary<NSNumber *, NSArray<UIImage *> *> *still = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, UIImage *> *sharpLines = [NSMutableDictionary dictionary];
    for (NSInteger i = low; i <= high; i++) {
        CGFloat height = heights[i].doubleValue;
        UIImage *sharp = lineImage(layouts[i], texts[i], drawn, pageWidth, height, scale, kPad, 1);
        UIImage *stepped = lineImage(layouts[i], texts[i], drawn, pageWidth, height, scale, kPad, kDimScale);
        if (!sharp || !stepped) continue;
        sharpLines[@(i)] = sharp;
        still[@(i)] = @[blurred(stepped, kBlurPerLine * scale),
                        blurred(stepped, MIN(kMaxBlur, kBlurPerLine * 2) * scale)];
    }

    CGImageRef mask = featherMask();

    NSString *identifier = [NSString stringWithFormat:@"%@-%@-%ld-%ld", kClipTag, track, (long)first, (long)startMs];
    NSURL *file = clipURL(identifier);
    // A file left behind by an older build, or by a write that was cut short, is not trusted: only
    // one big enough to hold a clip is reused.
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    BOOL have = attributes.fileSize > 20000;

    BOOL wrote = YES;
    if (!have) {
        wrote = writeClip(file, size, seconds, kFPS, ^(CGContextRef c, NSTimeInterval t) {
            double ms = startMs + t * 1000.0;
            [base drawInRect:CGRectMake(0, 0, size.width, size.height)];

            // Which line is sung at this instant, and how far the page has scrolled towards it.
            NSInteger at = first;
            for (NSInteger i = first; i < first + count; i++) {
                if (ms >= lines[i].start) at = i;
            }
            CGFloat scroll = tops[at].doubleValue;
            if (at > first) {
                double since = (ms - lines[at].start) / 350.0;
                if (since < 1) {
                    CGFloat ease = 1 - pow(1 - MAX(0, since), 3);
                    scroll = tops[at - 1].doubleValue + (tops[at].doubleValue - tops[at - 1].doubleValue) * ease;
                }
            }

            for (NSInteger i = MAX(low, at - 2); i <= MIN(high, at + 3); i++) {
                if (i == at) continue;
                NSArray<UIImage *> *variants = still[@(i)];
                if (!variants) continue;
                NSInteger distance = labs((long)(i - at));
                UIImage *image = distance <= 1 ? variants[0] : variants[1];
                CGFloat y = (kAnchor * kPageHeight + tops[i].doubleValue - scroll - kPad) * scale;
                [image drawInRect:CGRectMake(0, y, pageWidth * scale, image.size.height) blendMode:kCGBlendModeNormal alpha:kDimAlpha];
            }

            // The sung line: the dim copy under, the lit one above through the playhead's feather.
            NSData *boxes = layouts[at];
            const SGWordBox *words = boxes.bytes;
            NSUInteger n = boxes.length / sizeof(SGWordBox);
            BOOL swept = NO;
            for (NSUInteger i = 0; i < n; i++) {
                if (words[i].end > words[i].start) { swept = YES; break; }
            }
            SGWordBox rise = {0, 0, 0, 0, 0, lines[at].start, lines[at].start + 900, 0};
            CGFloat lift = liftAt(&rise, ms);
            CGFloat y = (kAnchor * kPageHeight + tops[at].doubleValue - scroll - kPad) * scale - lift * scale;
            CGFloat fade = MIN(1.0, MAX(0.0, (ms - lines[at].start) / 350.0));
            drawSungLine(c, sharpLines[@(at)], boxes, y, scale, cursorAt(words, n, ms), mask, swept, fade);
        });
    }
    if (!wrote) return nil;

    // The first frame, for the preview the system shows before the video starts.
    __block UIImage *poster = nil;
    {
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = 1;
        format.opaque = YES;
        poster = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextRef c = context.CGContext;
            [base drawInRect:CGRectMake(0, 0, size.width, size.height)];
            NSInteger at = first;
            CGFloat scroll = tops[at].doubleValue;
            for (NSInteger i = MAX(low, at - 2); i <= MIN(high, at + 3); i++) {
                if (i == at) continue;
                NSArray<UIImage *> *variants = still[@(i)];
                if (!variants) continue;
                UIImage *image = labs((long)(i - at)) <= 1 ? variants[0] : variants[1];
                CGFloat y = (kAnchor * kPageHeight + tops[i].doubleValue - scroll - kPad) * scale;
                [image drawInRect:CGRectMake(0, y, pageWidth * scale, image.size.height) blendMode:kCGBlendModeNormal alpha:kDimAlpha];
            }
            NSData *boxes = layouts[at];
            const SGWordBox *words = boxes.bytes;
            NSUInteger n = boxes.length / sizeof(SGWordBox);
            BOOL swept = NO;
            for (NSUInteger i = 0; i < n; i++) {
                if (words[i].end > words[i].start) { swept = YES; break; }
            }
            CGFloat y = (kAnchor * kPageHeight + tops[at].doubleValue - scroll - kPad) * scale;
            drawSungLine(c, sharpLines[@(at)], boxes, y, scale, 1e9, mask, swept, 1.0);
        }];
    }
    if (!poster) return nil;
    // Kept in memory for the rest of the track, so it is stored small: a full-height frame here is
    // 7 MB a stanza and the lock screen re-renders it into whatever size it asks for anyway.
    poster = smaller(poster, 480);
    return @{@"file": file, @"still": poster, @"first": @(first), @"count": @(count),
             @"from": @(startMs), @"seconds": @(seconds)};
}

// What the lock screen shows now: a rendered clip, under a fresh id so the system takes it.
static void applyClip(NSDictionary *entry, NSString *track) {
    if (!entry || sg_ownArtwork) return;
    if (![SGKaraokePlayingTrack() isEqualToString:track]) return;
    NSString *identifier = [NSString stringWithFormat:@"lyr-%@-%lu", track, (unsigned long)++sg_generation];
    SGArtworkApplyLocal(identifier, entry[@"file"], entry[@"still"]);
    sg_spanFirst = [entry[@"first"] integerValue];
    sg_spanCount = [entry[@"count"] integerValue];
    sg_started = [entry[@"from"] integerValue];
    sg_startedAt = CACurrentMediaTime();
}

static NSString *clipKey(NSString *track, NSInteger first, NSInteger fromMs) {
    return fromMs > 0 ? [NSString stringWithFormat:@"%@|%ld|%ld", track, (long)first, (long)fromMs]
                      : [NSString stringWithFormat:@"%@|%ld", track, (long)first];
}

static void build(NSArray<SGKaraokeLine *> *lines, NSInteger first, NSInteger fromMs,
                  NSString *track, CGSize size, BOOL show) {
    // A phone that is already hot has no room for a hundred full-height frames on top of the audio.
    if (NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) {
        note(@"too warm to draw another clip");
        return;
    }
    NSString *key = clipKey(track, first, fromMs);
    [sg_pending addObject:key];
    CFTimeInterval began = CACurrentMediaTime();
    note(@"drawing %ld from %ld (%@)", (long)first, (long)fromMs, show ? @"needed" : @"ahead");
    dispatch_async(sg_queue, ^{
        @autoreleasepool {
            NSDictionary *entry = makeClip(lines, first, fromMs, track, size);
            CFTimeInterval took = CACurrentMediaTime() - began;
            dispatch_async(dispatch_get_main_queue(), ^{
                [sg_pending removeObject:key];
                if (entry) sg_buildTime = sg_buildTime > 0 ? sg_buildTime * 0.6 + took * 0.4 : took;
                if (!entry) {
                    note(@"clip %ld could not be made (%.1f s)", (long)first, took);
                    return;
                }
                note(@"clip %ld ready in %.1f s for %@ s", (long)first, took,
                     [entry[@"seconds"] stringValue] ?: @"?");
                if (![track isEqualToString:sg_track ?: @""]) return;
                if (fromMs <= 0) sg_cache[key] = entry;
                // Only the clips either side of the playhead are ever wanted again.
                if (sg_cache.count > 6) {
                    for (NSString *old in sg_cache.allKeys) {
                        if (![old isEqualToString:key]) { [sg_cache removeObjectForKey:old]; break; }
                    }
                }
                if (show && sg_spanFirst != first) {
                    note(@"applied %ld for %@", (long)first, track);
                    applyClip(entry, track);
                }
            });
        }
    });
}

static void tick(void);

// The star's other side: the track's own artwork. The Canvas and the album's cover are fetched by
// the module that owns them, so all this does is wait for one of them and, when neither arrives,
// put a moving sleeve there itself so the toggle never lands on a dead still.
static void tickOwn(void) {
    NSString *track = SGKaraokePlayingTrack();
    if (!track.length) return;
    CGFloat aspect = 0;
    if (!SGAnimatedArtworkKey(&aspect) || aspect <= 0) return;
    if (SGArtworkClipReady()) return;
    if (sg_driftFor.length && ![sg_driftFor isEqualToString:track]) {
        sg_driftFor = nil;
        sg_ownAt = CACurrentMediaTime();
    }
    if (sg_driftFor.length) return;
    if (sg_ownAt <= 0) {
        sg_ownAt = CACurrentMediaTime();
        return;
    }
    if (CACurrentMediaTime() - sg_ownAt < 1.2) return;

    sg_driftFor = [track copy];
    CGSize size = CGSizeMake(round(1920 * aspect), 1920);
    dispatch_async(sg_queue, ^{
        @autoreleasepool {
            NSDictionary *entry = makeDriftClip(track, size);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!entry || !sg_ownArtwork) return;
                if (![track isEqualToString:SGKaraokePlayingTrack() ?: @""]) return;
                if (SGArtworkClipReady()) return;   // a real Canvas landed while this was being drawn
                NSString *identifier = [NSString stringWithFormat:@"drift-%@-%lu", track, (unsigned long)++sg_generation];
                SGArtworkApplyLocal(identifier, entry[@"file"], entry[@"still"]);
                note(@"no clip for %@, the cover drifts instead", track);
            });
        }
    });
}

static void swapMode(void) {
    sg_ownArtwork = !sg_ownArtwork;
    sg_spanFirst = -1;
    sg_generation++;
    sg_driftFor = nil;
    sg_ownAt = sg_ownArtwork ? CACurrentMediaTime() : 0;
    sg_lastPosition = -1;
    SGArtworkReload();
    if (!sg_ownArtwork) tick();
    note(@"%@", sg_ownArtwork ? @"the track's own artwork" : @"back to the line");
}

static void tick(void) {
    if (!SGFlag(SGKeyLockScreenArtwork, YES)) return;
    if (sg_ownArtwork) { tickOwn(); return; }
    if (!SGFlag(SGLyricsArtworkKey, YES)) return;
    NSString *track = SGKaraokePlayingTrack();
    if (!track.length) return;
    if (![track isEqualToString:sg_track ?: @""]) {
        sg_track = [track copy];
        sg_cache = [NSMutableDictionary dictionary];
        sg_spanFirst = -1;
        sg_spanCount = 0;
        sg_lastPosition = -1;
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

    // A seek is a jump in the playhead between two ticks, not a disagreement with the wall clock:
    // comparing against the clock kept rebuilding a clip that had simply been drawn a second late,
    // which left the words permanently behind and the phone drawing all the time.
    NSInteger step = position - sg_lastPosition;
    BOOL seeked = sg_lastPosition > 0 && (step < -500 || step > 2500);
    sg_lastPosition = position;
    if (seeked && sg_spanFirst >= 0) {
        note(@"jumped %ld ms, at %ld", (long)step, (long)position);
        sg_spanFirst = -1;
        sg_spanCount = 0;
        sg_cache = [NSMutableDictionary dictionary];
        [sg_pending removeAllObjects];
    }

    // Still inside the run already on screen: keep it, and have the next one ready before it ends.
    if (sg_spanFirst >= 0 && index >= sg_spanFirst && index < sg_spanFirst + sg_spanCount) {
        NSInteger next = sg_spanFirst + sg_spanCount;
        if (next < (NSInteger)lines.count && SGKaraokeLineText(lines[next]).length) {
            NSString *key = clipKey(track, next, 0);
            if (!sg_cache[key] && ![sg_pending containsObject:key]) build(lines, next, 0, track, size, NO);
        }
        return;
    }

    NSString *key = clipKey(track, index, 0);
    NSDictionary *ready = sg_cache[key];
    if (ready) {
        note(@"line %ld of %@ was ready", (long)index, track);
        applyClip(ready, track);
    } else {
        // Nothing drawn for this line yet. The clip only starts playing when it is applied, so its
        // first frame is put where the playhead will be by then, not where it is now: without that
        // every clip opened a second or two behind and stayed there until the next one.
        NSInteger lead = (NSInteger)(sg_buildTime * 1000.0) + 250;
        NSString *late = clipKey(track, index, position + lead);
        if (![sg_pending containsObject:late]) build(lines, index, position + lead, track, size, YES);
    }
}

__attribute__((constructor)) static void SGLyricsArtworkStart(void) {
    if (!SGAnimatedArtworkAvailable()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:SGLyricsArtworkKey] == nil) [defaults setBool:YES forKey:SGLyricsArtworkKey];
    if ([defaults objectForKey:SGLyricsStarKey] == nil) [defaults setBool:NO forKey:SGLyricsStarKey];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Not UTILITY: a backgrounded app on that class is throttled so hard that a twelve second
        // clip took minutes to draw and the words fell further behind with every stanza. The frames
        // are a dozen blits now, so the burst is short enough at the default class.
        sg_queue = dispatch_queue_create("com.spotipw.lyricsartwork", DISPATCH_QUEUE_SERIAL);
        sg_pending = [NSMutableSet set];
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
            NSTimer *timer = [NSTimer timerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { tick(); }];
            [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
            note(@"on");
        });
    });
}
