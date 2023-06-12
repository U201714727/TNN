// Tencent is pleased to support the open source community by making TNN available.
//
// Copyright (C) 2020 THL A29 Limited, a Tencent company. All rights reserved.
//
// Licensed under the BSD 3-Clause License (the "License"); you may not use this file except
// in compliance with the License. You may obtain a copy of the License at
//
// https://opensource.org/licenses/BSD-3-Clause
//
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

#include "tnn/device/cuda/acc/cuda_layer_acc.h"
#include "tnn/utils/dims_utils.h"

#include <cstdint>
#include <cuda.h>
#include <cuda_fp16.h>
#include <cuda_runtime_api.h>

namespace TNN_NS {

DECLARE_CUDA_ACC(FusedGroupNormSwish, LAYER_FUSED_GROUP_NORM_SWISH);

namespace {

inline static int getThreads(int count) {
    if (count <= 0) return 0;
    if (count <= 32) return 32;
    if (count > 256) return 512;
    count -= 1;
    count |= (count >> 1);
    count |= (count >> 2);
    count |= (count >> 4);
    return count + 1;
}

template<typename T>
struct Tuple2 {
    T v1; T v2;
    __device__ __host__ inline Tuple2<T>(const T a, const T b) : v1(a), v2(b) {}
    __device__ __host__ inline Tuple2<T>() : v1(0.), v2(0.) {}
    __device__ __host__ inline Tuple2<T>(const T& other): v1(other), v2(other) {}
    __device__ __host__ inline Tuple2<T> operator+(const Tuple2<T> &other) { return {v1 + other.v1, v2 + other.v2}; }
    __device__ __host__ inline Tuple2<T> &operator+=(const Tuple2<T> &other) { v1 += other.v1; v2 += other.v2; return *this; }
};

template <typename T>
__device__ __forceinline__ float toFloat(T x)
{
    return float(x);
}

template <typename T>
__device__ T fromFloat(float x);

template <>
__device__ __forceinline__ int8_t fromFloat<int8_t>(float x)
{
    // The order of the next two statements matters when x is a NaN,
    // because IEEE max/min return the non-NaN operand when one operand
    // is a NaN and the other is not.
    x = fmaxf(x, INT8_MIN);
    x = fminf(x, INT8_MAX);
    return __float2int_rn(x);
}

template <>
__device__ __forceinline__ __half fromFloat<__half>(float x)
{
    // The order of the next two statements matters when x is a NaN,
    // because IEEE max/min return the non-NaN operand when one operand
    // is a NaN and the other is not.
    x = fmaxf(x, INT8_MIN);
    x = fminf(x, INT8_MAX);
    return __float2half_rn(x);
}

template <>
__device__ __forceinline__ float fromFloat<float>(float x)
{
    return x;
}

template<typename T> struct GNAccType {using type = T; };
template<> struct GNAccType<__half> {using type = float; };
template<> struct GNAccType<float> {using type = float; };

__device__ inline static Tuple2<float> __shfl_down_sync(unsigned mask, Tuple2<float> var, unsigned int delta, int width) {
    auto ret = ::__shfl_down_sync(mask, *(double *)&var, delta, width);
    return *(Tuple2<float>*)&ret;
}
// __device__ inline static Tuple2<__half> __shfl_down_sync(unsigned mask, Tuple2<__half> var, unsigned int delta, int width) {
//     auto ret = __shfl_down_sync(mask, *(float*)&var, delta, width);
//     return *(Tuple2<__half>*)&ret;
// }

template<typename T, int WARP_SIZE>
struct WarpReducer { __device__ inline static T reduce(T val); };
template<typename T> struct WarpReducer<T, 32> { __device__ inline static T reduce(T val) {
    val += __shfl_down_sync(0xffffffff, val, 16, 32);
    val += __shfl_down_sync(0x0000ffff, val, 8, 16);
    val += __shfl_down_sync(0x000000ff, val, 4, 8);
    val += __shfl_down_sync(0x0000000f, val, 2, 4);
    val += __shfl_down_sync(0x00000003, val, 1, 2);
    return val;
}};
template<typename T> struct WarpReducer<T, 16> { __device__ inline static T reduce(T val) {
    val += __shfl_down_sync(0x0000ffff, val, 8, 16);
    val += __shfl_down_sync(0x000000ff, val, 4, 8);
    val += __shfl_down_sync(0x0000000f, val, 2, 4);
    val += __shfl_down_sync(0x00000003, val, 1, 2);
    return val;
}};
template<typename T> struct WarpReducer<T, 8> { __device__ inline static T reduce(T val) {
    val += __shfl_down_sync(0x000000ff, val, 4, 8);
    val += __shfl_down_sync(0x0000000f, val, 2, 4);
    val += __shfl_down_sync(0x00000003, val, 1, 2);
    return val;
}};
template<typename T> struct WarpReducer<T, 4> { __device__ inline static T reduce(T val) {
    val += __shfl_down_sync(0x0000000f, val, 2, 4);
    val += __shfl_down_sync(0x00000003, val, 1, 2);
    return val;
}};
template<typename T> struct WarpReducer<T, 2> { __device__ inline static T reduce(T val) {
    val += __shfl_down_sync(0x00000003, val, 1, 2);
    return val;
}};
template<typename T> struct WarpReducer<T, 1> { __device__ inline static T reduce(T val) { return val; }};

template<typename T> using UFunc = T(*)(T);
template<typename T> __device__ __host__ inline T idn(T val) { return val; }
template<typename T> __device__ __host__ inline T sqr(T val) { return val * val; }
template<typename T> __device__ __host__ inline Tuple2<T> idn(Tuple2<T> val) { return val; }
template<typename T> __device__ __host__ inline Tuple2<T> idn_sqr(Tuple2<T> val) { return {val.v1, val.v2 * val.v2}; }
}

template<int THREAD_PER_BLOCK, typename T, typename AccType, UFunc<AccType> ufunc>
__device__ static void reduce(const T* input, AccType* output, const int count, const float i0i8Scale, const int in_elem_step = 1) {

    static_assert(THREAD_PER_BLOCK % 32 == 0 && THREAD_PER_BLOCK >= 32, "");
    __shared__ char _sm_static[(THREAD_PER_BLOCK / 32) * sizeof(AccType)];
    AccType *ssum = reinterpret_cast<AccType*>(_sm_static);
    AccType sum = AccType(0.);

    const T* ptr = input + threadIdx.x * in_elem_step;
    const auto actual_step = THREAD_PER_BLOCK * in_elem_step;
    for (int i = threadIdx.x; i < count; i += THREAD_PER_BLOCK, ptr += actual_step) {
        T input = *ptr;
        auto value = static_cast<AccType>(input);
        sum += ufunc(value);
    }

    sum = WarpReducer<AccType, 32>::reduce(sum);
    if (threadIdx.x % 32 == 0) { ssum[threadIdx.x / 32] = sum; }
    __syncthreads();

    sum = threadIdx.x < THREAD_PER_BLOCK / 32 ? ssum[threadIdx.x] : AccType(0.);
    sum = WarpReducer<AccType, THREAD_PER_BLOCK / 32>::reduce(sum);
    if (threadIdx.x == 0) { *output = sum; }
    __syncthreads();
}


template<typename T>
__device__ void fuse_param_and_affine(const T *input, T *output, const float *gamma, const float *beta,
                                      const float i0i8Scale, const float o0i8Scale, int g,
                                      const int c_per_g, const int hw, const float eps,
                                      typename GNAccType<T>::type sum1, typename GNAccType<T>::type sum2) {
    using AccType = typename GNAccType<T>::type;
    extern __shared__ char _sm[];
    AccType* scale = reinterpret_cast<AccType*>(_sm);
    AccType* bias = scale + c_per_g;
    const int c_off = c_per_g * blockIdx.x % (c_per_g * g);
    for (int i = threadIdx.x; i < c_per_g; i += blockDim.x) {
        AccType mean = sum1 / (c_per_g * hw) ;
        AccType var = sum2 / (c_per_g * hw) - mean * mean;
        AccType k = rsqrt(var + eps) * gamma[c_off + i];
        scale[i] = k;
        bias[i] = - mean * k + beta[c_off + i];
    }
    __syncthreads();

    const auto count = c_per_g * hw;
    const auto offset = count * blockIdx.x;

    const T* in_ptr = input + offset;
    T* out_ptr = output + offset;
    for (int i = threadIdx.x; i < count; i += blockDim.x) {
        auto c_idx = i / hw;
        float out_val = toFloat(static_cast<AccType>(in_ptr[i]) * scale[c_idx] + bias[c_idx]);
        out_ptr[i] = fromFloat<T>(out_val / (1.f + expf(-out_val)));
    }
}

template<int THREAD_PER_BLOCK, typename T>
__global__ void group_norm_1pass(const T *input, T *output, const float *gamma, const float *beta,
                                 const float i0i8Scale, const float o0i8Scale,
                                 int g, const int c_per_g, const int hw, const float eps) {
    // 1 group per block, used when c_per_g * hw <= 4096
    // assert (c == g * c_per_g)
    using AccType = typename GNAccType<T>::type;

    __shared__ char _sums[sizeof(Tuple2<AccType>)];
    Tuple2<AccType> *sums = reinterpret_cast<Tuple2<AccType>*>(_sums);

    reduce<THREAD_PER_BLOCK, T, Tuple2<AccType>, idn_sqr<AccType> >(
        input + blockIdx.x * hw * c_per_g, sums, c_per_g * hw, i0i8Scale);

    fuse_param_and_affine<T>(input, output, gamma, beta, i0i8Scale, o0i8Scale, g,
                              c_per_g, hw, eps, sums[0].v1, sums[0].v2);
}

template<typename T>
static Status group_norm_v2(const T *input, T* output, const float *gamma, const float *beta,
                            const float i0i8Scale, const float o0i8Scale,
                            const int n, const int c, const int g, const int c_per_g, const int h, const int w,
                            const float eps, cudaStream_t s) {
    using AccType = typename GNAccType<T>::type;
    static std::map<int, void(*)(
        const T*, T*, const float *, const float *,
        const float, const float, int, const int, const int, const float)> group_norm_1pass_funcs = {
        {32,  group_norm_1pass<32, T>},
        {64,  group_norm_1pass<64, T>},
        {128, group_norm_1pass<128, T>},
        {256, group_norm_1pass<256, T>},
        {512, group_norm_1pass<512, T>},
    };
    const int hw = h * w;
    auto block = getThreads(c_per_g * hw);
    auto grid = n * g;
    {
        group_norm_1pass_funcs[block]<<<grid, block, 2 * c_per_g * sizeof(AccType), s>>>(
            input, output, gamma, beta, i0i8Scale, o0i8Scale, g, c_per_g, hw, eps);
        auto err = cudaGetLastError();
        if (err != cudaSuccess)
            return Status(TNNERR_CUDA_TENSORRT_ERROR, "GNSwish Plugin 1pass failed: " + std::to_string(err));
    }
    return TNN_OK;
}

Status CudaFusedGroupNormSwishLayerAcc::Init(Context *context, LayerParam *param, LayerResource *resource,
        const std::vector<Blob *> &inputs, const std::vector<Blob *> &outputs) {
    return CudaLayerAcc::Init(context, param, resource, inputs, outputs);
}

Status CudaFusedGroupNormSwishLayerAcc::Reshape(const std::vector<Blob *> &inputs, const std::vector<Blob *> &outputs) {
    return TNN_OK;
}

Status CudaFusedGroupNormSwishLayerAcc::Forward(const std::vector<Blob *> &inputs, const std::vector<Blob *> &outputs) {
    auto params = dynamic_cast<GroupNormLayerParam*>(param_);
    auto dtype = inputs[0]->GetBlobDesc().data_type;
    auto dformat    = inputs[0]->GetBlobDesc().data_format;

    Blob *input_blob = inputs[0];
    Blob *scale_blob = inputs[1];
    Blob *bias_blob  = inputs[2];
    Blob *output_blob = outputs[0];
    auto input_dims = inputs[0]->GetBlobDesc().dims;
    if (dtype == DATA_TYPE_FLOAT) {
        float* input_data = static_cast<float*>(input_blob->GetHandle().base);
        float* scale_data = static_cast<float*>(scale_blob->GetHandle().base) + scale_blob->GetHandle().bytes_offset;
        float* bias_data  = static_cast<float*>(bias_blob->GetHandle().base) + bias_blob->GetHandle().bytes_offset;
        float* output_data = static_cast<float*>(output_blob->GetHandle().base);
        int channels_per_group = input_dims[1] / params->group;

        return group_norm_v2<float>(input_data, output_data, scale_data, bias_data, 1.0, 1.0,
                                    input_dims[0], input_dims[1], params->group, channels_per_group,
                                    input_dims[2], input_dims[3], params->eps, context_->GetStream());
    } else if (dtype == DATA_TYPE_HALF) {
        __half* input_data = static_cast<__half*>(input_blob->GetHandle().base);
        float* scale_data = static_cast<float*>(scale_blob->GetHandle().base) + scale_blob->GetHandle().bytes_offset;
        float* bias_data  = static_cast<float*>(bias_blob->GetHandle().base) + bias_blob->GetHandle().bytes_offset;
        __half* output_data = static_cast<__half*>(output_blob->GetHandle().base);
        int channels_per_group = input_dims[1] / params->group;

        return group_norm_v2<__half>(input_data, output_data, scale_data, bias_data, 1.0, 1.0,
                                    input_dims[0], input_dims[1], params->group, channels_per_group,
                                    input_dims[2], input_dims[3], params->eps, context_->GetStream());
    } else {
        return Status(TNNERR_CUDA_TENSORRT_ERROR, "Unexpected data type " + std::to_string(dtype));
    }

    return TNN_OK;
}

REGISTER_CUDA_ACC(FusedGroupNormSwish, LAYER_FUSED_GROUP_NORM_SWISH);

}  // namespace TNN_NS
