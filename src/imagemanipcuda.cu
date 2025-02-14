// imagemanipcuda.cu
// Andrew S. Ng
// Started: 2020-12-01
// Updated: 2020-12-07
//
// For CS 301 Fall 2020
// Source for image processing operations in CUDA

#include "imagemanipcuda.h"
#include "mat2.h"
#include "vec2.h"

#define _USE_MATH_DEFINES
#include <cmath>
#include <cstddef>
using std::size_t;
#include <algorithm>
using std::max;
using std::min;
using std::swap;
#include <vector>
using std::vector;
using FilterType1D = vector<float>;
using FilterType2D = vector<vector<float>>;


// bilinearInterp
// Performs bilinear interpolation to find Pixel value at float coords on given image.
// Executed on device only.
__device__ void bilinearInterp(float * input, float x, float y, int width, int height, float * color)
{
    int x0 = int(x) < width-1 ? int(x) : width-1;
    int y0 = int(y) < height-1 ? int(y) : height-1;
    int x1 = x0+1 < width-1 ? x0+1 : width-1;
    int y1 = y0+1 < height-1 ? y0+1 : height-1;
    float * c00 = &input[y0 * width*3 + x0*3];
    float * c01 = &input[y1 * width*3 + x0*3];
    float * c10 = &input[y0 * width*3 + x1*3];
    float * c11 = &input[y1 * width*3 + x1*3];
    float biasX = x - x0;
    float biasY = y - y0;

    color[0] = (1.0f - biasY) * ((1.0f - biasX) * c00[0] + biasX * c10[0]) + biasY * ((1.0f - biasX) * c01[0] + biasX * c11[0]);
    color[1] = (1.0f - biasY) * ((1.0f - biasX) * c00[1] + biasX * c10[1]) + biasY * ((1.0f - biasX) * c01[1] + biasX * c11[1]);
    color[2] = (1.0f - biasY) * ((1.0f - biasX) * c00[2] + biasX * c10[2]) + biasY * ((1.0f - biasX) * c01[2] + biasX * c11[2]);
}


// transformKernel
// CUDA kernel that performs inverse transformation and bilinear
//   interp sampling for each pixel, storing values in output.
__global__ void transformKernel(float * input, float * output, float minX, float minY, 
                                float dx, float dy, int iWidth, int iHeight, int oWidth, int oHeight, float * mat)
{                            
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x < 0 || x > oWidth-1 || y < 0 || y > oHeight-1)
        return;

    // "minX + x * dx" finds floating-point coordinates of pixels in output space
    float tx = mat[0] * (minX + x * dx) + mat[1] * (minY + y * dy);    
    float ty = mat[2] * (minX + x * dx) + mat[3] * (minY + y * dy);

    if (-0.5f <= tx && tx <= float(iWidth) - 0.5f &&
        -0.5f <= ty && ty <= float(iHeight) - 0.5f)
    {
        int out = (oHeight-1-y) * oWidth*3 + x*3;
        float color[3];
        bilinearInterp(input, tx+0.5f, iHeight-1-ty+0.5f, iWidth, iHeight, color);
        output[out+0] = color[0];
        output[out+1] = color[1];
        output[out+2] = color[2];
    }
}    


// transformCuda
// Helper function to transform image using given transformation matrix.
// Uses CUDA for GPU acceleration.
Image transformCuda(const Image & image, Mat2 transform)
{
    // Original 4 corners of image
    float maxX = float(image.width() - 1);
    float maxY = float(image.height() - 1);
    Vec2 topLeft(0.0f, maxY);
    Vec2 topRight(maxX, maxY);
    Vec2 botLeft(0.0f, 0.0f);
    Vec2 botRight(maxX, 0.0f);

    // Find where the 4 corners move to
    topLeft = transform * topLeft;
    topRight = transform * topRight;
    botLeft = transform * botLeft;
    botRight = transform * botRight;

    // Construct transformed Image using 4 corners
    float newMaxX = max({ topLeft.x, topRight.x, botLeft.x, botRight.x });
    float newMinX = min({ topLeft.x, topRight.x, botLeft.x, botRight.x });
    float newMaxY = max({ topLeft.y, topRight.y, botLeft.y, botRight.y });
    float newMinY = min({ topLeft.y, topRight.y, botLeft.y, botRight.y });
    Image transformed(newMaxX - newMinX + 1, newMaxY - newMinY + 1);

    // Distance between pixels in output space
    float dx = (newMaxX - newMinX) / transformed.width();
    float dy = (newMaxY - newMinY) / transformed.height();

    // Perform gaussian blur on source image if downsampling
    Image source;
    float sizeRatio = float(transformed.width() * transformed.height()) / (image.width() * image.height());
    if (sizeRatio < 0.25)
        source = gaussianBlurSeparableCuda(image, 9, 3);
    else
        source = image;

    Mat2 transformInv = transform.inverse();

    // Move source image onto device
    float * input;
    cudaMalloc(&input, source.width() * source.height() * sizeof(float) * 3);
    cudaMemcpy(input, &source(0, 0), source.width() * source.height() * sizeof(float) * 3, cudaMemcpyHostToDevice);

    // Allocate device memory for output image
    float * output;
    cudaMalloc(&output, transformed.width() * transformed.height() * sizeof(float) * 3);

    // Move inverse transform matrix onto device
    float * mat;
    cudaMalloc(&mat, 4 * sizeof(float));
    cudaMemcpy(mat, &transformInv[0][0], 4 * sizeof(float), cudaMemcpyHostToDevice);

    // Call kernel
    dim3 blockSize(16, 16);
    dim3 gridSize((transformed.width()  + blockSize.x - 1) / blockSize.x,
                  (transformed.height() + blockSize.y - 1) / blockSize.y);

    transformKernel<<<gridSize, blockSize>>>(input, output, newMinX, newMinY, dx, dy,
        source.width(), source.height(), transformed.width(), transformed.height(), mat);

    // Move output image back to host
    cudaDeviceSynchronize();
    cudaMemcpy(&transformed(0, 0), output, transformed.width() * transformed.height() * sizeof(float) * 3, cudaMemcpyDeviceToHost);

    // Free allocated memory
    cudaFree(input);
    cudaFree(output);
    cudaFree(mat);

    return transformed;
}


// rotateCuda
// (see header.)
Image rotateCuda(const Image & image, float angleDeg)
{
    float angleRad = M_PI * angleDeg / 180.0f;
    float cosAngle = cosf(angleRad);
    float sinAngle = sinf(angleRad);
    Mat2 rotMat = {
        { cosAngle, -sinAngle },
        { sinAngle,  cosAngle }
    };

    return transformCuda(image, rotMat);   
}


// scaleCuda
// (see header.)
Image scaleCuda(const Image & image, float scaleX, float scaleY)
{
    Mat2 scaleMat = {
        { scaleX, 0.0f   },
        { 0.0f,   scaleY }
    };

    return transformCuda(image, scaleMat);
}


// skewCuda
// (see header.)
Image skewCuda(const Image & image, float skewX, float skewY)
{
    Mat2 skewMat = {
        { 1.0f,  skewX },
        { skewY, 1.0f  }
    };

    return transformCuda(image, skewMat);
}


// clamp
// Clamps x value between a and b.
// Executed on device only.
__device__ int clamp(int x, int a, int b)
{
    if (b < a)
    {
        int tmp = a;
        a = b;
        b = tmp;
    }
    if (x < a)
        return a;
    if (x > b)
        return b;
    return x;
}


// convolve2Dkernel
// CUDA kernel that runs 2D filter on each pixel, storing values in output.
__global__ void convolve2DKernel(float * input, float * output, int width, int height, float * filter, int size)
{
    int r = (size - 1) / 2;
    float sumR = 0.0f;
    float sumG = 0.0f;
    float sumB = 0.0f;
    
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x < 0 || x > width-1 || y < 0 || y > height-1)
        return;

    for (int j = y-r; j <= y+r; ++j)
    {
        for (int i = x-r; i <= x+r; ++i)
        {
            float weight = filter[(j-y+r) * size + (i-x+r)];
            int ci = clamp(i, 0, width-1);
            int cj = clamp(j, 0, height-1);

            sumR += input[cj * width*3 + ci*3 + 0] * weight;
            sumG += input[cj * width*3 + ci*3 + 1] * weight;
            sumB += input[cj * width*3 + ci*3 + 2] * weight;
        }
    }

    output[y * width*3 + x*3 + 0] = sumR;
    output[y * width*3 + x*3 + 1] = sumG;
    output[y * width*3 + x*3 + 2] = sumB;
}


// printFilter
// CUDA kernel that prints given filter for debugging purposes.
__global__ void printFilter(float * filter, int size)
{
    int x = 0;
    int y = 0;
    int r = (size - 1) / 2;
    for (int j = y-r; j <= y+r; ++j)
    {
        for (int i = x-r; i <= x+r; ++i)
        {
            float weight = filter[(i-x+r) * size + (j-y+r)];
            printf("%f ", weight);
        }
        printf("\n");
    }
    printf("\n");
}


// convolveImage2DCuda
// Helper function to convolve image using given 2D filter.
// Uses CUDA for GPU acceleration.
Image convolveImage2DCuda(const Image & image, const FilterType1D & filter)
{
    Image convolved(image.width(), image.height());

    int size = sqrt(filter.size());

    // Move source image onto device
    float * input;
    cudaMalloc(&input, image.width() * image.height() * sizeof(float) * 3);
    cudaMemcpy(input, &image(0, 0), image.width() * image.height() * sizeof(float) * 3, cudaMemcpyHostToDevice);

    // Allocate device memory for output image
    float * output;
    cudaMalloc(&output, convolved.width() * convolved.height() * sizeof(float) * 3);

    // Move 2D filter onto device
    float * filter2D;
    cudaMalloc(&filter2D, size * size * sizeof(float));
    cudaMemcpy(filter2D, &filter[0], size * size * sizeof(float), cudaMemcpyHostToDevice);

    // Call kernel
    dim3 blockSize(16, 16);
    dim3 gridSize((convolved.width()  + blockSize.x - 1) / blockSize.x,
                  (convolved.height() + blockSize.y - 1) / blockSize.y);

    convolve2DKernel<<<gridSize, blockSize>>>(input, output, image.width(), image.height(), filter2D, size);

    // Move output image back to host
    cudaDeviceSynchronize();
    cudaMemcpy(&convolved(0, 0), output, convolved.width() * convolved.height() * sizeof(float) * 3, cudaMemcpyDeviceToHost);

    // Free allocated memory
    cudaFree(input);
    cudaFree(output);
    cudaFree(filter2D);

    return convolved;
}


// convolve1DKernel
// CUDA kernel that runs 1D filter on each pixel, storing values in output.
// bool vert specifies if filter is used vertically or horizontally.
__global__ void convolve1DKernel(float * input, float * output, int width, int height, float * filter, int size, bool vert)
{
    int r = (size - 1) / 2;
    float sumR = 0.0f;
    float sumG = 0.0f;
    float sumB = 0.0f;
    
    int x = blockIdx.x * blockDim.x + threadIdx.x;
    int y = blockIdx.y * blockDim.y + threadIdx.y;
    if (x < 0 || x > width-1 || y < 0 || y > height-1)
        return;

    if (vert)
    {
        int tmp = x;
        x = y;
        y = tmp;
    }
    for (int i = x-r; i <= x+r; ++i)
    {
        float weight = filter[(i-x+r)];
        int ci = clamp(i, 0, width-1);
        if (vert)
        {
            ci = clamp(i, 0, height-1);
            sumR += input[ci * width*3 + y*3 + 0] * weight;
            sumG += input[ci * width*3 + y*3 + 1] * weight;
            sumB += input[ci * width*3 + y*3 + 2] * weight;
        }
        else
        {
            ci = clamp(i, 0, width-1);
            sumR += input[y * width*3 + ci*3 + 0] * weight;
            sumG += input[y * width*3 + ci*3 + 1] * weight;
            sumB += input[y * width*3 + ci*3 + 2] * weight;
        }
    }

    if (vert)
    {
        output[x * width*3 + y*3 + 0] = sumR;
        output[x * width*3 + y*3 + 1] = sumG;
        output[x * width*3 + y*3 + 2] = sumB;
    }
    else
    {
        output[y * width*3 + x*3 + 0] = sumR;
        output[y * width*3 + x*3 + 1] = sumG;
        output[y * width*3 + x*3 + 2] = sumB;
    }
}


// convolveImage1DCuda
// Helper function to convolve image using given separable 1D filter.
// Uses CUDA for GPU acceleration.
Image convolveImage1DCuda(const Image & image, const FilterType1D & filter)
{
    Image convolved(image.width(), image.height());

    int size = filter.size();
    
    // Move source image onto device
    float * input;
    cudaMalloc(&input, image.width() * image.height() * sizeof(float) * 3);
    cudaMemcpy(input, &image(0, 0), image.width() * image.height() * sizeof(float) * 3, cudaMemcpyHostToDevice);

    // Allocate device memory for output image
    float * output;
    cudaMalloc(&output, convolved.width() * convolved.height() * sizeof(float) * 3);
    
    // Move 1D filter onto device
    float * filter1D;
    cudaMalloc(&filter1D, size * sizeof(float));
    cudaMemcpy(filter1D, &filter[0], size * sizeof(float), cudaMemcpyHostToDevice);
    
    dim3 blockSize(16, 16);
    dim3 gridSize((convolved.width()  + blockSize.x - 1) / blockSize.x,
    (convolved.height() + blockSize.y - 1) / blockSize.y);
    
    // Horizontal convolution from image -> middle
    convolve1DKernel<<<gridSize, blockSize>>>(input, output, image.width(), image.height(), filter1D, size, false);

    cudaDeviceSynchronize();

    // Vertical convolution from middle -> convolved
    convolve1DKernel<<<gridSize, blockSize>>>(output, input, convolved.width(), convolved.height(), filter1D, size, true);
    
    cudaDeviceSynchronize();
    
    // Move output image back to host
    cudaMemcpy(&convolved(0, 0), input, convolved.width() * convolved.height() * sizeof(float) * 3, cudaMemcpyDeviceToHost);

    // Free allocated memory
    cudaFree(input);
    cudaFree(output);
    cudaFree(filter1D);

    return convolved;
}


// boxBlurCuda
// (see header.)
Image boxBlurCuda(const Image & image, int radius)
{
    int size = 2 * radius + 1;
    float weight = 1.0f / (size * size);
    FilterType1D boxFilter(size*size, weight);

    return convolveImage2DCuda(image, boxFilter);
}


// boxBlurSeparableCuda
// (see header.)
Image boxBlurSeparableCuda(const Image & image, int radius)
{
    int size = 2 * radius + 1;
    float weight = 1.0f / size;
    FilterType1D boxFilter(size, weight);

    return convolveImage1DCuda(image, boxFilter);
}


// gaussianBlurCuda
// (see header.)
Image gaussianBlurCuda(const Image & image, int radius, float stddev)
{
    int size = 2 * radius + 1;
    float s = 2 * stddev * stddev;
    FilterType1D gaussianFilter(size*size, 0.0f);
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            float x2 = x - radius;
            float y2 = y - radius;
            float G = expf(-(x2*x2 + y2*y2) / s) / (M_PI * s);
            gaussianFilter[y*size+x] = G;
        }
    }

    return convolveImage2DCuda(image, gaussianFilter);
}


// gaussianBlurSeparableCuda
// (see header.)
Image gaussianBlurSeparableCuda(const Image & image, int radius, float stddev)
{
    int size = 2 * radius + 1;
    float s = 2 * stddev * stddev;
    FilterType1D gaussianFilter(size, 0.0f);
    for (int x = 0; x < size; ++x)
    {
        float x2 = x - radius;
        float G = expf(-(x2 * x2) / s) / sqrtf(M_PI * s);
        gaussianFilter[x] = G;
    }

    return convolveImage1DCuda(image, gaussianFilter);
}

