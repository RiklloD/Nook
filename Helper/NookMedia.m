// NookMedia: a tiny MediaRemote bridge, loaded into /usr/bin/perl.
//
// Since macOS 15.4 MediaRemote only answers Apple-signed processes, and perl is one. Nook runs
// `perl stream.pl NookMedia.dylib`; this library then:
//   - prints one JSON line on stdout every time Now Playing changes (event-driven, no polling)
//   - reads commands on stdin: toggle | play | pause | next | prev | seek <seconds>
// It exits when stdin closes, so it never outlives Nook.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, CFDictionaryRef);
typedef void (*MRSetElapsed)(double);
typedef CFStringRef (*MRClientString)(id);

static MRGetInfo getInfo;
static MRGetIsPlaying getIsPlaying;
static MRGetClient getClient;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;
static MRClientString clientBundle, clientParent;

static NSUInteger lastArtHash;
static NSUInteger lastArtLength;
static BOOL pending;

static void emit(NSDictionary *payload) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void publish(void) {
    pending = NO;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *info = (__bridge NSDictionary *)raw;
        getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getClient(dispatch_get_main_queue(), ^(id client) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = playing ? @YES : @NO;
                NSString *bundle = client ? (__bridge NSString *)clientBundle(client) : nil;
                NSString *parent = client && clientParent ? (__bridge NSString *)clientParent(client) : nil;
                if (parent.length) out[@"bundle"] = parent;
                else if (bundle.length) out[@"bundle"] = bundle;

                NSDictionary *keys = @{
                    @"kMRMediaRemoteNowPlayingInfoTitle": @"title",
                    @"kMRMediaRemoteNowPlayingInfoArtist": @"artist",
                    @"kMRMediaRemoteNowPlayingInfoAlbum": @"album",
                    @"kMRMediaRemoteNowPlayingInfoDuration": @"duration",
                    @"kMRMediaRemoteNowPlayingInfoElapsedTime": @"elapsed",
                    @"kMRMediaRemoteNowPlayingInfoPlaybackRate": @"rate",
                };
                for (NSString *key in keys) {
                    id value = info[key];
                    if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class])
                        out[keys[key]] = value;
                }
                NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                if ([stamp isKindOfClass:NSDate.class]) out[@"ts"] = @(stamp.timeIntervalSince1970);

                // Artwork is only sent when it changes; the app keeps the last one otherwise.
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class] && art.length) {
                    NSUInteger hash = art.hash;
                    if (hash != lastArtHash || art.length != lastArtLength) {
                        lastArtHash = hash;
                        lastArtLength = art.length;
                        out[@"art"] = [art base64EncodedStringWithOptions:0];
                    }
                    out[@"hasArt"] = @YES;
                } else {
                    lastArtHash = 0;
                    lastArtLength = 0;
                }
                emit(out);
            });
        });
    });
}

// MediaRemote fires bursts of notifications per change; coalesce them into one read.
static void schedulePublish(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ publish(); });
}

static void handleCommand(NSString *line) {
    NSArray<NSString *> *parts = [line componentsSeparatedByString:@" "];
    NSString *verb = parts.firstObject;
    // MRMediaRemoteCommand values: play 0, pause 1, toggle 2, next 4, previous 5.
    if ([verb isEqualToString:@"toggle"]) sendCommand(2, NULL);
    else if ([verb isEqualToString:@"play"]) sendCommand(0, NULL);
    else if ([verb isEqualToString:@"pause"]) sendCommand(1, NULL);
    else if ([verb isEqualToString:@"next"]) sendCommand(4, NULL);
    else if ([verb isEqualToString:@"prev"]) sendCommand(5, NULL);
    else if ([verb isEqualToString:@"seek"] && parts.count > 1) setElapsed(parts[1].doubleValue);
    else if ([verb isEqualToString:@"refresh"]) schedulePublish();
}

__attribute__((visibility("default"))) void nook_run(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) exit(2);
    getInfo = dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getClient = dlsym(mr, "MRMediaRemoteGetNowPlayingClient");
    sendCommand = dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = dlsym(mr, "MRMediaRemoteSetElapsedTime");
    clientBundle = dlsym(mr, "MRNowPlayingClientGetBundleIdentifier");
    clientParent = dlsym(mr, "MRNowPlayingClientGetParentAppBundleIdentifier");
    MRRegister registerFn = dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getClient || !sendCommand || !setElapsed || !clientBundle || !registerFn) exit(3);

    registerFn(dispatch_get_main_queue());
    for (NSString *name in @[
        @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
        @"kMRMediaRemoteNowPlayingApplicationClientStateDidChange",
    ]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { schedulePublish(); }];
    }

    // Commands from Nook, one per line. EOF means Nook quit.
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    static NSMutableString *buffer;
    buffer = [NSMutableString string];
    dispatch_source_set_event_handler(input, ^{
        char chunk[512];
        ssize_t count = read(STDIN_FILENO, chunk, sizeof chunk);
        if (count <= 0) exit(0);
        [buffer appendString:[[NSString alloc] initWithBytes:chunk length:count encoding:NSUTF8StringEncoding] ?: @""];
        NSRange newline;
        while ((newline = [buffer rangeOfString:@"\n"]).location != NSNotFound) {
            NSString *line = [buffer substringToIndex:newline.location];
            [buffer deleteCharactersInRange:NSMakeRange(0, newline.location + 1)];
            handleCommand([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
        }
    });
    dispatch_resume(input);

    schedulePublish();
    CFRunLoopRun();
}
