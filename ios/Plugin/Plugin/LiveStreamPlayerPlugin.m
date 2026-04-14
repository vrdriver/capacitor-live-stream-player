#import <Foundation/Foundation.h>
#import <Capacitor/Capacitor.h>

CAP_PLUGIN(LiveStreamPlayerPlugin, "LiveStreamPlayer",
    CAP_PLUGIN_METHOD(play, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(pause, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(resume, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(stop, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(setNowPlaying, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(seekTo, CAPPluginReturnPromise);
    CAP_PLUGIN_METHOD(getState, CAPPluginReturnPromise);
)
