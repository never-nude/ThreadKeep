#import "TKArchiveDecode.h"

id _Nullable TKTryUnarchive(NSData *_Nullable data) {
    if (data.length == 0) {
        return nil;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    @try {
        return [NSUnarchiver unarchiveObjectWithData:data];
    } @catch (NSException *exception) {
        // Malformed/legacy archive — swallow the Obj-C exception so the caller can skip the row.
        return nil;
    }
#pragma clang diagnostic pop
}
