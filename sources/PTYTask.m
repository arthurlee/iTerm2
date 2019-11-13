#define MAXRW 1024

#import "Coprocess.h"
#import "DebugLogging.h"
#import "iTermMalloc.h"
#import "iTermLegacyPTY.h"
#import "iTermMonoServerPTY.h"
#import "iTermNotificationController.h"
#import "iTermProcessCache.h"
#import "NSWorkspace+iTerm.h"
#import "PreferencePanel.h"
#import "PTYTask.h"
#import "PTYTask+MRR.h"
#import "TaskNotifier.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermLSOF.h"
#import "iTermOpenDirectory.h"
#import "iTermOrphanServerAdopter.h"
#import "iTermPTY.h"
#import "NSDictionary+iTerm.h"

#include "iTermFileDescriptorClient.h"
#include "iTermFileDescriptorServer.h"
#include "iTermFileDescriptorSocketPath.h"
#include "shell_launcher.h"
#include <dlfcn.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/msg.h>
#include <sys/select.h>
#include <sys/time.h>
#include <sys/user.h>
#include <unistd.h>
#include <util.h>

#define CTRLKEY(c) ((c)-'A'+1)

NSString *kCoprocessStatusChangeNotification = @"kCoprocessStatusChangeNotification";

static NSSize PTYTaskClampViewSize(NSSize viewSize) {
    return NSMakeSize(MAX(0, MIN(viewSize.width, USHRT_MAX)),
                      MAX(0, MIN(viewSize.height, USHRT_MAX)));
}

static void
setup_tty_param(iTermTTYState *ttyState,
                VT100GridSize gridSize,
                NSSize viewSize,
                BOOL isUTF8) {
    struct termios *term = &ttyState->term;
    struct winsize *win = &ttyState->win;

    memset(term, 0, sizeof(struct termios));
    memset(win, 0, sizeof(struct winsize));

    // UTF-8 input will be added on demand.
    term->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT | (isUTF8 ? IUTF8 : 0);
    term->c_oflag = OPOST | ONLCR;
    term->c_cflag = CREAD | CS8 | HUPCL;
    term->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;

    term->c_cc[VEOF] = CTRLKEY('D');
    term->c_cc[VEOL] = -1;
    term->c_cc[VEOL2] = -1;
    term->c_cc[VERASE] = 0x7f;           // DEL
    term->c_cc[VWERASE] = CTRLKEY('W');
    term->c_cc[VKILL] = CTRLKEY('U');
    term->c_cc[VREPRINT] = CTRLKEY('R');
    term->c_cc[VINTR] = CTRLKEY('C');
    term->c_cc[VQUIT] = 0x1c;           // Control+backslash
    term->c_cc[VSUSP] = CTRLKEY('Z');
    term->c_cc[VDSUSP] = CTRLKEY('Y');
    term->c_cc[VSTART] = CTRLKEY('Q');
    term->c_cc[VSTOP] = CTRLKEY('S');
    term->c_cc[VLNEXT] = CTRLKEY('V');
    term->c_cc[VDISCARD] = CTRLKEY('O');
    term->c_cc[VMIN] = 1;
    term->c_cc[VTIME] = 0;
    term->c_cc[VSTATUS] = CTRLKEY('T');

    term->c_ispeed = B38400;
    term->c_ospeed = B38400;

    NSSize safeViewSize = PTYTaskClampViewSize(viewSize);
    win->ws_row = gridSize.height;
    win->ws_col = gridSize.width;
    win->ws_xpixel = safeViewSize.width;
    win->ws_ypixel = safeViewSize.height;
}

static void HandleSigChld(int n) {
    // This is safe to do because write(2) is listed in the sigaction(2) man page
    // as allowed in a signal handler. Calling a method is *NOT* safe since something might
    // be fiddling with the runtime. I saw a lot of crashes where CoreData got interrupted by
    // a sigchild while doing class_addMethod and that caused a crash because of a method call.
    UnblockTaskNotifier();
}

@interface PTYTaskLock : NSObject
@end

@implementation PTYTaskLock
@end

@interface PTYTask ()
@property(atomic, assign) BOOL hasMuteCoprocess;
@property(atomic, assign) BOOL coprocessOnlyTaskIsDead;
@property(atomic, retain) NSFileHandle *logHandle;
@property(nonatomic, copy) NSString *logPath;
@end

typedef struct {
    VT100GridSize gridSize;
    NSSize viewSize;
} PTYTaskSize;

@implementation PTYTask {
    NSString *_tty;
    int status;
    NSString* path;
    BOOL hasOutput;

    NSLock* writeLock;  // protects writeBuffer
    NSMutableData* writeBuffer;

    Coprocess *coprocess_;  // synchronized (self)
    BOOL brokenPipe_;
    NSString *command_;  // Command that was run if launchWithPath:arguments:etc was called

    // Number of spins of the select loop left before we tell the delegate we were deregistered.
    int _spinsNeeded;
    BOOL _paused;

    PTYTaskSize _desiredSize;
    NSTimeInterval _timeOfLastSizeChange;
    BOOL _rateLimitedSetSizeToDesiredSizePending;
    BOOL _haveBumpedProcessCache;

    id<iTermPTY> _pty;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        writeBuffer = [[NSMutableData alloc] init];
        writeLock = [[NSLock alloc] init];
        if ([iTermAdvancedSettingsModel runJobsInServers]) {
            _pty = [[iTermMonoServerPTY alloc] init];
        } else {
            _pty = [[iTermLegacyPTY alloc] init];
        }
    }
    return self;
}

- (void)dealloc {
    [[TaskNotifier sharedInstance] deregisterTask:self];

    [_pty shutdown];

    if (_tmuxClientProcessID) {
        [[iTermProcessCache sharedInstance] unregisterTrackedPID:_tmuxClientProcessID.intValue];
    }

    [self closeFileDescriptor];
    [_logHandle closeFile];

    @synchronized (self) {
        [[self coprocess] mainProcessDidTerminate];
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<%@: %p %@ tmux pid=%@>",
            NSStringFromClass([self class]), self, _pty, _tmuxClientProcessID];
}

#pragma mark - APIs

- (BOOL)paused {
    @synchronized(self) {
        return _paused;
    }
}

- (void)setPaused:(BOOL)paused {
    @synchronized(self) {
        _paused = paused;
    }
    // Start/stop selecting on our FD
    [[TaskNotifier sharedInstance] unblock];
}

- (BOOL)pidIsChild {
    return [_pty pidIsChild];
}

- (pid_t)serverPid {
    return [_pty serverPid];
}

- (int)fd {
    return [_pty fd];
}

- (pid_t)pid {
    return [_pty pid];
}

- (int)status {
    return status;
}

- (NSString *)path {
    return path;
}

- (NSString *)getWorkingDirectory {
    if (self.pid == -1) {
        DLog(@"Want to use the kernel to get the working directory but pid = -1");
        return nil;
    }
    return [iTermLSOF workingDirectoryOfProcess:self.pid];
}

- (BOOL)logging {
    @synchronized(self) {
        return (_logHandle != nil);
    }
}

- (Coprocess *)coprocess {
    @synchronized (self) {
        return coprocess_;
    }
    return nil;
}

- (void)setCoprocess:(Coprocess *)coprocess {
    @synchronized (self) {
        coprocess_ = coprocess;
        self.hasMuteCoprocess = coprocess_.mute;
    }
    [[TaskNotifier sharedInstance] unblock];
}

- (BOOL)writeBufferHasRoom {
    const int kMaxWriteBufferSize = 1024 * 10;
    [writeLock lock];
    BOOL hasRoom = [writeBuffer length] < kMaxWriteBufferSize;
    [writeLock unlock];
    return hasRoom;
}

- (BOOL)hasCoprocess {
    @synchronized (self) {
        return coprocess_ != nil;
    }
    return NO;
}

- (BOOL)passwordInput {
    struct termios termAttributes;
    const int fd = [_pty fd];
    if ([iTermAdvancedSettingsModel detectPasswordInput] &&
        fd > 0 &&
        isatty(fd) &&
        tcgetattr(fd, &termAttributes) == 0) {
        return !(termAttributes.c_lflag & ECHO) && (termAttributes.c_lflag & ICANON);
    } else {
        return NO;
    }
}

- (BOOL)hasBrokenPipe {
    return brokenPipe_;
}

- (NSString *)originalCommand {
    return command_;
}

- (void)launchWithPath:(NSString *)progpath
             arguments:(NSArray *)args
           environment:(NSDictionary *)env
              gridSize:(VT100GridSize)gridSize
              viewSize:(NSSize)viewSize
                isUTF8:(BOOL)isUTF8
           autologPath:(NSString *)autologPath
           synchronous:(BOOL)synchronous
            completion:(void (^)(void))completion {
    DLog(@"launchWithPath:%@ args:%@ env:%@ grisSize:%@ isUTF8:%@ autologPath:%@ synchronous:%@",
         progpath, args, env, VT100GridSizeDescription(gridSize), @(isUTF8), autologPath, @(synchronous));

    if ([iTermAdvancedSettingsModel runJobsInServers]) {
        // We want to run
        //   iTerm2 --server progpath args
        NSArray *updatedArgs = [@[ @"--server", progpath ] arrayByAddingObjectsFromArray:args];
        if (![iTermAdvancedSettingsModel bootstrapDaemon]) {
            env = [env dictionaryBySettingObject:@"1" forKey:@"ITERM2_DISABLE_BOOTSTRAP"];
        }
        [self reallyLaunchWithPath:[[NSBundle mainBundle] executablePath]
                         arguments:updatedArgs
                       environment:env
                          gridSize:gridSize
                          viewSize:viewSize
                            isUTF8:isUTF8
                       autologPath:autologPath
                       synchronous:synchronous
                        completion:completion];
    } else {
        [self reallyLaunchWithPath:progpath
                         arguments:args
                       environment:env
                          gridSize:gridSize
                          viewSize:viewSize
                            isUTF8:isUTF8
                       autologPath:autologPath
                       synchronous:synchronous
                        completion:completion];
    }
}

- (void)setTmuxClientProcessID:(NSNumber *)tmuxClientProcessID {
    if ([NSObject object:tmuxClientProcessID isEqualToObject:_tmuxClientProcessID]) {
        return;
    }
    DLog(@"Set tmux client process ID for %@ to %@", self, tmuxClientProcessID);
    if (_tmuxClientProcessID) {
        [[iTermProcessCache sharedInstance] unregisterTrackedPID:_tmuxClientProcessID.intValue];
    }
    if (tmuxClientProcessID) {
        [[iTermProcessCache sharedInstance] registerTrackedPID:tmuxClientProcessID.intValue];
    }
    _tmuxClientProcessID = tmuxClientProcessID;
}

- (pid_t)processIDForCurrentJob {
    return self.tmuxClientProcessID ? self.tmuxClientProcessID.intValue : self.pid;
}

- (void)fetchProcessInfoForCurrentJobWithCompletion:(void (^)(iTermProcessInfo *))completion {
    const pid_t pid = self.processIDForCurrentJob;
    iTermProcessInfo *info = [[iTermProcessCache sharedInstance] deepestForegroundJobForPid:pid];
    DLog(@"%@ fetch process info for %@", self, @(pid));
    if (info.name) {
        DLog(@"Return name synchronously");
        completion(info);
    } else if (info) {
        DLog(@"Have info for pid %@ but no name", @(pid));
    }

    if (pid <= 0) {
        DLog(@"Lack a good pid");
        completion(nil);
        return;
    }
    if (_haveBumpedProcessCache) {
        DLog(@"Already bumped process cache");
        [[iTermProcessCache sharedInstance] setNeedsUpdate:YES];
        return;
    }
    _haveBumpedProcessCache = YES;
    DLog(@"Requesting immediate update");
    [[iTermProcessCache sharedInstance] requestImmediateUpdateWithCompletionBlock:^{
        completion([[iTermProcessCache sharedInstance] deepestForegroundJobForPid:pid]);
    }];
}

- (iTermProcessInfo *)cachedProcessInfoIfAvailable {
    const pid_t pid = self.pid;
    iTermProcessInfo *info = [[iTermProcessCache sharedInstance] deepestForegroundJobForPid:pid];
    if (info.name) {
        return info;
    }

    if (pid > 0 && _haveBumpedProcessCache) {
        _haveBumpedProcessCache = YES;
        [[iTermProcessCache sharedInstance] setNeedsUpdate:YES];
    }

    return nil;
}

- (void)writeTask:(NSData *)data {
    if (self.isCoprocessOnly) {
        // Send keypresses to tmux.
        NSData *copyOfData = [data copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_delegate writeForCoprocessOnlyTask:copyOfData];
        });
    } else {
        // Write as much as we can now through the non-blocking pipe
        // Lock to protect the writeBuffer from the IO thread
        [writeLock lock];
        [writeBuffer appendData:data];
        [[TaskNotifier sharedInstance] unblock];
        [writeLock unlock];
    }
}

- (void)sendSignal:(int)signo toServer:(BOOL)toServer {
    [_pty sendSignal:signo toServer:toServer];
    if (_tmuxClientProcessID) {
        [[iTermProcessCache sharedInstance] unregisterTrackedPID:_tmuxClientProcessID.intValue];
    }
}

- (void)setSize:(VT100GridSize)size viewSize:(NSSize)viewSize {
    DLog(@"Set terminal size to %@", VT100GridSizeDescription(size));
    if (self.fd == -1) {
        return;
    }

    NSSize safeViewSize = PTYTaskClampViewSize(viewSize);
    _desiredSize.gridSize = size;
    _desiredSize.viewSize = safeViewSize;

    [self rateLimitedSetSizeToDesiredSize];
}

- (void)stop {
    self.paused = NO;
    [self stopLogging];
    [self sendSignal:SIGHUP toServer:NO];
    [self killServerIfRunning];

    if ([_pty fd] >= 0) {
        [self closeFileDescriptor];
        [[TaskNotifier sharedInstance] deregisterTask:self];
        // Require that it spin twice so we can be completely sure that the task won't get called
        // again. If we add the observer just before select() was going to be called, it wouldn't
        // mean anything; but after the second call, we know we've been moved into the dead pool.
        @synchronized(self) {
            _spinsNeeded = 2;
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(notifierDidSpin)
                                                     name:kTaskNotifierDidSpin
                                                   object:nil];
        // Force a spin
        [[TaskNotifier sharedInstance] unblock];

        // This isn't an atomic update, but select() should be resilient to
        // being passed a half-broken fd. We must change it because after this
        // function returns, a new task may be created with this fd and then
        // the select thread wouldn't know which task a fd belongs to.
        [_pty invalidate];
    }
    if (self.isCoprocessOnly) {
        self.coprocessOnlyTaskIsDead = YES;
    }
}

- (BOOL)startLoggingToFileWithPath:(NSString*)aPath shouldAppend:(BOOL)shouldAppend {
    @synchronized(self) {
        self.logPath = [aPath stringByStandardizingPath];

        [_logHandle closeFile];
        self.logHandle = [NSFileHandle fileHandleForWritingAtPath:_logPath];
        if (_logHandle == nil) {
            NSFileManager *fileManager = [NSFileManager defaultManager];
            [fileManager createFileAtPath:_logPath contents:nil attributes:nil];
            self.logHandle = [NSFileHandle fileHandleForWritingAtPath:_logPath];
        }
        if (shouldAppend) {
            [_logHandle seekToEndOfFile];
        } else {
            [_logHandle truncateFileAtOffset:0];
        }

        return self.logging;
    }
}

- (void)stopLogging {
    @synchronized(self) {
        [_logHandle closeFile];
        self.logPath = nil;
        self.logHandle = nil;
    }
}

- (void)brokenPipe {
    brokenPipe_ = YES;
    [[TaskNotifier sharedInstance] deregisterTask:self];
    [self.delegate threadedTaskBrokenPipe];
}

- (void)processRead {
    int iterations = 4;
    int bytesRead = 0;

    char buffer[MAXRW * iterations];
    for (int i = 0; i < iterations; ++i) {
        // Only read up to MAXRW*iterations bytes, then release control
        ssize_t n = read([_pty fd], buffer + bytesRead, MAXRW);
        if (n < 0) {
            // There was a read error.
            if (errno != EAGAIN && errno != EINTR) {
                // It was a serious error.
                [self brokenPipe];
                return;
            } else {
                // We could read again in the case of EINTR but it would
                // complicate the code with little advantage. Just bail out.
                n = 0;
            }
        }
        bytesRead += n;
        if (n < MAXRW) {
            // If we read fewer bytes than expected, return. For some apparently
            // undocumented reason, read() never returns more than 1024 bytes
            // (at least on OS 10.6), so that's what MAXRW is set to. If that
            // ever goes down this'll break.
            break;
        }
    }

    hasOutput = YES;

    // Send data to the terminal
    [self readTask:buffer length:bytesRead];
}

- (void)processWrite {
    // Retain to prevent the object from being released during this method
    // Lock to protect the writeBuffer from the main thread
    [writeLock lock];

    // Only write up to MAXRW bytes, then release control
    char* ptr = [writeBuffer mutableBytes];
    unsigned int length = [writeBuffer length];
    if (length > MAXRW) {
        length = MAXRW;
    }
    ssize_t written = write([_pty fd], [writeBuffer mutableBytes], length);

    // No data?
    if ((written < 0) && (!(errno == EAGAIN || errno == EINTR))) {
        [self brokenPipe];
    } else if (written > 0) {
        // Shrink the writeBuffer
        length = [writeBuffer length] - written;
        memmove(ptr, ptr+written, length);
        [writeBuffer setLength:length];
    }

    // Clean up locks
    [writeLock unlock];
}

- (void)stopCoprocess {
    pid_t thePid = 0;
    @synchronized (self) {
        if (coprocess_.pid > 0) {
            thePid = coprocess_.pid;
        }
        [coprocess_ terminate];
        coprocess_ = nil;
        self.hasMuteCoprocess = NO;
    }
    if (thePid) {
        [[TaskNotifier sharedInstance] waitForPid:thePid];
    }
    [[TaskNotifier sharedInstance] performSelectorOnMainThread:@selector(notifyCoprocessChange)
                                                    withObject:nil
                                                 waitUntilDone:NO];
}

- (void)logData:(const char *)buffer length:(int)length {
    @synchronized(self) {
        if ([self logging]) {
            @try {
                [_logHandle writeData:[NSData dataWithBytes:buffer
                                                     length:length]];
            } @catch (NSException *exception) {
                DLog(@"Exception while logging %@ bytes of data: %@", @(length), exception);
                [self stopLogging];
            }
        }
    }
}

- (BOOL)tryToAttachToServerWithProcessId:(pid_t)thePid {
    return [_pty tryToAttachToServerWithProcessId:thePid];
}

- (void)attachToServer:(iTermFileDescriptorServerConnection)serverConnection {
    [_pty attachToServer:serverConnection];
    [[TaskNotifier sharedInstance] registerTask:self];
}

// Sends a signal to the server. This breaks it out of accept()ing forever when iTerm2 quits.
- (void)killServerIfRunning {
    [_pty killServerIfRunning];
    NSLog(@"File descriptor server exited with status %d", status);
}

- (void)registerAsCoprocessOnlyTask {
    self.isCoprocessOnly = YES;
    [[TaskNotifier sharedInstance] registerTask:self];
}

- (void)writeToCoprocessOnlyTask:(NSData *)data {
    if (self.coprocess) {
        TaskNotifier *taskNotifier = [TaskNotifier sharedInstance];
        [taskNotifier lock];
        @synchronized (self) {
            [self.coprocess.outputBuffer appendData:data];
        }
        [taskNotifier unlock];

        // Wake up the task notifier so the coprocess's output buffer will be sent to its file
        // descriptor.
        [taskNotifier unblock];
    }
}

#pragma mark - Private

#pragma mark Task Launching Helpers

// Returns a NSMutableDictionary containing the key-value pairs defined in the
// global "environ" variable.
- (NSMutableDictionary *)mutableEnvironmentDictionary {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    extern char **environ;
    if (environ != NULL) {
        for (int i = 0; environ[i]; i++) {
            NSString *kvp = [NSString stringWithUTF8String:environ[i]];
            NSRange equalsRange = [kvp rangeOfString:@"="];
            if (equalsRange.location != NSNotFound) {
                NSString *key = [kvp substringToIndex:equalsRange.location];
                NSString *value = [kvp substringFromIndex:equalsRange.location + 1];
                result[key] = value;
            } else {
                result[kvp] = @"";
            }
        }
    }
    return result;
}

// Returns an array of C strings terminated with a null pointer of the form
// KEY=VALUE that is based on this process's "environ" variable. Values passed
// in "env" are added or override existing environment vars. Both the returned
// array and all string pointers within it are malloced and should be free()d
// by the caller.
- (char **)environWithOverrides:(NSDictionary *)env {
    NSMutableDictionary *environmentDict = [self mutableEnvironmentDictionary];
    for (NSString *k in env) {
        environmentDict[k] = env[k];
    }
    char **environment = iTermMalloc(sizeof(char*) * (environmentDict.count + 1));
    int i = 0;
    for (NSString *k in environmentDict) {
        NSString *temp = [NSString stringWithFormat:@"%@=%@", k, environmentDict[k]];
        environment[i++] = strdup([temp UTF8String]);
    }
    environment[i] = NULL;
    return environment;
}

- (NSDictionary *)environmentBySettingShell:(NSDictionary *)originalEnvironment {
    NSString *shell = [iTermOpenDirectory userShell];
    if (!shell) {
        return originalEnvironment;
    }
    NSMutableDictionary *newEnvironment = [originalEnvironment mutableCopy];
    newEnvironment[@"SHELL"] = [shell copy];
    return newEnvironment;
}

- (void)setCommand:(NSString *)command {
    command_ = [command copy];
}

- (void)populateArgvArray:(const char **)argv
              fromProgram:(NSString *)progpath
                     args:(NSArray *)args
                    count:(int)max {
    argv[0] = [[progpath stringByStandardizingPath] UTF8String];
    if (args != nil) {
        int i;
        for (i = 0; i < max; ++i) {
            argv[i + 1] = [args[i] UTF8String];
        }
    }
    argv[max + 1] = NULL;
}

- (void)failedToForkProgram:(NSString *)progpath {
    DLog(@"Unable to fork %@: %s", progpath, strerror(errno));
    [[iTermNotificationController sharedInstance] notify:@"Unable to fork!" withDescription:@"You may have too many processes already running."];
}

- (void)freeEnvironment:(char **)newEnviron {
    for (int j = 0; newEnviron[j]; j++) {
        free(newEnviron[j]);
    }
    free(newEnviron);
}

- (NSString *)tty {
    @synchronized([PTYTaskLock class]) {
        return _tty;
    }
}

- (void)setTty:(NSString *)tty {
    @synchronized([PTYTaskLock class]) {
        _tty = [tty copy];
    }
    if ([NSThread isMainThread]) {
        [self.delegate taskDidChangeTTY:self];
    } else {
        __weak id<PTYTaskDelegate> delegate = self.delegate;
        __weak __typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong __typeof(self) strongSelf = weakSelf;
            if (strongSelf) {
                [delegate taskDidChangeTTY:strongSelf];
            }
        });
    }
}

- (void)reallyLaunchWithPath:(NSString *)progpath
                   arguments:(NSArray *)args
                 environment:(NSDictionary *)env
                    gridSize:(VT100GridSize)gridSize
                    viewSize:(NSSize)viewSize
                      isUTF8:(BOOL)isUTF8
                 autologPath:(NSString *)autologPath
                 synchronous:(BOOL)synchronous
                  completion:(void (^)(void))completion {
    DLog(@"reallyLaunchWithPath:%@ args:%@ env:%@ gridSize:%@ viewSize:%@ isUTF8:%@ autologPath:%@ synchronous:%@",
         progpath, args, env,VT100GridSizeDescription(gridSize), NSStringFromSize(viewSize), @(isUTF8), autologPath, @(synchronous));
    if (autologPath) {
        [self startLoggingToFileWithPath:autologPath shouldAppend:[iTermAdvancedSettingsModel autologAppends]];
    }

    iTermTTYState ttyState;
    setup_tty_param(&ttyState, gridSize, viewSize, isUTF8);

    [self setCommand:progpath];
    env = [self environmentBySettingShell:env];
    DLog(@"After setting shell environment is %@", env);
    path = [progpath copy];
    NSString *commandToExec = [progpath stringByStandardizingPath];
    const char *argpath = [commandToExec UTF8String];

    // Register a handler for the child death signal. There is some history here.
    // Originally, a do-nothing handler was registered with the following comment:
    //   We cannot ignore SIGCHLD because Sparkle (the software updater) opens a
    //   Safari control which uses some buggy Netscape code that calls wait()
    //   until it succeeds. If we wait() on its pid, that process locks because
    //   it doesn't check if wait()'s failure is ECHLD. Instead of wait()ing here,
    //   we reap our children when our select() loop sees that a pipes is broken.
    // In response to bug 2903, wherein select() fails to return despite the file
    // descriptor having EOF status, I changed the handler to unblock the task
    // notifier.
    signal(SIGCHLD, HandleSigChld);

    int max = (args == nil) ? 0 : [args count];
    const char* argv[max + 2];
    [self populateArgvArray:argv fromProgram:progpath args:args count:max];

    DLog(@"Preparing to launch a job. Command is %@ and args are %@", commandToExec, args);
    DLog(@"Environment is\n%@", env);
    char **newEnviron = [self environWithOverrides:env];

    // Note: stringByStandardizingPath will automatically call stringByExpandingTildeInPath.
    const char *initialPwd = [[[env objectForKey:@"PWD"] stringByStandardizingPath] UTF8String];
    DLog(@"initialPwd=%s", initialPwd);
    iTermForkState forkState = {
        .connectionFd = -1,
        .deadMansPipe = { 0, 0 },
    };

    const BOOL forkOK = [_pty forkAndExecWithEnvironment:newEnviron
                                               forkState:&forkState
                                                ttyState:&ttyState
                                                 argPath:argpath
                                                    argv:argv
                                              initialPwd:initialPwd];
    // Parent
    [self freeEnvironment:newEnviron];

    if (!forkOK) {
        if (completion != nil) {
            completion();
        }
        return;
    }

    if (forkState.pid < (pid_t)0) {
        // Error
        [self failedToForkProgram:progpath];
        if (completion != nil) {
            completion();
        }
        return;
    }


    // Make sure the master side of the pty is closed on future exec() calls.
    DLog(@"fcntl");
    const int fd = [_pty fd];
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);

    DLog(@"done forking");
    [_pty didForkParent:&forkState
               ttyState:&ttyState
            synchronous:synchronous
             completion:^(NSString *tty, BOOL failedImmediately, BOOL shouldRegister){
                 if (tty) {
                     self.tty = tty;
                 }
                 if (failedImmediately) {
                     [self.delegate taskDiedImmediately];
                 }
                 if (shouldRegister) {
                     [[TaskNotifier sharedInstance] registerTask:self];
                 }
                 if (completion) {
                     completion();
                 }
             }];
}

#pragma mark I/O

- (BOOL)wantsRead {
    return !self.paused;
}

- (BOOL)wantsWrite {
    if (self.paused) {
        return NO;
    }
    [writeLock lock];
    BOOL wantsWrite = [writeBuffer length] > 0;
    [writeLock unlock];
    return wantsWrite;
}

- (BOOL)hasOutput {
    return hasOutput;
}

// The bytes in data were just read from the fd.
- (void)readTask:(char *)buffer length:(int)length {
    [self logData:buffer length:length];

    // The delegate is responsible for parsing VT100 tokens here and sending them off to the
    // main thread for execution. If its queues get too large, it can block.
    [self.delegate threadedReadTask:buffer length:length];

    @synchronized (self) {
        if (coprocess_) {
            [coprocess_.outputBuffer appendData:[NSData dataWithBytes:buffer length:length]];
        }
    }
}

- (void)closeFileDescriptor {
    [_pty closeFileDescriptor];
}

#pragma mark Terminal Size

- (void)rateLimitedSetSizeToDesiredSize {
    if (_rateLimitedSetSizeToDesiredSizePending) {
        return;
    }

    static const NSTimeInterval kDelayBetweenSizeChanges = 0.2;
    if ([NSDate timeIntervalSinceReferenceDate] - _timeOfLastSizeChange < kDelayBetweenSizeChanges) {
        // Avoid problems with signal coalescing of SIGWINCH preventing redraw for the second size
        // change. For example, issue 5096 and 4494.
        _rateLimitedSetSizeToDesiredSizePending = YES;
        DLog(@" ** Rate limiting **");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kDelayBetweenSizeChanges * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_rateLimitedSetSizeToDesiredSizePending = NO;
            [self setTerminalSizeToDesiredSize];
        });
    } else {
        [self setTerminalSizeToDesiredSize];
    }
}

- (void)setTerminalSizeToDesiredSize {
    DLog(@"Set size of %@ to %@ cells, %@ px", _delegate, VT100GridSizeDescription(_desiredSize.gridSize), NSStringFromSize(_desiredSize.viewSize));
    _timeOfLastSizeChange = [NSDate timeIntervalSinceReferenceDate];
    if (![_pty isatty]) {
        return;
    }

    struct winsize winsize;
    const int fd = [_pty fd];
    if (fd < 0) {
        return;
    }
    ioctl(fd, TIOCGWINSZ, &winsize);
    if (winsize.ws_col != _desiredSize.gridSize.width ||
        winsize.ws_row != _desiredSize.gridSize.height ||
        winsize.ws_xpixel != _desiredSize.viewSize.width ||
        winsize.ws_ypixel != _desiredSize.viewSize.height) {
        DLog(@"Actually setting the size");
        winsize.ws_col = _desiredSize.gridSize.width;
        winsize.ws_row = _desiredSize.gridSize.height;
        winsize.ws_xpixel = _desiredSize.viewSize.width;
        winsize.ws_ypixel = _desiredSize.viewSize.height;
        ioctl(fd, TIOCSWINSZ, &winsize);
    }
}

#pragma mark Process Tree

- (pid_t)getFirstChildOfPid:(pid_t)parentPid {
    return [iTermLSOF pidOfFirstChildOf:parentPid];
}

#pragma mark - Notifications

// This runs in TaskNotifier's thread.
- (void)notifierDidSpin {
    BOOL unblock = NO;
    @synchronized(self) {
        unblock = (--_spinsNeeded) > 0;
    }
    if (unblock) {
        // Force select() to return so we get another spin even if there is no
        // activity on the file descriptors.
        [[TaskNotifier sharedInstance] unblock];
    } else {
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self.delegate taskWasDeregistered];
    }
}

@end

