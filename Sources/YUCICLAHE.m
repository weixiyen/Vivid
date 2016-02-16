//
//  YUCICLAHE.m
//  Pods
//
//  Created by YuAo on 2/16/16.
//
//

#import "YUCICLAHE.h"
#import "YUCIFilterConstructor.h"
#import <Accelerate/Accelerate.h>

NSInteger const YUCICLAHEHistogramBinCount = 256;

static NSData * YUCICLAHETransformLUTForContrastLimitedHistogram(vImagePixelCount histogram[YUCICLAHEHistogramBinCount], vImagePixelCount totalPixelCount) {
    vImagePixelCount sum = 0;
    uint8_t equalizationFunction[YUCICLAHEHistogramBinCount];
    for (NSInteger index = 0; index < YUCICLAHEHistogramBinCount; ++index) {
        sum += histogram[index];
        equalizationFunction[index] = round(sum * (YUCICLAHEHistogramBinCount - 1) / (double)totalPixelCount);
    }
    NSData *data = [NSData dataWithBytes:equalizationFunction length:YUCICLAHEHistogramBinCount * sizeof(u_int8_t)];
    return data;
}

@interface YUCICLAHE ()

@property (nonatomic,strong) CIContext *context;

@end

@implementation YUCICLAHE

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        @autoreleasepool {
            if ([CIFilter respondsToSelector:@selector(registerFilterName:constructor:classAttributes:)]) {
                [CIFilter registerFilterName:NSStringFromClass([YUCICLAHE class])
                                 constructor:[YUCIFilterConstructor constructor]
                             classAttributes:@{kCIAttributeFilterCategories: @[kCICategoryStillImage,kCICategoryVideo,kCICategoryColorAdjustment],
                                               kCIAttributeFilterDisplayName: @"Contrast Limited Adaptive Histogram Equalization"}];
            }
        }
    });
}

+ (CIKernel *)filterKernel {
    static CIKernel *kernel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *kernelString = [[NSString alloc] initWithContentsOfURL:[[NSBundle bundleForClass:self] URLForResource:NSStringFromClass([YUCICLAHE class]) withExtension:@"cikernel"] encoding:NSUTF8StringEncoding error:nil];
        kernel = [CIKernel kernelWithString:kernelString];
    });
    return kernel;
}

+ (CIColorKernel *)RGBToHSLKernel {
    static CIColorKernel *kernel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *kernelString = [[NSString alloc] initWithContentsOfURL:[[NSBundle bundleForClass:self] URLForResource:@"YUCIRGBToHSL" withExtension:@"cikernel"] encoding:NSUTF8StringEncoding error:nil];
        kernel = [CIColorKernel kernelWithString:kernelString];
    });
    return kernel;
}

+ (CIColorKernel *)HSLToRGBKernel {
    static CIColorKernel *kernel;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *kernelString = [[NSString alloc] initWithContentsOfURL:[[NSBundle bundleForClass:self] URLForResource:@"YUCIHSLToRGB" withExtension:@"cikernel"] encoding:NSUTF8StringEncoding error:nil];
        kernel = [CIColorKernel kernelWithString:kernelString];
    });
    return kernel;
}

- (CIContext *)context {
    if (!_context) {
        _context = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: CFBridgingRelease(CGColorSpaceCreateWithName(kCGColorSpaceSRGB))}];
    }
    return _context;
}

- (NSNumber *)inputClipLimit {
    if (!_inputClipLimit) {
        _inputClipLimit = @(1.0);
    }
    return _inputClipLimit;
}

- (CIVector *)inputTileGridSize {
    if (!_inputTileGridSize) {
        _inputTileGridSize = [CIVector vectorWithX:8 Y:8];
    }
    return _inputTileGridSize;
}

- (CIImage *)outputImage {
    /* Convert to HSL */
    CIImage *inputImage = [[YUCICLAHE RGBToHSLKernel] applyWithExtent:self.inputImage.extent arguments:@[self.inputImage]];
    
    /* Prepare */
    NSInteger tileGridSizeX = self.inputTileGridSize.X;
    NSInteger tileGridSizeY = self.inputTileGridSize.Y;
    
    CIImage *inputImageForLUT;
    
    if ((NSInteger)inputImage.extent.size.width % tileGridSizeX == 0 &&
        (NSInteger)inputImage.extent.size.height % tileGridSizeY == 0) {
        inputImageForLUT = inputImage;
    } else {
        NSInteger dY = tileGridSizeY - ((NSInteger)inputImage.extent.size.height % tileGridSizeY);
        NSInteger dX = tileGridSizeX - ((NSInteger)inputImage.extent.size.width % tileGridSizeX);
        
#warning BORDER_REFLECT_101
        inputImageForLUT = [self.inputImage.imageByClampingToExtent imageByCroppingToRect:CGRectMake(self.inputImage.extent.origin.x, self.inputImage.extent.origin.y, self.inputImage.extent.size.width + dX, self.inputImage.extent.size.height + dY)];
    }
    
    CGSize tileSize = CGSizeMake(inputImageForLUT.extent.size.width/tileGridSizeX, inputImageForLUT.extent.size.height/tileGridSizeY);
    
    NSInteger clipLimit = 0;
    if (self.inputClipLimit.doubleValue > 0.0) {
        clipLimit = (NSInteger)(self.inputClipLimit.doubleValue * tileSize.width * tileSize.height / YUCICLAHEHistogramBinCount);
        clipLimit = MAX(clipLimit, 1);
    }
    
    /* Create LUTs */
    NSMutableData *LUTsData = [[NSMutableData alloc] init];
    
    for (NSInteger tileIndex = 0; tileIndex < tileGridSizeX * tileGridSizeY; ++tileIndex) {
        NSInteger colum = tileIndex % tileGridSizeX;
        NSInteger row = tileIndex / tileGridSizeX;
        
        CIImage *tile = [inputImageForLUT imageByCroppingToRect:CGRectMake(inputImageForLUT.extent.origin.x + colum * tileSize.width,
                                                                           inputImageForLUT.extent.origin.y + row * tileSize.height,
                                                                           tileSize.width,
                                                                           tileSize.height)];
     
        ptrdiff_t rowBytes = tile.extent.size.width * 4; // ARGB has 4 components
        uint8_t *byteBuffer = calloc(rowBytes * tile.extent.size.height, sizeof(uint8_t)); // Buffer to render into
        [self.context render:tile
                    toBitmap:byteBuffer
                    rowBytes:rowBytes
                      bounds:tile.extent
                      format:kCIFormatARGB8
                  colorSpace:self.context.workingColorSpace];
        
        vImage_Buffer vImageBuffer;
        vImageBuffer.data = byteBuffer;
        vImageBuffer.width = tile.extent.size.width;
        vImageBuffer.height = tile.extent.size.height;
        vImageBuffer.rowBytes = rowBytes;
        
        vImagePixelCount h[YUCICLAHEHistogramBinCount];
        vImagePixelCount s[YUCICLAHEHistogramBinCount];
        vImagePixelCount l[YUCICLAHEHistogramBinCount];
        vImagePixelCount alpha[YUCICLAHEHistogramBinCount];
        vImagePixelCount *histogram[4] = {alpha, h, s, l};
        
        vImage_Error error = vImageHistogramCalculation_ARGB8888(&vImageBuffer, histogram, 0);
        free(byteBuffer);
        if (error != kvImageNoError) {
            return nil;
        }
        
        NSInteger histSize = YUCICLAHEHistogramBinCount;
        vImagePixelCount clipped = 0;
        for (NSInteger i = 0; i < histSize; ++i) {
            if(l[i] > clipLimit) {
                clipped += (l[i] - clipLimit);
                l[i] = clipLimit;
            };
        }
        
        vImagePixelCount redistBatch = clipped / histSize;
        vImagePixelCount residual = clipped - redistBatch * histSize;
        
        for (NSInteger i = 0; i < histSize; ++i) {
            l[i] += redistBatch;
        }
        
        for (NSInteger i = 0; i < residual; ++i) {
            l[i]++;
        }
        
        [LUTsData appendData:YUCICLAHETransformLUTForContrastLimitedHistogram(l, (vImagePixelCount)tileSize.width * (vImagePixelCount)tileSize.height)];
    }
    
    CIImage *LUTs = [CIImage imageWithBitmapData:LUTsData
                                     bytesPerRow:YUCICLAHEHistogramBinCount * sizeof(uint8_t)
                                            size:CGSizeMake(YUCICLAHEHistogramBinCount, tileGridSizeX * tileGridSizeY)
                                          format:kCIFormatR8
                                      colorSpace:self.context.workingColorSpace];
    
    /* Apply & Interpolation */
    CIImage *equalizedImage = [[YUCICLAHE filterKernel] applyWithExtent:inputImage.extent
                                                            roiCallback:^CGRect(int index, CGRect destRect) {
                                                                if (index == 1) {
                                                                    return LUTs.extent;
                                                                } else {
                                                                    return destRect;
                                                                }
                                                            } arguments:@[inputImage,LUTs,[CIVector vectorWithX:tileGridSizeX Y:tileGridSizeY],[CIVector vectorWithX:tileSize.width Y:tileSize.height]]];
    /* Back to RGB */
    return [[YUCICLAHE HSLToRGBKernel] applyWithExtent:equalizedImage.extent arguments:@[equalizedImage]];
}

@end