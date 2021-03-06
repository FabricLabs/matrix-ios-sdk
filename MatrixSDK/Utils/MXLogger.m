/*
 Copyright 2015 OpenMarket Ltd

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at

 http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
 */

#import "MXLogger.h"

#import "MatrixSDK.h"

// stderr so it can be restored
int stderrSave = 0;

static NSString *buildVersion;
static NSString *subLogName;

#define MXLOGGER_CRASH_LOG @"crash.log"

@implementation MXLogger

#pragma mark - NSLog redirection
+ (void)redirectNSLogToFiles:(BOOL)redirectNSLogToFiles
{
    if (redirectNSLogToFiles)
    {
        NSMutableString *log = [NSMutableString string];

        // Default subname
        if (!subLogName)
        {
            subLogName = @"";
        }

        // Set log location
        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSString *logsFolderPath = [MXLogger logsFolderPath];

        // Do a circular buffer based on 10 files
        for (NSInteger index = 8; index >= 0; index--)
        {
            NSString *nsLogPathOlder;
            NSString *nsLogPathCurrent;

            if (index == 0)
            {
                nsLogPathOlder   = [NSString stringWithFormat:@"console%@.1.log", subLogName];
                nsLogPathCurrent = [NSString stringWithFormat:@"console%@.log", subLogName];
            }
            else
            {
                nsLogPathOlder   = [NSString stringWithFormat:@"console%@.%tu.log", subLogName, index + 1];
                nsLogPathCurrent = [NSString stringWithFormat:@"console%@.%tu.log", subLogName, index];
            }

            nsLogPathOlder = [logsFolderPath stringByAppendingPathComponent:nsLogPathOlder];
            nsLogPathCurrent = [logsFolderPath stringByAppendingPathComponent:nsLogPathCurrent];

            if ([fileManager fileExistsAtPath:nsLogPathCurrent])
            {
                if ([fileManager fileExistsAtPath:nsLogPathOlder])
                {
                    // Temp log
                    [log appendFormat:@"[NSLog] redirectNSLogToFiles: removeItemAtPath: %@\n", nsLogPathOlder];

                    NSError *error;
                    [fileManager removeItemAtPath:nsLogPathOlder error:&error];
                    if (error)
                    {
                        [log appendFormat:@"[NSLog] ERROR: removeItemAtPath: %@. Error: %@\n", nsLogPathOlder, error];
                    }
                }

                // Temp log
                [log appendFormat:@"[NSLog] redirectNSLogToFiles: moveItemAtPath: %@ toPath: %@\n", nsLogPathCurrent, nsLogPathOlder];

                NSError *error;
                [fileManager moveItemAtPath:nsLogPathCurrent toPath:nsLogPathOlder error:&error];
                if (error)
                {
                    [log appendFormat:@"[NSLog] ERROR: moveItemAtPath: %@ toPath: %@. Error: %@\n", nsLogPathCurrent, nsLogPathOlder, error];
                }
            }
        }

        // Save stderr so it can be restored.
        stderrSave = dup(STDERR_FILENO);

        NSString *nsLogPath = [logsFolderPath stringByAppendingPathComponent:[NSString stringWithFormat:@"console%@.log", subLogName]];
        freopen([nsLogPath fileSystemRepresentation], "w+", stderr);

        NSLog(@"[NSLog] redirectNSLogToFiles: YES");
        if (log.length)
        {
            // We can now log into files
            NSLog(@"%@", log);
        }
    }
    else if (stderrSave)
    {
        // Flush before restoring stderr
        fflush(stderr);

        // Now restore stderr, so new output goes to console.
        dup2(stderrSave, STDERR_FILENO);
        close(stderrSave);
    }
}

+ (void)deleteLogFiles
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *logFile in [self logFiles])
    {
        [fileManager removeItemAtPath:logFile error:nil];
    }
}

+ (NSArray*)logFiles
{
    NSMutableArray *logFiles = [NSMutableArray array];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *logsFolderPath = [MXLogger logsFolderPath];

    NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtPath:logsFolderPath];

    // Find all *.log files
    NSString *file = nil;
    while ((file = [dirEnum nextObject]))
    {
        if ([[file lastPathComponent] hasPrefix:@"console"])
        {
            NSString *logPath = [logsFolderPath stringByAppendingPathComponent:file];
            [logFiles addObject:logPath];
        }
    }

    NSLog(@"[NSLog] logFiles: %@", logFiles);

    return logFiles;
}


#pragma mark - Exceptions and crashes
// Exceptions uncaught by try catch block are handled here
static void handleUncaughtException(NSException *exception)
{
    [MXLogger logCrashes:NO];

    // Extract running app information
    NSDictionary* infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString* appVersion;
    NSString* app, *appId;

    app = infoDict[@"CFBundleExecutable"];
    appId = infoDict[@"CFBundleIdentifier"];

    if ([infoDict objectForKey:@"CFBundleVersion"])
    {
        appVersion =  [NSString stringWithFormat:@"%@ (r%@)", [infoDict objectForKey:@"CFBundleShortVersionString"],  [infoDict objectForKey:@"CFBundleVersion"]];
    }
    else
    {
        appVersion =  [infoDict objectForKey:@"CFBundleShortVersionString"];
    }

    // Build the crash log
#if TARGET_OS_IPHONE
    NSString *model = [[UIDevice currentDevice] model];
    NSString *version = [[UIDevice currentDevice] systemVersion];
#elif TARGET_OS_OSX
    NSString *model = @"Mac";
    NSString *version = [[NSProcessInfo processInfo] operatingSystemVersionString];
#endif
    NSArray  *backtrace = [exception callStackSymbols];
    NSString *description = [NSString stringWithFormat:@"%.0f - %@\n%@\nApplication: %@ (%@)\nApplication version: %@\nMatrix SDK version: %@\nBuild: %@\n%@ %@\n\nMain thread: %@\n%@\n",
                             [[NSDate date] timeIntervalSince1970],
                             [NSDate date],
                             exception.description,
                             app, appId,
                             appVersion,
                             MatrixSDKVersion,
                             buildVersion,
                             model, version,
                             [NSThread isMainThread] ? @"YES" : @"NO",
                             backtrace];

    // Write to the crash log file
    [MXLogger deleteCrashLog];
    NSString *crashLog = crashLogPath();
    [description writeToFile:crashLog
                  atomically:NO
                    encoding:NSStringEncodingConversionAllowLossy
                       error:nil];

    NSLog(@"[MXLogger] handleUncaughtException:\n%@", description);
}

// Signals emitted by the app are handled here
static void handleSignal(int signalValue)
{
    // Throw a custom Objective-C exception
    // The Objective-C runtime will then be able to build a readable call stack in handleUncaughtException
    [NSException raise:@"Signal detected" format:@"Signal detected: %d", signalValue];
}

+ (void)logCrashes:(BOOL)logCrashes
{
    if (logCrashes)
    {
        // Handle not managed exceptions by ourselves
        NSSetUncaughtExceptionHandler(&handleUncaughtException);

        // Register signal event (seg fault & cie)
        signal(SIGABRT, handleSignal);
        signal(SIGILL, handleSignal);
        signal(SIGSEGV, handleSignal);
        signal(SIGFPE, handleSignal);
        signal(SIGBUS, handleSignal);
    }
    else
    {
        // Disable crash handling
        NSSetUncaughtExceptionHandler(NULL);
        signal(SIGABRT, SIG_DFL);
        signal(SIGILL, SIG_DFL);
        signal(SIGSEGV, SIG_DFL);
        signal(SIGFPE, SIG_DFL);
        signal(SIGBUS, SIG_DFL);
    }
}

+ (void)setBuildVersion:(NSString *)theBuildVersion
{
    buildVersion = theBuildVersion;
}

+ (void)setSubLogName:(NSString *)theSubLogName
{
    subLogName = [NSString stringWithFormat:@"-%@", theSubLogName];
}

// Return the path of the crash log file
static NSString* crashLogPath(void)
{
    return [[MXLogger logsFolderPath] stringByAppendingPathComponent:MXLOGGER_CRASH_LOG];
}

+ (NSString*)crashLog
{
    NSString *exceptionLog;

    NSString *crashLog = crashLogPath();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if([fileManager fileExistsAtPath:crashLog])
    {
        exceptionLog = crashLog;
    }
    return exceptionLog;
}

+ (void)deleteCrashLog
{
    NSString *crashLog = crashLogPath();
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if([fileManager fileExistsAtPath:crashLog])
    {
        [fileManager removeItemAtPath:crashLog error:nil];
    }
}

// The folder where logs are stored
+ (NSString*)logsFolderPath
{
    NSString *logsFolderPath = nil;

    NSString *applicationGroupIdentifier = [MXSDKOptions sharedInstance].applicationGroupIdentifier;
    if (applicationGroupIdentifier)
    {
        NSURL *sharedContainerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:applicationGroupIdentifier];
        logsFolderPath = [sharedContainerURL path];
    }
    else
    {
        NSArray<NSURL *> *paths = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask];
        logsFolderPath = paths[0].path;
    }

    return logsFolderPath;
}

@end


