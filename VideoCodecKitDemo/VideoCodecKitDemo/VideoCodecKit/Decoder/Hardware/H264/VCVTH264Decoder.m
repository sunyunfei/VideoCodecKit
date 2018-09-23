//
//  VCVTH264Decoder.m
//  VideoCodecKitDemo
//
//  Created by CmST0us on 2018/9/22.
//  Copyright © 2018年 eric3u. All rights reserved.
//

#import <VideoToolbox/VideoToolbox.h>
#import "VCVTH264Decoder.h"
#import "VCH264Frame.h"
#import "VCYUV420PImage.h"

@interface VCVTH264Decoder () {
    CMVideoFormatDescriptionRef _videoFormatDescription;
    VTDecompressionSessionRef _decodeSession;
    
    uint8_t *_sps;
    size_t _spsSize;
    uint8_t *_pps;
    size_t _ppsSize;
    uint8_t *_sei;
    size_t _seiSize;
    NSInteger _startCodeSize;
    
    BOOL _isVideoFormatDescriptionUpdate;
    BOOL _hasSEI;
}

@end

@implementation VCVTH264Decoder

static void decompressionOutputCallback(void *decompressionOutputRefCon,
                                        void *sourceFrameRefCon,
                                        OSStatus status,
                                        VTDecodeInfoFlags infoFlags,
                                        CVImageBufferRef imageBuffer,
                                        CMTime presentationTimeStamp,
                                        CMTime presentationDuration) {
    CVPixelBufferRef *outputPixelBuffer = (CVPixelBufferRef *)sourceFrameRefCon;
    *outputPixelBuffer = CVPixelBufferRetain(imageBuffer);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _videoFormatDescription = NULL;
        _decodeSession = NULL;
        _spsSize = 0;
        _ppsSize = 0;
        _seiSize = 0;
        
        _hasSEI = NO;
        _isVideoFormatDescriptionUpdate = NO;
    }
    return self;
}

- (void)dealloc {
    [self freeSPS];
    [self freePPS];
    [self freeSEI];
    
    [self freeVideoFormatDescription];
    [self freeDecodeSession];
}

- (void)freeDecodeSession {
    if (_decodeSession != NULL) {
        VTDecompressionSessionInvalidate(_decodeSession);
        CFRelease(_decodeSession);
        _decodeSession = NULL;
    }
}

- (void)freeVideoFormatDescription {
    if (_videoFormatDescription != NULL) {
        CFRelease(_videoFormatDescription);
        _videoFormatDescription = NULL;
    }
}

- (void)freeSPS {
    if (_sps != NULL) {
        free(_sps);
        _sps = NULL;
        _spsSize = 0;
    }
}

- (void)freePPS {
    if (_pps != NULL) {
        free(_pps);
        _pps = NULL;
        _ppsSize = 0;
    }
}

- (void)freeSEI {
    if (_sei != NULL) {
        free(_sei);
        _sei = NULL;
        _seiSize = 0;
    }
}

- (void)setup {
    
    [self commitStateTransition];
}

- (void)invalidate {
    [self freeDecodeSession];
    [self freeVideoFormatDescription];
    [self freeSPS];
    [self freePPS];
    [self freeSEI];
    [self commitStateTransition];
}

- (BOOL)setupVideoFormatDescription {
    [self freeVideoFormatDescription];
    
    const uint8_t *para[3] = {_sps, _pps, _sei};
    const size_t paraSize[3] = {_spsSize, _ppsSize, _seiSize};
    
    OSStatus ret = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                       _hasSEI ? 2 : 2,
                                                                       para,
                                                                       paraSize,
                                                                       4,
                                                                       &_videoFormatDescription);
    if (ret == 0) {
        return YES;
    }
    return NO;
}

- (BOOL)setupDecompressionSession {
    if (_videoFormatDescription == NULL) return NO;
    [self freeDecodeSession];
    
    CFDictionaryRef attr = NULL;
    const void *keys[] = {kCVPixelBufferPixelFormatTypeKey};
    uint32_t v = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const void *values[] = {CFNumberCreate(NULL, kCFNumberSInt32Type, &v)};
    attr = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
    
    VTDecompressionOutputCallbackRecord callbackRecord;
    callbackRecord.decompressionOutputCallback = decompressionOutputCallback;
    callbackRecord.decompressionOutputRefCon = NULL;
    
    OSStatus ret = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                 _videoFormatDescription,
                                 NULL,
                                 attr,
                                 &callbackRecord,
                                 &_decodeSession);
    CFRelease(attr);
    
    if (ret == 0) {
        return YES;
    }
    return NO;
}

- (void)tryUseSPS:(uint8_t *)spsData length:(size_t)length {
    
    if (spsData != NULL && _sps != NULL && memcmp(spsData, _sps, length) == 0) {
        // same
        return;
    }
    
    [self freeSPS];
    
    _spsSize = length;
    _sps = (uint8_t *)malloc(_spsSize);
    memcpy(_sps, spsData, _spsSize);
    _isVideoFormatDescriptionUpdate = YES;
}

- (void)tryUsePPS:(uint8_t *)ppsData length:(size_t)length {
    if (ppsData != NULL && _pps != NULL && memcmp(ppsData, _pps, length) == 0) {
        // same
        return;
    }
    
    [self freePPS];
    
    _ppsSize = length;
    _pps = (uint8_t *)malloc(_ppsSize);
    memcpy(_pps, ppsData, _ppsSize);
    _isVideoFormatDescriptionUpdate = YES;
}

- (void)tryUseSEI:(uint8_t *)seiData length:(size_t)length {
    if (seiData != NULL && _sei != NULL && memcmp(seiData, _sei, length) == 0) {
        // same
        return;
    }

    [self freeSEI];
    
    _seiSize = length;
    _sei = (uint8_t *)malloc(_seiSize);
    memcpy(_sei, seiData, _seiSize);
    _isVideoFormatDescriptionUpdate = YES;
    _hasSEI = YES;
}

- (id<VCImageTypeProtocol>)decode:(id<VCFrameTypeProtocol>)frame {
    if (self.currentState.unsignedIntegerValue != VCBaseDecoderStateRunning) return nil;
    
    if (![frame isKindOfClass:[VCH264Frame class]]) nil;
    
    VCH264Frame *decodeFrame = (VCH264Frame *)frame;
    
    if (decodeFrame.startCodeSize < 0) return nil;
    _startCodeSize = decodeFrame.startCodeSize;
    
    uint32_t nalSize = (uint32_t)(decodeFrame.parseSize - _startCodeSize);
    uint32_t *pNalSize = (uint32_t *)decodeFrame.parseData;
    if (_startCodeSize == 4) {
        *pNalSize = CFSwapInt32HostToBig(nalSize);
    } else {
        // 暂不支持 start code 为 00 00 01的slice帧
        // rbsp拷贝
        uint8_t *copyRbsp = malloc(nalSize + 4);
        static uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};
        memcpy(copyRbsp + 4, decodeFrame.parseData + _startCodeSize, nalSize);
        memcpy(copyRbsp, startCode, 4);
        free(decodeFrame.parseData);
        decodeFrame.parseData = copyRbsp;
        decodeFrame.parseSize = nalSize + 4;
        decodeFrame.startCodeSize = 4;
        _startCodeSize = decodeFrame.startCodeSize;
        
        uint32_t nalSize = (uint32_t)(decodeFrame.parseSize - _startCodeSize);
        uint32_t *pNalSize = (uint32_t *)decodeFrame.parseData;
        *pNalSize = CFSwapInt32HostToBig(nalSize);
    }
    
    if (decodeFrame.frameType == VCH264FrameTypeSPS) {
        // copy sps
        [self tryUseSPS:decodeFrame.parseData + _startCodeSize length:nalSize];
        return nil;
    } else if (decodeFrame.frameType == VCH264FrameTypePPS) {
        // copy pps
        [self tryUsePPS:decodeFrame.parseData + _startCodeSize length:nalSize];
        return nil;
    } else if (decodeFrame.frameType == VCH264FrameTypeSEI) {
        // copy sei
        [self tryUseSEI:decodeFrame.parseData + _startCodeSize length:nalSize];
        return nil;
    }
    
    if (decodeFrame.frameType == VCH264FrameTypeIDR) {
        if (_isVideoFormatDescriptionUpdate) {
            if (![self setupVideoFormatDescription]) {
                _isVideoFormatDescriptionUpdate = YES;
            } else {
                if ([self setupDecompressionSession]) {
                    _isVideoFormatDescriptionUpdate = NO;
                }
            }
        }
    }
    
    if (_videoFormatDescription == NULL) return nil;
    // decode process
    CMBlockBufferRef blockBuffer = NULL;
    CVPixelBufferRef outputPixelBuffer = NULL;
    OSStatus ret = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                      decodeFrame.parseData,
                                                      decodeFrame.parseSize,
                                                      kCFAllocatorNull,
                                                      NULL,
                                                      0,
                                                      decodeFrame.parseSize,
                                                      0,
                                                      &blockBuffer);
    if (ret == kCMBlockBufferNoErr) {
        // decode success
        CMSampleBufferRef sampleBuffer = NULL;
        const size_t sampleSizeArray[] = {decodeFrame.parseSize};
        ret = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                        blockBuffer,
                                        _videoFormatDescription,
                                        1,
                                        0,
                                        NULL,
                                        1,
                                        sampleSizeArray,
                                        &sampleBuffer);
        if (ret == kCMBlockBufferNoErr && sampleBuffer) {
            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags flagOut = 0;
            OSStatus decodeStatus = VTDecompressionSessionDecodeFrame(_decodeSession,
                                                                      sampleBuffer,
                                                                      flags,
                                                                      &outputPixelBuffer,
                                                                      &flagOut);
            if (decodeStatus == kVTInvalidSessionErr) {
                [self freeDecodeSession];
                [self setupDecompressionSession];
            }
            CFRelease(sampleBuffer);
            sampleBuffer = NULL;
        }
        CFRelease(blockBuffer);
        blockBuffer = NULL;
    }
    
    if (outputPixelBuffer == NULL) {
        return nil;
    }
    
    VCYUV420PImage *image = [[VCYUV420PImage alloc] initWithWidth:decodeFrame.width height:decodeFrame.height];
    [image setPixelBuffer:outputPixelBuffer];
    
    CVPixelBufferRelease(outputPixelBuffer);
    return image;
}

- (void)decodeWithFrame:(id<VCFrameTypeProtocol>)frame {
    if (self.currentState.unsignedIntegerValue != VCBaseDecoderStateRunning) return;
    id<VCImageTypeProtocol> image = [self decode:frame];
    if (image != NULL) {
        if (self.delegate && [self.delegate respondsToSelector:@selector(decoder:didProcessImage:)]) {
            [self.delegate decoder:self didProcessImage:image];
        }
    }
}

- (void)decodeFrame:(id<VCFrameTypeProtocol>)frame completion:(void (^)(id<VCImageTypeProtocol>))block {
    if (self.currentState.unsignedIntegerValue != VCBaseDecoderStateRunning) return;
    
    id<VCImageTypeProtocol> image = [self decode:frame];
    if (image != NULL) {
        if (block) {
            block(image);
        }
    }
}

@end
