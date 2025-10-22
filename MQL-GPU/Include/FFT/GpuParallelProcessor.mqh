//+------------------------------------------------------------------+
//| GpuParallelProcessor.mqh                                          |
//| High-Performance Parallel GPU Processing Manager                  |
//| MQL5-COMPATIBLE VERSION (No C++ pointers)                         |
//+------------------------------------------------------------------+
#property copyright "GPU Parallel Processing Framework"
#property version   "1.01"
#property strict

#include <FFT\GpuBridgeExtended.mqh>

//+------------------------------------------------------------------+
//| Performance Configuration                                          |
//+------------------------------------------------------------------+
#define GPU_DEFAULT_BATCH_SIZE        512
#define GPU_MIN_BATCH_SIZE            32
#define GPU_MAX_BATCH_SIZE            2048
#define GPU_OPTIMAL_WINDOW_SIZE       512

//+------------------------------------------------------------------+
//| Batch Result Structure                                            |
//+------------------------------------------------------------------+
struct GpuBatchResult {
    double real_data[];
    double imag_data[];
    int    processed_count;
    int    window_size;
    int    batch_size;
    ulong  execution_time_us;
    bool   success;
};

//+------------------------------------------------------------------+
//| Processing Configuration                                          |
//+------------------------------------------------------------------+
struct GpuProcessingConfig {
    int    batch_size;
    int    window_size;
    bool   enable_profiling;
    int    gpu_device_id;

    GpuProcessingConfig() {
        batch_size = GPU_DEFAULT_BATCH_SIZE;
        window_size = GPU_OPTIMAL_WINDOW_SIZE;
        enable_profiling = false;
        gpu_device_id = 0;
    }
};

//+------------------------------------------------------------------+
//| Main Parallel Processor Class (MQL5-Compatible)                  |
//+------------------------------------------------------------------+
class CGpuParallelProcessor {
private:
    // Configuration
    GpuProcessingConfig m_config;
    bool               m_gpu_initialized;
    bool               m_gpu_configured;

    // Statistics
    ulong              m_total_processed;
    ulong              m_total_batches;
    ulong              m_total_execution_time_us;

    bool InitializeGpu() {
        if(m_gpu_initialized) {
            return true;
        }

        int status = GpuSessionInit(m_config.gpu_device_id);
        if(!GpuStatusIsOk(status)) {
            return false;
        }

        m_gpu_initialized = true;
        return true;
    }

    bool ConfigureGpuForWindow() {
        if(!m_gpu_initialized) {
            return false;
        }

        if(m_gpu_configured) {
            return true;
        }

        int status = GpuConfigureWaveform(m_config.window_size);
        if(!GpuStatusIsOk(status)) {
            return false;
        }

        m_gpu_configured = true;
        return true;
    }

public:
    CGpuParallelProcessor() {
        m_gpu_initialized = false;
        m_gpu_configured = false;
        m_total_processed = 0;
        m_total_batches = 0;
        m_total_execution_time_us = 0;
    }

    ~CGpuParallelProcessor() {
        Shutdown();
    }

    bool Initialize(const GpuProcessingConfig &config) {
        m_config = config;

        if(m_config.batch_size < GPU_MIN_BATCH_SIZE) {
            m_config.batch_size = GPU_MIN_BATCH_SIZE;
        }
        if(m_config.batch_size > GPU_MAX_BATCH_SIZE) {
            m_config.batch_size = GPU_MAX_BATCH_SIZE;
        }

        if(!InitializeGpu()) {
            return false;
        }

        if(!ConfigureGpuForWindow()) {
            return false;
        }

        m_total_processed = 0;
        m_total_batches = 0;
        m_total_execution_time_us = 0;

        return true;
    }

    int ProcessRollingWindows(const double &prices[],
                              GpuBatchResult &results[]) {

        if(!m_gpu_initialized || !m_gpu_configured) {
            return -1;
        }

        int total_bars = ArraySize(prices);
        if(total_bars < m_config.window_size) {
            return -1;
        }

        int total_windows = total_bars - m_config.window_size + 1;
        int total_batches = (int)MathCeil((double)total_windows / (double)m_config.batch_size);

        ArrayResize(results, total_batches);

        int processed_windows = 0;
        int batch_index = 0;

        while(processed_windows < total_windows) {
            int current_batch_size = (int)MathMin(
                m_config.batch_size,
                total_windows - processed_windows
            );

            int result_size = m_config.window_size * current_batch_size;

            // Resize output buffers to receive GPU results
            ArrayResize(results[batch_index].real_data, result_size);
            ArrayResize(results[batch_index].imag_data, result_size);

            ulong start_time = m_config.enable_profiling ? GetMicrosecondCount() : 0;

            // ⚡ CALL GPU BATCH FFT DIRECTLY - Process on GPU, no local copies!
            // GPU will handle rolling windows internally
            int status = RunWaveformFftBatch(
                prices,                                    // Input directly from prices array
                results[batch_index].real_data,           // Output directly to results
                results[batch_index].imag_data,           // Output directly to results
                m_config.window_size,
                current_batch_size
            );

            ulong end_time = m_config.enable_profiling ? GetMicrosecondCount() : 0;

            if(!GpuStatusIsOk(status)) {
                results[batch_index].success = false;
                return -1;
            }

            results[batch_index].processed_count = current_batch_size;
            results[batch_index].window_size = m_config.window_size;
            results[batch_index].batch_size = current_batch_size;
            results[batch_index].execution_time_us = end_time - start_time;
            results[batch_index].success = true;

            m_total_processed += current_batch_size;
            m_total_batches++;
            m_total_execution_time_us += (end_time - start_time);

            processed_windows += current_batch_size;
            batch_index++;
        }

        return processed_windows;
    }

    void Shutdown() {
        if(m_gpu_initialized) {
            GpuSessionClose();
            m_gpu_initialized = false;
            m_gpu_configured = false;
        }
    }

    double GetAverageProcessingTimeMs() {
        if(m_total_batches == 0) return 0.0;
        return (double)m_total_execution_time_us / (double)m_total_batches / 1000.0;
    }

    bool ExtractWindowResult(const GpuBatchResult &batch_result,
                             int window_index,
                             double &out_real[],
                             double &out_imag[]) {

        if(window_index < 0 || window_index >= batch_result.processed_count) {
            return false;
        }

        ArrayResize(out_real, batch_result.window_size);
        ArrayResize(out_imag, batch_result.window_size);

        int src_offset = window_index * batch_result.window_size;

        ArrayCopy(out_real, batch_result.real_data, 0, src_offset, batch_result.window_size);
        ArrayCopy(out_imag, batch_result.imag_data, 0, src_offset, batch_result.window_size);

        return true;
    }

    bool GetPowerSpectrum(const double &in_real[],
                          const double &in_imag[],
                          double &power[]) {
        int size = ArraySize(in_real);
        ArrayResize(power, size);

        int status = ComputePowerSpectrumGpu(in_real, in_imag, power, size, 1);
        return GpuStatusIsOk(status);
    }

    bool GetMagnitudeSpectrum(const double &in_real[],
                              const double &in_imag[],
                              double &magnitude[]) {
        int size = ArraySize(in_real);
        ArrayResize(magnitude, size);

        int status = ComputeMagnitudeSpectrumGpu(in_real, in_imag, magnitude, size, 1);
        return GpuStatusIsOk(status);
    }
};
//+------------------------------------------------------------------+
