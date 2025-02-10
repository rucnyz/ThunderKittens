#include <iostream>
#include <string>
#include <fstream>

constexpr int ATTN_B = 256;
constexpr int ATTN_H = 1;
constexpr int ATTN_N = 924; // 768*2; // 4096;
constexpr int ATTN_D = 128; // hardcoded into this kernel
constexpr int ITER   = 10;

#define CudaCheckError()    __cudaCheckError( __FILE__, __LINE__ )
inline void __cudaCheckError( const char *file, const int line ) {
    cudaError err = cudaGetLastError();
    if ( cudaSuccess != err )
    {
        fprintf( stderr, "cudaCheckError() failed at %s:%i : %s\n",
                 file, line, cudaGetErrorString( err ) );
        exit( -1 );
    }
    // More careful checking. However, this will affect performance.
    // Comment away if needed.
    err = cudaDeviceSynchronize();
    if( cudaSuccess != err )
    {
        fprintf( stderr, "cudaCheckError() with sync failed at %s:%i : %s\n",
                 file, line, cudaGetErrorString( err ) );
        exit( -1 );
    }
}

// Compute FLOPs for forward attention
constexpr uint64_t ATTN_FLOPS = 
    2llu * ATTN_B * ATTN_H * ATTN_N * ATTN_N * ATTN_D + // Q * K^T: 2BHNND (multiply-add)
    4llu * ATTN_B * ATTN_H * ATTN_N * ATTN_N +          // Softmax: 2BHNN (exp and divide, plus flash-attn bookkeeping)
    2llu * ATTN_B * ATTN_H * ATTN_N * ATTN_N * ATTN_D;      // (Q * K^T) * V: 2BHNND (multiply-add)

int main(int argc, char **argv) {
    // TODO: consider doing sequential kernel launches to force batches dimension element to execute sequentially,
    // which may increase the probability of L2 cache hits on KV
    using ker_template = attn_fwd_template<ATTN_D>;

    std::cout << "Entered main!" << std::endl;

    // create dummy variables that are the right size
    constexpr int TOTAL_ELEMENTS = ATTN_B*ATTN_H*ATTN_N*ATTN_D;
    constexpr int TOTAL_UNIQUE_ELEMENTS = ATTN_N*ATTN_D*ATTN_H;

    float *q = new float[TOTAL_ELEMENTS];
    float *k = new float[TOTAL_ELEMENTS];
    float *v = new float[TOTAL_ELEMENTS];
    float *o_ref = new float[TOTAL_ELEMENTS];

    bf16 *q_bf = new bf16[TOTAL_ELEMENTS];
    bf16 *k_bf = new bf16[TOTAL_ELEMENTS];
    bf16 *v_bf = new bf16[TOTAL_ELEMENTS];
    bf16 *o_bf = new bf16[TOTAL_ELEMENTS];
    float *o = new float[TOTAL_ELEMENTS];

    std::ifstream infile(argv[1]);

    std::cout << "Starting to enter!" << std::endl;

    for(int i = 0; i < TOTAL_ELEMENTS/ATTN_B; i++) infile >> q[i];
    std::cout << "Finished loading Q" << std::endl;
    for(int i = 0; i < TOTAL_ELEMENTS/ATTN_B; i++) infile >> k[i];
    std::cout << "Finished loading K" << std::endl;
    for(int i = 0; i < TOTAL_ELEMENTS/ATTN_B; i++) infile >> v[i];
    std::cout << "Finished loading V" << std::endl;
    for(int i = 0; i < TOTAL_ELEMENTS/ATTN_B; i++) infile >> o_ref[i];
    std::cout << "Finished loading O_REF" << std::endl;

    std::cout << "Finished loading file from " << argv[1] << "!" << std::endl;

    // replicate into batch elements
    for(int i = 0; i < TOTAL_ELEMENTS; i++) {
        q_bf[i] = __float2bfloat16(q[i % (TOTAL_ELEMENTS/ATTN_B)]);
        k_bf[i] = __float2bfloat16(k[i % (TOTAL_ELEMENTS/ATTN_B)]);
        v_bf[i] = __float2bfloat16(v[i % (TOTAL_ELEMENTS/ATTN_B)]);
    }

    bf16 *d_q, *d_k, *d_v, *d_o;
    cudaMalloc(&d_q, TOTAL_ELEMENTS * sizeof(bf16));
    cudaMalloc(&d_k, TOTAL_ELEMENTS * sizeof(bf16));
    cudaMalloc(&d_v, TOTAL_ELEMENTS * sizeof(bf16));
    cudaMalloc(&d_o, TOTAL_ELEMENTS * sizeof(bf16));

    cudaMemcpy(d_q, q_bf, TOTAL_ELEMENTS * sizeof(bf16), cudaMemcpyHostToDevice);
    cudaMemcpy(d_k, k_bf, TOTAL_ELEMENTS * sizeof(bf16), cudaMemcpyHostToDevice);
    cudaMemcpy(d_v, v_bf, TOTAL_ELEMENTS * sizeof(bf16), cudaMemcpyHostToDevice);

    ker_template::layout::qo_global Qg(d_q, ATTN_B, ATTN_H, ATTN_N, nullptr);
    ker_template::layout::kv_global Kg(d_k, ATTN_B, ATTN_H, ATTN_N, nullptr);
    ker_template::layout::kv_global Vg(d_v, ATTN_B, ATTN_H, ATTN_N, nullptr);
    ker_template::layout::qo_global Og(d_o, ATTN_B, ATTN_H, ATTN_N, nullptr);
    ker_template::layout::globals globals = {Og, Qg, Kg, Vg};
    
    unsigned long mem_size = kittens::MAX_SHARED_MEMORY - 2000; // have the flag tell us
    
    cudaFuncSetAttribute(
        prototype::lcf::kernel<ker_template>,
        cudaFuncAttributeMaxDynamicSharedMemorySize,
        mem_size
    );

    cudaDeviceSynchronize();
    std::cout << "Starting kernel\n";
    constexpr int NUM_WORKERS = prototype::detail::NUM_CONSUMER_WARPGROUPS_v<ker_template>;
    constexpr int BLOCK_SIZE = prototype::detail::NUM_THREADS_v<ker_template>;
    dim3 grid(132, 1, 1);
    // dim3 bad_grid(grid.z, grid.y, grid.x);
    std::cout << "Grid size: " << grid.x << " x " << grid.y << " x " << grid.z << std::endl;
    // warmup
    for(int j = 0; j < ITER; j++)
        prototype::lcf::kernel<ker_template><<<grid, BLOCK_SIZE, mem_size>>>(globals);
    cudaDeviceSynchronize();
    
    const auto start = std::chrono::high_resolution_clock::now();
    for(int i = 0; i < ITER; i++) {
        prototype::lcf::kernel<ker_template><<<grid, BLOCK_SIZE, mem_size>>>(globals);
    }
    cudaDeviceSynchronize();
    const auto finish = std::chrono::high_resolution_clock::now();
    CudaCheckError();
    std::cout << "Finished kernel\n";
    
    // check correctness
    cudaMemcpy(o_bf, d_o, TOTAL_ELEMENTS * sizeof(bf16), cudaMemcpyDeviceToHost);
    for(int i = 0; i < TOTAL_ELEMENTS; i++) {
        o[i] = __bfloat162float(o_bf[i]);
    }

    bool good = true;
    std::ofstream o_ref_file("printouts/o_ref.txt");
    std::ofstream o_file("printouts/o.txt");
    std::ofstream diff_file("printouts/diff.txt");

    float total_diff = 0;
    float max_error = 0; 

    for(int i = 0; i < TOTAL_ELEMENTS; i++) {
        float diff = o[i] - o_ref[i % (TOTAL_ELEMENTS/ATTN_B)];

        if (i < TOTAL_UNIQUE_ELEMENTS) {
            o_ref_file << o_ref[i % (TOTAL_ELEMENTS/ATTN_B)] << ' ';
            o_file << o[i] << ' ';
            diff_file << diff << ' ';
        }
        if (i % ATTN_D == ATTN_D-1) {
            o_ref_file << '\n';
            o_file << '\n';
            diff_file << '\n';
        }
        if(abs(diff) > 0.01 || isnan(diff)) {
            good = false;
        }

        total_diff += abs(diff);
        if (abs(diff) > max_error) {
            max_error = abs(diff);
        }
    }

    // print average difference
    std::cout << "Average o difference: " << total_diff / TOTAL_ELEMENTS << std::endl;
    std::cout << "Max     o difference: " << max_error << std::endl;
    if (abs(total_diff / TOTAL_ELEMENTS) < 1e-3) {
        good = true;
    }

    std::cout << "Average fwd execution time: " << std::chrono::duration_cast<std::chrono::microseconds>(finish - start).count() / ITER << " us" << std::endl;
    if(good) std::cout << "FWD Correct :)\n";
    else std::cout << "FWD Incorrect :(\n";
    // Compute and print average TFLOPs achieved
    double avg_time_s = (double)(std::chrono::duration_cast<std::chrono::microseconds>(finish - start).count()) / (ITER * 1e6);
    double avg_tflops = (ATTN_FLOPS / avg_time_s) / 1e12;
    std::cout << "Efficiency: " << avg_tflops << " TFLOPS\n\n\n" << std::endl;

    cudaFree(d_q);
    cudaFree(d_k);
    cudaFree(d_v);
    cudaFree(d_o);

    delete[] q, k, v, o, o_ref;
    delete[] q_bf, k_bf, v_bf, o_bf;

    return 0;
}
