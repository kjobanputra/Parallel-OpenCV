#include <stdio.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <driver_functions.h>

#include "CycleTimer.h"
#include "config.h"

#include <chrono>

#define BLOCK_WIDTH 32
#define BLOCK_HEIGHT 32
#define THREADS_PER_BLOCK (BLOCK_WIDTH * BLOCK_HEIGHT)

#define SHARED_PADDING (WINDOW_SIZE / 2) + (GRAD_SIZE / 2) 

#define dceil(a, b) ((a) % (b) != 0 ? ((a) / (b) + 1) : ((a) / (b)))

#define INSIDE (1.0f)
#define OUTSIDE (0.0f)
#define UNDEFINED (-1.0f)

#define MAX_F(a, b) ((a) > (b) ? (a) : (b))
#define MIN_F(a, b) ((a) < (b) ? (a) : (b))

using namespace std::chrono;

// Constant pointer to the image data
__constant__ float *image_data;
__constant__ float *image_x_grad;
__constant__ float *image_y_grad;
float *c_image_data;

// __global__
// void harrisCornerDetector_kernel(float *input, float *output, int height, int width) {
//     const int shared_size = THREADS_PER_BLOCK + 2 * THREADS_PER_BLOCK * SHARED_PADDING + SHARED_PADDING * SHARED_PADDING;
//     __shared__ float image_dx[shared_size];
//     __shared__ float image_dy[shared_size];

//     uint pixelY = blockIdx.y * blockDim.y + threadIdx.y;
//     uint pixelX = blockIdx.x * blockDim.x + threadIdx.x;
// }

__global__
void gaussian_kernel(float *image, float *output, int height, int width, int pheight, int pwidth) {
    // TODO:
}

__global__
void sobel_x_kernel(int height, int width, int pheight, int pwidth) {
    const uint pixelY = blockIdx.y * blockDim.y + threadIdx.y;
    const uint pixelX = blockIdx.x * blockDim.x + threadIdx.x;
    const uint ppixelY = pixelY + pheight;
    const uint ppixelX = pixelX + pwidth;
    

    if(pixelX < width && pixelY < height) {
        float value = 0.0f; 
        // left horizontal sweep
        for(int i = -1; i <= 1; i++) {
            const float weight = i != 0 ? 0.125f : 0.25f;
            value += weight * image_data[(ppixelY + i) * (2 * pwidth + width) + ppixelX - 1];
        }

        // right horizontal sweep
        for(int i = -1; i <= 1; i++) {
            const float weight = i != 0 ? -0.125f : -0.25f;
            value += weight * image_data[(ppixelY + i) * (2 * pwidth + width) + ppixelX + 1];
        }
        image_x_grad[pixelY * width + pixelX] = value;
    }
}

__global__
void sobel_y_kernel(int height, int width, int pheight, int pwidth) {
    const uint pixelY = blockIdx.y * blockDim.y + threadIdx.y;
    const uint pixelX = blockIdx.x * blockDim.x + threadIdx.x;
    const uint ppixelY = pixelY + pheight;
    const uint ppixelX = pixelX + pwidth;

    if(pixelX < width && pixelY < height) {
        float value = 0.0f; 
        // left horizontal sweep
        for(int i = -1; i <= 1; i++) {
            const float weight = i != 0 ? 0.125f : 0.25f;
            value += weight * image_data[(ppixelY - 1) * (2 * pwidth + width) + ppixelX + i];
        }

        // right horizontal sweep
        for(int i = -1; i <= 1; i++) {
            const float weight = i != 0 ? -0.125f : -0.25f;
            value += weight * image_data[(ppixelY + 1) * (2 * pwidth + width) + ppixelX + i];
        }
        image_y_grad[pixelY * width + pixelX] = value;
    }
}

__global__
void cornerness_kernel(int height, int width) {
    const int padding = WINDOW_PADDING_SIZE;
    const uint pixelY = blockIdx.y * blockDim.y + threadIdx.y;
    const uint pixelX = blockIdx.x * blockDim.x + threadIdx.x;
    const uint ppixelY = pixelY + padding;
    const uint ppixelX = pixelX + padding;

    if(pixelX < width && pixelY < height) {
        float gxx = 0.0f, gyy = 0.0f, gxy = 0.0f;
        for(int i = -padding; i <= padding; i++) {
            for(int j = -padding; j <= padding; j++) {
                const uint pos = (ppixelY + i) * (2 * padding + width) + ppixelX + j;
                gxx += image_x_grad[pos] * image_x_grad[pos];
                gyy += image_y_grad[pos] * image_y_grad[pos];
                gxy += image_x_grad[pos] * image_y_grad[pos];
            }
        }
        const float det = gxx * gyy - gxy * gxy;
        const float trace = gxx + gyy;
        image_data[pixelY * width + pixelX] = det - K * trace * trace;
    }
}

/* algorithm borrowed from: http://www.bmva.org/bmvc/2008/papers/45.pdf */
__global__
void non_maximum_suppression_kernel(float *cornerness, float *input, float *output, int height, int width, bool *done) {
    
}

/* input is a grayscale image of size height by width */
void harrisCornerDetectorStaged(float *pinput, float *output, int height, int width) {
    auto start_time = high_resolution_clock::now();
    const size_t padding = TOTAL_PADDING_SIZE;

    const int input_image_size = sizeof(float) * (height + 2 * padding) * (width + 2 * padding);
    const int grad_image_width = width + 2 * (padding - GRAD_PADDING_SIZE);
    const int grad_image_height = height + 2 * (padding - GRAD_PADDING_SIZE);
    const int grad_image_size = sizeof(float) * grad_image_height * grad_image_width;
    const int output_image_size = sizeof(float) * height * width;
    auto mem_start_time1 = high_resolution_clock::now();
    auto mem_end_time1 = high_resolution_clock::now();

    // Copy input arrays to the GPU
    auto mem_start_time2 = high_resolution_clock::now();
    cudaMemcpy(c_image_data, pinput, input_image_size, cudaMemcpyHostToDevice);
    auto mem_end_time2 = high_resolution_clock::now();

    const dim3 grid (dceil(width, BLOCK_WIDTH), dceil(height, BLOCK_HEIGHT));
    const dim3 threadBlock (BLOCK_WIDTH, BLOCK_HEIGHT);
    auto kernel_start_time = high_resolution_clock::now();
    sobel_x_kernel<<<grid, threadBlock>>>(grad_image_height, grad_image_width, GRAD_PADDING_SIZE, GRAD_PADDING_SIZE);
    sobel_y_kernel<<<grid, threadBlock>>>(grad_image_height, grad_image_width, GRAD_PADDING_SIZE, GRAD_PADDING_SIZE);
    //cudaDeviceSynchronize();
    cornerness_kernel<<<grid, threadBlock>>>(height, width);
    //cudaDeviceSynchronize();
    auto kernel_end_time = high_resolution_clock::now();

    // Copy result to CPU
    auto mem_start_time3 = high_resolution_clock::now();
    cudaMemcpy(output, c_image_data, output_image_size, cudaMemcpyDeviceToHost);
    auto mem_end_time3 = high_resolution_clock::now();
    auto mem_start_time4 = high_resolution_clock::now();
    auto mem_end_time4 = high_resolution_clock::now();
    auto end_time = high_resolution_clock::now();

    auto mem_total_time = duration_cast<microseconds>((mem_end_time1 - mem_start_time1) + (mem_end_time2 - mem_start_time2) + 
                                                      (mem_end_time3 - mem_start_time3) + (mem_end_time4 - mem_start_time4));
    printf("Kernel: %ld us\n", duration_cast<microseconds>(kernel_end_time - kernel_start_time).count());
    printf("Memory 1: %ld us\n", duration_cast<microseconds>(mem_end_time1 - mem_start_time1).count());
    printf("Memory 2: %ld us\n", duration_cast<microseconds>(mem_end_time2 - mem_start_time2).count());
    printf("Memory 3: %ld us\n", duration_cast<microseconds>(mem_end_time3 - mem_start_time3).count());
    printf("Memory 4: %ld us\n", duration_cast<microseconds>(mem_end_time4 - mem_start_time4).count());
    printf("Total Memory Time: %ld us\n", mem_total_time.count());
    printf("Total Time: %ld us\n", duration_cast<microseconds>(end_time - start_time).count());
}

// __global__
// void sobel_x_kernel_shared(int height, int width) {
//     __shared__ float image_shared[THREADS_PER_BLOCK + 4 * (BLOCK_HEIGHT + 1)];

//     const uint pixelY = blockIdx.y * blockDim.y + threadIdx.y;
//     const uint pixelX = blockIdx.x * blockDim.x + threadIdx.x;
//     const uint pixelSL = (blockIdx.y + 1) * BLOCK_WIDTH + blockIdx.x + 1;

//     if(pixelX < width && pixelY < height) {
//         // Load image value into shared memory
//         image_shared[pixelSL] = image_data[pixelY * width + pixelX];
//         if(threadIdx.x == 0 && threadIdy.y == 0) {
//             image_shared[]
//         }
//         float value = 0.0f; 
//         // left horizontal sweep
//         for(int i = -1; i <= 1; i++) {
//             const float weight = i != 0 ? 0.125f : 0.25f;
//             const int x = MAX_F(pixelX - 1, 0);
//             const int bx = MAX_F(threadIdx.x - 1, 0);
//             const int y = MAX_F(pixelY + i, 0);
//             y = MIN_F(y, height);
//             const int by = MAX_F(threadIdx.y + i, 0);
//             by = MIN_F(threadIdx.y + i, BLOCK_WIDTH);
//             // Nearest padding
//             const float image_value;
//             if(pixelX == 0 || pixelY + i >= height || pixelY + i < 0) {
//                 image_value = image_shared[blockIdx.y * BLOCK_WIDTH + blockIdx.x];
//             }
//             else if(blockIdx.x == 0 || blockIdx.y + i < 0 || blockIdx.y + i >= BLOCK_HEIGHT) {
//                 image_value = image_data[y * width + x];
//             }
//             else {
//                 image_value = image_shared[x];
//             }
//             value += weight * image_value;
//         }

//         // right horizontal sweep
//         for(int i = -1; i <= 1; i++) {
//             const float weight = i != 0 ? -0.125f : -0.25f;
//             // Nearest padding
//             const float image_value;
//             if(pixelX + 1 >= width || pixelY + i >= height || pixelY + i < 0) {
//                 // TODO: technically use the "nearest", but since this is a 3x3 kernel
//                 // the nearest is always the current pixel under consideration.
//                 image_value = image_shared[blockIdx.y * BLOCK_WIDTH + blockIdx.x];
//             }
//             else if(blockIdx.x + 1 >= BLOCK_WIDTH || blockIdx.y + i < 0 || blockIdx.y + i >= BLOCK_HEIGHT) {
//                 image_value = image_data[(pixelY + i) * width + pixelX + 1];
//             }
//             else {
//                 image_value = image_shared[(blockIdx.y + i) * BLOCK_WIDTH + blockIdx.x + 1];
//             }
//             value += weight * image_value;
//         }
//         // Global write
//         image_x_grad[pixelY * width + pixelX] = value;
//     }
// }

// __global__
// void sobel_x_kernel_shared(int height, int width) {
//     __shared__ float image_shared[THREADS_PER_BLOCK];

//     const uint pixelY = blockIdx.y * blockDim.y + threadIdx.y;
//     const uint pixelX = blockIdx.x * blockDim.x + threadIdx.x;
//     const uint pixelSL = blockIdx.y * BLOCK_WIDTH + blockIdx.x;

//     if(pixelX < width && pixelY < height) {
//         image_shared[pixelSL] = image_data[pixelY * width + pixelX];
//         float value = 0.0f; 
//         // left horizontal sweep
//         for(int i = -1; i <= 1; i++) {
//             const float weight = i != 0 ? 0.125f : 0.25f;
//             const int x = MAX_F(pixelX - 1, 0);
//             const int bx = MAX_F(threadIdx.x - 1, 0);
//             const int y = MAX_F(pixelY + i, 0);
//             y = MIN_F(y, height);
//             const int by = MAX_F(threadIdx.y + i, 0);
//             by = MIN_F(threadIdx.y + i, BLOCK_WIDTH);
//             // Nearest padding
//             const float image_value;
//             if(pixelX == 0 || pixelY + i >= height || pixelY + i < 0) {
//                 image_value = image_shared[blockIdx.y * BLOCK_WIDTH + blockIdx.x];
//             }
//             else if(blockIdx.x == 0 || blockIdx.y + i < 0 || blockIdx.y + i >= BLOCK_HEIGHT) {
//                 image_value = image_data[y * width + x];
//             }
//             else {
//                 image_value = image_shared[x];
//             }
//             value += weight * image_value;
//         }

//         // right horizontal sweep
//         for(int i = -1; i <= 1; i++) {
//             const float weight = i != 0 ? -0.125f : -0.25f;
//             // Nearest padding
//             const float image_value;
//             if(pixelX + 1 >= width || pixelY + i >= height || pixelY + i < 0) {
//                 // TODO: technically use the "nearest", but since this is a 3x3 kernel
//                 // the nearest is always the current pixel under consideration.
//                 image_value = image_shared[blockIdx.y * BLOCK_WIDTH + blockIdx.x];
//             }
//             else if(blockIdx.x + 1 >= BLOCK_WIDTH || blockIdx.y + i < 0 || blockIdx.y + i >= BLOCK_HEIGHT) {
//                 image_value = image_data[(pixelY + i) * width + pixelX + 1];
//             }
//             else {
//                 image_value = image_shared[(blockIdx.y + i) * BLOCK_WIDTH + blockIdx.x + 1];
//             }
//             value += weight * image_value;
//         }
//         // Global write
//         image_x_grad[pixelY * width + pixelX] = value;
//     }
// }

void init_cuda() {
    cudaSetDevice(0);
    cudaFree(0);

    // Allocate space for our input images and intermediate results
    float *d_image_data;
    float *d_image_x_grad;
    float *d_image_y_grad;
    cudaMalloc(&d_image_data, sizeof(float) * MAX_IMAGE_HEIGHT * MAX_IMAGE_WIDTH);
    cudaMalloc(&d_image_x_grad, sizeof(float) * MAX_IMAGE_HEIGHT * MAX_IMAGE_WIDTH);
    cudaMalloc(&d_image_y_grad, sizeof(float) * MAX_IMAGE_HEIGHT * MAX_IMAGE_WIDTH);
    cudaMemcpyToSymbol(image_data, &d_image_data, sizeof(float *));
    cudaMemcpyToSymbol(image_x_grad, &d_image_x_grad, sizeof(float *));
    cudaMemcpyToSymbol(image_y_grad, &d_image_y_grad, sizeof(float *));
    c_image_data = d_image_data;
}

void
printCudaInfo() {

    // for fun, just print out some stats on the machine

    int deviceCount = 0;
    cudaError_t err = cudaGetDeviceCount(&deviceCount);

    printf("---------------------------------------------------------\n");
    printf("Found %d CUDA devices\n", deviceCount);

    for (int i=0; i<deviceCount; i++) {
        cudaDeviceProp deviceProps;
        cudaGetDeviceProperties(&deviceProps, i);
        printf("Device %d: %s\n", i, deviceProps.name);
        printf("   SMs:        %d\n", deviceProps.multiProcessorCount);
        printf("   Global mem: %.0f MB\n",
               static_cast<float>(deviceProps.totalGlobalMem) / (1024 * 1024));
        printf("   CUDA Cap:   %d.%d\n", deviceProps.major, deviceProps.minor);
    }
    printf("---------------------------------------------------------\n");
}