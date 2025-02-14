// imagemanip.cpp
// Andrew S. Ng
// Started: 2020-11-12
// Updated: 2020-12-07
//
// For CS 301 Fall 2020
// Source for image processing operations

#include "imagemanip.h"
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
Image::Pixel bilinearInterp(const Image & image, float x, float y)
{
    // Find coordinates of 4 surrounding pixels
    int x0 = min(int(x), image.width() - 1);
    int y0 = min(int(y), image.height() - 1);
    int x1 = min(x0 + 1, image.width() - 1);
    int y1 = min(y0 + 1, image.height() - 1);

    // Get Pixel values from the 4 pixels
    Image::Pixel c00 = image.getColor(x0, y0);
    Image::Pixel c01 = image.getColor(x0, y1);
    Image::Pixel c10 = image.getColor(x1, y0);
    Image::Pixel c11 = image.getColor(x1, y1);

    // Interpolation biases from float coordinates
    float biasX = x - x0;
    float biasY = y - y0;

    // Linear interpolation computations for resulting Pixel
    Image::Pixel result;
    result.r = (1.0f - biasY) * ((1.0f - biasX) * c00.r + biasX * c10.r) + biasY * ((1.0f - biasX) * c01.r + biasX * c11.r);
    result.g = (1.0f - biasY) * ((1.0f - biasX) * c00.g + biasX * c10.g) + biasY * ((1.0f - biasX) * c01.g + biasX * c11.g);
    result.b = (1.0f - biasY) * ((1.0f - biasX) * c00.b + biasX * c10.b) + biasY * ((1.0f - biasX) * c01.b + biasX * c11.b);

    return result;
}


// transform
// Helper function to transform image using given transformation matrix.
Image transform(const Image & image, Mat2 transform)
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
        source = gaussianBlurSeparable(image, 9, 3);
    else
        source = image;

    Mat2 transformInv = transform.inverse();

    // For each output pixel, find sample position using inverse transform,
    // then sample and set color value using bilinear interp.
    for (int y = 0; y < transformed.height(); ++y)
    {
        for (int x = 0; x < transformed.width(); ++x)
        {
            // "newMinX + x * dx" finds floating-point coordinates of pixels in output space
            Vec2 samplePos = transformInv * Vec2(newMinX + x * dx, newMinY + y * dy);

            if (-0.5f <= samplePos.x && samplePos.x <= float(source.width()) - 0.5f &&
                -0.5f <= samplePos.y && samplePos.y <= float(source.height()) - 0.5f)
            {
                Image::Pixel color = bilinearInterp(source, samplePos.x + 0.5f, float(source.height() - 1) - samplePos.y + 0.5f);
                transformed.setColor(x, transformed.height() - y - 1, color);
            }
        }
    }
    return transformed;
}


// rotate
// (see header.)
Image rotate(const Image & image, float angleDeg)
{
    float angleRad = M_PI * angleDeg / 180.0f;
    float cosAngle = cosf(angleRad);
    float sinAngle = sinf(angleRad);
    Mat2 rotMat = {
        { cosAngle, -sinAngle },
        { sinAngle,  cosAngle }
    };

    return transform(image, rotMat);   
}


// scale
// (see header.)
Image scale(const Image & image, float scaleX, float scaleY)
{
    Mat2 scaleMat = {
        { scaleX, 0.0f   },
        { 0.0f,   scaleY }
    };

    return transform(image, scaleMat);
}


// skew
// (see header.)
Image skew(const Image & image, float skewX, float skewY)
{
    Mat2 skewMat = {
        { 1.0f,  skewX },
        { skewY, 1.0f  }
    };

    return transform(image, skewMat);
}


// convolvePixel2D
// Runs 2D filter on a given pixel, returning new value.
Image::Pixel convolvePixel2D(const Image & image, const FilterType2D & filter, int x, int y)
{
    int r = (filter.size() - 1) / 2;
    Image::Pixel sum;
    for (int j = y-r; j <= y+r; ++j)
    {
        for (int i = x-r; i <= x+r; ++i)
        {
            float weight = filter[i-x+r][j-y+r];

            int clampI = max(0, min(i, image.width() - 1));
            int clampJ = max(0, min(j, image.height() - 1));

            Image::Pixel val = image.getColor(clampI, clampJ);
            sum.r += val.r * weight;
            sum.g += val.g * weight;
            sum.b += val.b * weight;
        }
    }

    return sum;
}


// convolveImage2D
// Helper function to convolve image using given 2D filter.
Image convolveImage2D(const Image & image, const FilterType2D & filter)
{
    Image convolved(image.width(), image.height());

    for (int y = 0; y < convolved.height(); ++y)
    {
        for (int x = 0; x < convolved.width(); ++x)
        {
            convolved.setColor(x, y, convolvePixel2D(image, filter, x, y));
        }
    }

    return convolved;
}


// convolvePixel1D
// Runs 1D filter on a given pixel, returning new value.
// bool vert specifies if filter is used vertically or horizontally.
Image::Pixel convolvePixel1D(const Image & image, const FilterType1D & filter, int x, int y, bool vert)
{
    int r = (filter.size() - 1) / 2;
    Image::Pixel sum;

    if (vert)
        swap(x, y);

    for (int i = x-r; i <= x+r; ++i)
    {
        float weight = filter[i-x+r];

        int clampI;
        Image::Pixel val;
        if (vert)
        {
            clampI = max(0, min(i, image.height() - 1));
            val = image.getColor(y, clampI);
        }
        else
        {
            clampI = max(0, min(i, image.width() - 1));
            val = image.getColor(clampI, y);
        }
        sum.r += val.r * weight;
        sum.g += val.g * weight;
        sum.b += val.b * weight;
    }

    return sum;
}


// convolveImageSeparable
// Helper function to convolve image using given separable 1D filter.
Image convolveImageSeparable(const Image & image, const FilterType1D & filter)
{
    // Horizontal convolution from image -> middle
    Image middle(image.width(), image.height());
    for (int y = 0; y < middle.height(); ++y)
    {
        for (int x = 0; x < middle.width(); ++x)
        {
            middle.setColor(x, y, convolvePixel1D(image, filter, x, y, false));
        }
    }

    // Vertical convolution from middle -> convolved
    Image convolved(middle.width(), middle.height());
    for (int y = 0; y < convolved.height(); ++y)
    {
        for (int x = 0; x < convolved.width(); ++x)
        {
            convolved.setColor(x, y, convolvePixel1D(middle, filter, x, y, true));
        }
    }

    return convolved;
}


// boxBlur
// (see header.)
Image boxBlur(const Image & image, int radius)
{
    int size = 2 * radius + 1;
    float weight = 1.0f / (size * size);
    FilterType2D boxFilter(size, FilterType1D(size, weight));

    return convolveImage2D(image, boxFilter);
}


// boxBlurSeparable
// (see header.)
Image boxBlurSeparable(const Image & image, int radius)
{
    int size = 2 * radius + 1;
    float weight = 1.0f / size;
    FilterType1D boxFilter(size, weight);

    return convolveImageSeparable(image, boxFilter);
}


// gaussianBlur
// (see header.)
Image gaussianBlur(const Image & image, int radius, float stddev)
{
    int size = 2 * radius + 1;
    float s = 2 * stddev * stddev;
    FilterType2D gaussianFilter(size, FilterType1D(size, 0.0f));
    for (int y = 0; y < size; ++y)
    {
        for (int x = 0; x < size; ++x)
        {
            float x2 = x - radius;
            float y2 = y - radius;
            float G = expf(-(x2*x2 + y2*y2) / s) / (M_PI * s);
            gaussianFilter[x][y] = G;
        }
    }

    return convolveImage2D(image, gaussianFilter);
}


// gaussianBlurSeparable
// (see header.)
Image gaussianBlurSeparable(const Image & image, int radius, float stddev)
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

    return convolveImageSeparable(image, gaussianFilter);
}

