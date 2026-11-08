#import "AudioWriterBridge.h"

AVAssetWriterInput *SWMakeAudioWriterInput(
    NSDictionary<NSString *, id> *settings,
    CMFormatDescriptionRef formatHint,
    NSError **error
) {
    @try {
        return [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                            outputSettings:settings
                                          sourceFormatHint:formatHint];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"com.superworkspace.audio"
                                        code:1
                                    userInfo:@{NSLocalizedDescriptionKey:
                                        @"The selected microphone format is unsupported. Choose another microphone or turn off microphone recording."}];
        }
        return nil;
    }
}
