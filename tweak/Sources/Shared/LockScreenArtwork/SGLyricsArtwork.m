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
// once a line. Longer runs mean fewer blinks and a longer wait before the first one can be shown.
static const NSInteger kSpanLines = 4;
static const NSTimeInterval kFPS = 12;
static const NSTimeInterval kShortest = 1.5;
static const NSTimeInterval kLongest = 20;

static dispatch_queue_t sg_queue;
static NSString *sg_track;      // the track the cache belongs to
static NSInteger sg_spanFirst = -1, sg_spanCount = 0;   // the clip the lock screen is showing
static NSInteger sg_started;    // where that clip's first frame sits on the track
static CFTimeInterval sg_startedAt;   // and when it went up, so a seek can be caught
static NSInteger sg_lastPosition;
static NSMutableDictionary<NSString *, NSDictionary *> *sg_cache;
static NSMutableSet<NSString *> *sg_pending;   // clips being encoded, so one is never asked for twice
static BOOL sg_ownArtwork;      // the star has been tapped: show the track's artwork, not the line
static NSUInteger sg_generation;

// One word of a line, in page points: where its box sits, how far along the line's sweep it starts,
// and when it is sung.
typedef struct {
    CGFloat x, y, w, h;
    CGFloat flow;
    NSInteger start, end;
    NSUInteger index;
} SGWordBox;

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

// One line of the page, at the height it is drawn at. `mask` is nil for an ordinary pass; when it is
// set only the part of each word behind the playhead is drawn, feathered across kFillEdge.
static void drawLineWords(CGContextRef c, NSData *boxes, NSArray<NSString *> *texts, UIFont *font,
                          CGFloat offsetX, CGFloat offsetY, CGFloat scale, double ms,
                          CGFloat cursor, CGImageRef mask, CGFloat alpha) {
    const SGWordBox *b = boxes.bytes;
    NSUInteger n = boxes.length / sizeof(SGWordBox);
    NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByClipping;
    for (NSUInteger i = 0; i < n; i++) {
        CGFloat lift = liftAt(&b[i], ms);
        CGRect rect = CGRectMake(offsetX + b[i].x * scale, offsetY + (b[i].y - lift) * scale,
                                 b[i].w * scale + 2, b[i].h * scale + 2);
        NSDictionary *attributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:alpha],
            NSParagraphStyleAttributeName: paragraph,
        };
        NSString *text = texts[b[i].index];
        if (!mask) {
            [text drawInRect:rect withAttributes:attributes];
            continue;
        }
        // Where the feather sits in this word's own row.
        CGFloat local = b[i].x + (cursor - b[i].flow);
        CGFloat start = local - kFillEdge / 2, end = local + kFillEdge / 2;
        if (b[i].x + b[i].w <= start) {
            [text drawInRect:rect withAttributes:attributes];
            continue;
        }
        if (b[i].x >= end) continue;

        CGFloat solid = MIN(b[i].x + b[i].w, start);
        if (solid > b[i].x) {
            CGContextSaveGState(c);
            CGContextClipToRect(c, CGRectMake(offsetX + b[i].x * scale, offsetY + (b[i].y - lift) * scale,
                                              (solid - b[i].x) * scale, b[i].h * scale));
            [text drawInRect:rect withAttributes:attributes];
            CGContextRestoreGState(c);
        }
        CGContextSaveGState(c);
        CGContextClipToMask(c, CGRectMake(offsetX + start * scale, offsetY + (b[i].y - lift) * scale,
                                          kFillEdge * scale, b[i].h * scale), mask);
        [text drawInRect:rect withAttributes:attributes];
        CGContextRestoreGState(c);
    }
}

// A whole line drawn on its own at full white, and the same blurred: what an inactive line is shown
// as. Both are made once per clip; the active one is drawn afresh every frame for the sweep.
static UIImage *lineImage(NSData *boxes, NSArray<NSString *> *texts, UIFont *font,
                          CGFloat pageWidth, CGFloat height, CGFloat scale, CGFloat pad) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = NO;
    CGSize size = CGSizeMake(pageWidth * scale, height * scale + pad * 2 * scale);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        drawLineWords(context.CGContext, boxes, texts, font, 0, pad * scale, scale, 0, 0, NULL, 1.0);
    }];
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
// lay out in UIKit coordinates from the top left.
static BOOL writeClip(NSURL *url, CGSize size, NSTimeInterval seconds, NSTimeInterval fps,
                      void (^draw)(CGContextRef c, NSTimeInterval t)) {
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:url fileType:AVFileTypeMPEG4 error:&error];
    if (!writer) {
        SGLog(@"lyrics artwork: writer: %@", error.localizedDescription);
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
        SGLog(@"lyrics artwork: start: %@", writer.error.localizedDescription);
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
                // The buffer is bottom up; turn it over so the image lands the right way.
                CGContextTranslateCTM(c, 0, h);
                CGContextScaleCTM(c, 1, -1);
                CGContextDrawImage(c, CGRectMake(0, 0, w, h), image.CGImage);
                CGContextRelease(c);
            }
            CGColorSpaceRelease(space);
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            if (![adaptor appendPixelBuffer:buffer withPresentationTime:CMTimeMakeWithSeconds(t, 600)]) ok = NO;
            CVPixelBufferRelease(buffer);
        }
    }

    [input markAsFinished];
    if (!ok) {
        [writer cancelWriting];
        SGLog(@"lyrics artwork: frame dropped");
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
        SGLog(@"lyrics artwork: finish %ld %@", (long)writer.status, writer.error.localizedDescription);
        return NO;
    }
    return YES;
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

    // The lines either side of the run, drawn sharp and blurred while the clip is made: they never
    // change inside it, and blurring them per frame would cost more than the encoding does.
    NSInteger low = MAX(0, first - 2), high = MIN((NSInteger)lines.count - 1, first + count + 3);
    NSMutableDictionary<NSNumber *, NSArray<UIImage *> *> *still = [NSMutableDictionary dictionary];
    for (NSInteger i = low; i <= high; i++) {
        CGFloat height = heights[i].doubleValue;
        UIImage *sharp = lineImage(layouts[i], texts[i], drawn, pageWidth, height, scale, kPad);
        if (!sharp) continue;
        still[@(i)] = @[sharp, blurred(sharp, kBlurPerLine * scale), blurred(sharp, MIN(kMaxBlur, kBlurPerLine * 2) * scale)];
    }

    CGImageRef mask = featherMask();

    NSString *identifier = [NSString stringWithFormat:@"%@-%@-%ld-%ld", kClipTag, track, (long)first, (long)startMs];
    NSURL *file = clipURL(identifier);
    BOOL have = [NSFileManager.defaultManager fileExistsAtPath:file.path];

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

            for (NSInteger i = low; i <= high; i++) {
                if (i == at) continue;
                NSArray<UIImage *> *variants = still[@(i)];
                if (!variants) continue;
                NSInteger distance = labs((long)(i - at));
                UIImage *image = distance <= 1 ? variants[1] : variants[2];
                CGFloat y = (kAnchor * kPageHeight + tops[i].doubleValue - scroll - kPad) * scale;
                [image drawInRect:CGRectMake(0, y, pageWidth * scale, image.size.height) blendMode:kCGBlendModeNormal alpha:kDimAlpha];
            }

            // The sung line: dim underneath, lit on top through the feather at the playhead.
            NSData *boxes = layouts[at];
            const SGWordBox *words = boxes.bytes;
            NSUInteger n = boxes.length / sizeof(SGWordBox);
            CGFloat y = (kAnchor * kPageHeight + tops[at].doubleValue - scroll) * scale;
            BOOL swept = NO;
            for (NSUInteger i = 0; i < n; i++) {
                if (words[i].end > words[i].start) { swept = YES; break; }
            }
            drawLineWords(c, boxes, texts[at], drawn, 0, y, scale, ms, 0, NULL, kDimAlpha);
            if (swept) {
                CGFloat cursor = cursorAt(words, n, ms);
                drawLineWords(c, boxes, texts[at], drawn, 0, y, scale, ms, cursor, mask, 1.0);
            } else {
                double since = MAX(0.0, (ms - lines[at].start) / 350.0);
                CGFloat alpha = MIN(1.0, since);
                if (alpha > 0) drawLineWords(c, boxes, texts[at], drawn, 0, y, scale, ms, 0, NULL, alpha);
            }
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
            for (NSInteger i = low; i <= high; i++) {
                if (i == at) continue;
                NSArray<UIImage *> *variants = still[@(i)];
                if (!variants) continue;
                UIImage *image = labs((long)(i - at)) <= 1 ? variants[1] : variants[2];
                CGFloat y = (kAnchor * kPageHeight + tops[i].doubleValue - scroll - kPad) * scale;
                [image drawInRect:CGRectMake(0, y, pageWidth * scale, image.size.height) blendMode:kCGBlendModeNormal alpha:kDimAlpha];
            }
            NSData *boxes = layouts[at];
            const SGWordBox *words = boxes.bytes;
            NSUInteger n = boxes.length / sizeof(SGWordBox);
            CGFloat y = (kAnchor * kPageHeight + tops[at].doubleValue - scroll) * scale;
            drawLineWords(c, boxes, texts[at], drawn, 0, y, scale, startMs, 0, NULL, kDimAlpha);
            drawLineWords(c, boxes, texts[at], drawn, 0, y, scale, startMs, cursorAt(words, n, startMs), mask, 1.0);
        }];
    }
    if (!poster) return nil;
    return @{@"file": file, @"still": poster, @"first": @(first), @"count": @(count), @"from": @(startMs)};
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
    NSString *key = clipKey(track, first, fromMs);
    [sg_pending addObject:key];
    dispatch_async(sg_queue, ^{
        @autoreleasepool {
            NSDictionary *entry = makeClip(lines, first, fromMs, track, size);
            dispatch_async(dispatch_get_main_queue(), ^{
                [sg_pending removeObject:key];
                if (!entry) return;
                if (![track isEqualToString:sg_track ?: @""]) return;
                if (fromMs <= 0) sg_cache[key] = entry;
                if (show && sg_spanFirst != first) {
                    SGLog(@"lyrics artwork: from line %ld of %@", (long)first, track);
                    applyClip(entry, track);
                }
            });
        }
    });
}

static void tick(void);

static void swapMode(void) {
    sg_ownArtwork = !sg_ownArtwork;
    sg_spanFirst = -1;
    sg_generation++;
    SGArtworkReload();
    if (!sg_ownArtwork) tick();
    SGLog(@"lyrics artwork: %@", sg_ownArtwork ? @"the track's own artwork" : @"back to the line");
}

static void tick(void) {
    if (sg_ownArtwork) return;
    if (!SGFlag(SGKeyLockScreenArtwork, YES) || !SGFlag(SGLyricsArtworkKey, YES)) return;
    NSString *track = SGKaraokePlayingTrack();
    if (!track.length) return;
    if (![track isEqualToString:sg_track ?: @""]) {
        sg_track = [track copy];
        sg_cache = [NSMutableDictionary dictionary];
        sg_spanFirst = -1;
        sg_spanCount = 0;
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

    // A seek or a long pause leaves the clip behind the playhead. Caught only while the track is
    // actually moving, so a pause does not spin the renderer.
    BOOL playing = position != sg_lastPosition;
    sg_lastPosition = position;
    if (playing && sg_spanFirst >= 0) {
        double expect = sg_started + (CACurrentMediaTime() - sg_startedAt) * 1000.0;
        if (fabs(position - expect) > 2000) {
            SGLog(@"lyrics artwork: seek to %ld", (long)position);
            sg_spanFirst = -1;
            sg_spanCount = 0;
            NSString *key = clipKey(track, index, position);
            if (![sg_pending containsObject:key]) build(lines, index, position, track, size, YES);
            return;
        }
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
        SGLog(@"lyrics artwork: line %ld of %@ (ready)", (long)index, track);
        applyClip(ready, track);
    } else if (![sg_pending containsObject:key]) {
        build(lines, index, 0, track, size, YES);
    }
}

__attribute__((constructor)) static void SGLyricsArtworkStart(void) {
    if (!SGAnimatedArtworkAvailable()) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:SGLyricsArtworkKey] == nil) [defaults setBool:YES forKey:SGLyricsArtworkKey];
    if ([defaults objectForKey:SGLyricsStarKey] == nil) [defaults setBool:NO forKey:SGLyricsStarKey];

    static dispatch_once_t once;
    dispatch_once(&once, ^{
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
            SGLog(@"lyrics artwork: on");
        });
    });
}
