//+------------------------------------------------------------------+
//| ExampleGpuOnly.mq5                                                |
//| GPU-Only Spectral Analysis - NO CPU Fallback                     |
//| Demonstração de processamento 100% paralelo na GPU                |
//+------------------------------------------------------------------+
#property copyright "GPU-Only Processing"
#property version   "1.00"
#property script_show_inputs

#include <FFT\GpuParallelProcessor.mqh>

input int WindowSize = 512;
input int BatchCount = 100;

//+------------------------------------------------------------------+
//| Script principal                                                 |
//+------------------------------------------------------------------+
void OnStart() {
    Print("========================================");
    Print("GPU-ONLY Spectral Analysis Demo");
    Print("NO CPU Fallback - Pure GPU Processing");
    Print("========================================");

    // Gerar dados de teste
    double test_data[];
    int total_size = WindowSize * BatchCount;
    ArrayResize(test_data, total_size);

    for(int i = 0; i < total_size; i++) {
        test_data[i] = MathSin(2 * M_PI * i / 50.0) +
                       0.5 * MathSin(2 * M_PI * i / 20.0) +
                       0.3 * (MathRand() / 32767.0);
    }

    // ========== TESTE 1: Single Window GPU ==========
    Print("\n=== TEST 1: Single Window (GPU Only) ===");
    TestSingleWindow(test_data);

    // ========== TESTE 2: Batch Processing GPU ==========
    Print("\n=== TEST 2: Batch Processing (GPU Only) ===");
    TestBatchProcessing(test_data);

    Print("\n========================================");
    Print("Demo Complete - All GPU!");
    Print("========================================");
}

//+------------------------------------------------------------------+
//| Teste 1: Single Window                                           |
//+------------------------------------------------------------------+
void TestSingleWindow(const double &data[]) {
    CGpuParallelProcessor gpu;
    GpuProcessingConfig config;

    config.window_size = WindowSize;
    config.enable_profiling = true;

    if(!gpu.Initialize(config)) {
        Print("ERROR: GPU initialization failed");
        Print("Check: GPU available? CUDA drivers installed?");
        return;
    }

    // Extrair janela
    double window[];
    ArrayResize(window, WindowSize);
    ArrayCopy(window, data, 0, 0, WindowSize);

    ulong start_time = GetMicrosecondCount();

    // FFT na GPU
    double fft_real[], fft_imag[];
    if(!gpu.ProcessSingleWindow(window, fft_real, fft_imag)) {
        Print("ERROR: GPU FFT failed");
        gpu.Shutdown();
        return;
    }

    // Análise espectral na GPU (PARALELA)
    double magnitude[], phase[], power[];

    bool mag_ok = gpu.GetMagnitudeSpectrum(fft_real, fft_imag, magnitude);
    bool phase_ok = gpu.GetPhaseSpectrum(fft_real, fft_imag, phase);
    bool power_ok = gpu.GetPowerSpectrum(fft_real, fft_imag, power);

    ulong total_time = GetMicrosecondCount() - start_time;

    if(!mag_ok || !phase_ok || !power_ok) {
        Print("ERROR: GPU spectral analysis failed");
        if(!mag_ok) Print("  - Magnitude computation failed");
        if(!phase_ok) Print("  - Phase computation failed");
        if(!power_ok) Print("  - Power computation failed");
        gpu.Shutdown();
        return;
    }

    Print("✅ SUCCESS - GPU Processing Complete");
    Print("  - Total Time: ", total_time / 1000.0, " ms");
    Print("  - Magnitude[0]: ", magnitude[0]);
    Print("  - Phase[0]: ", phase[0]);
    Print("  - Power[0]: ", power[0]);
    Print("  - All processed on GPU (zero CPU work)");

    // Encontrar frequência dominante
    int dom_idx = FindDominantFrequencyIndex(magnitude);
    Print("  - Dominant Frequency Index: ", dom_idx);

    gpu.Shutdown();
}

//+------------------------------------------------------------------+
//| Teste 2: Batch Processing                                        |
//+------------------------------------------------------------------+
void TestBatchProcessing(const double &data[]) {
    CGpuParallelProcessor gpu;
    GpuProcessingConfig config;

    config.window_size = WindowSize;
    config.batch_size = MathMin(BatchCount, 512);
    config.enable_profiling = true;

    if(!gpu.Initialize(config)) {
        Print("ERROR: GPU initialization failed");
        return;
    }

    ulong start_time = GetMicrosecondCount();

    // Processar rolling windows (GPU batch)
    GpuBatchResult results[];
    int windows = gpu.ProcessRollingWindows(data, results);

    if(windows <= 0) {
        Print("ERROR: GPU batch processing failed");
        gpu.Shutdown();
        return;
    }

    // Análise espectral de TODOS os batches na GPU
    int batch_count = ArraySize(results);
    int total_spectrum_elements = 0;

    for(int b = 0; b < batch_count; b++) {
        double magnitude_batch[];

        // GPU BATCH processing (100% paralelo)
        if(!gpu.GetMagnitudeSpectrumBatch(results[b], magnitude_batch)) {
            Print("ERROR: GPU batch ", b, " failed");
            continue;
        }

        total_spectrum_elements += ArraySize(magnitude_batch);
    }

    ulong total_time = GetMicrosecondCount() - start_time;

    Print("✅ SUCCESS - GPU Batch Processing Complete");
    Print("  - Total Windows: ", windows);
    Print("  - Total Batches: ", batch_count);
    Print("  - Total Time: ", total_time / 1000.0, " ms");
    Print("  - Per Window: ", (total_time / (double)windows) / 1000.0, " ms");
    Print("  - Throughput: ", (windows * 1000000.0) / total_time, " FFTs/sec");
    Print("  - Spectrum Elements Processed: ", total_spectrum_elements);
    Print("  - All on GPU (256 threads/block × ", batch_count, " blocks)");

    // Estatísticas do processador
    ulong total_processed, total_batches, total_exec_time;
    gpu.GetStatistics(total_processed, total_batches, total_exec_time);

    Print("\nGPU Statistics:");
    Print("  - Total FFTs Processed: ", total_processed);
    Print("  - Total Batches: ", total_batches);
    Print("  - Avg Time per Batch: ", gpu.GetAverageProcessingTimeMs(), " ms");
    Print("  - Overall Throughput: ", gpu.GetThroughputFFTsPerSecond(), " FFTs/sec");

    gpu.Shutdown();
}
//+------------------------------------------------------------------+
