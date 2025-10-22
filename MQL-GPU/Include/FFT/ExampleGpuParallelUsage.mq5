//+------------------------------------------------------------------+
//| ExampleGpuParallelUsage.mq5                                       |
//| Exemplo de uso do GpuParallelProcessor                            |
//+------------------------------------------------------------------+
#property copyright "GPU Parallel Processing Example"
#property version   "1.00"
#property strict

#include <FFT\GpuParallelProcessor.mqh>

//+------------------------------------------------------------------+
//| Global processor instance                                         |
//+------------------------------------------------------------------+
CGpuParallelProcessor g_gpu_processor;

//+------------------------------------------------------------------+
//| Expert initialization function                                    |
//+------------------------------------------------------------------+
int OnInit() {
    GpuProcessingConfig config;
    config.batch_size = 512;
    config.window_size = 512;
    config.enable_profiling = true;
    config.gpu_device_id = 0;
    
    if(!g_gpu_processor.Initialize(config)) {
        Print("ERROR: Failed to initialize GPU processor");
        return INIT_FAILED;
    }
    
    Print("GPU Processor initialized successfully");
    Print("Window size: ", config.window_size);
    Print("Batch size: ", config.batch_size);
    
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                  |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
    ulong total_processed, total_batches, total_time;
    g_gpu_processor.GetStatistics(total_processed, total_batches, total_time);
    
    Print("=== GPU Processing Statistics ===");
    Print("Total windows processed: ", total_processed);
    Print("Total batches: ", total_batches);
    Print("Average processing time: ", g_gpu_processor.GetAverageProcessingTimeMs(), " ms");
    Print("Throughput: ", g_gpu_processor.GetThroughputFFTsPerSecond(), " FFTs/sec");
    
    g_gpu_processor.Shutdown();
    Print("GPU Processor shutdown complete");
}

//+------------------------------------------------------------------+
//| Exemplo 1: Processamento batch de rolling windows                |
//+------------------------------------------------------------------+
void ExampleRollingWindowsBatch() {
    double prices[];
    int bars_to_copy = 10000;
    
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, bars_to_copy, prices) != bars_to_copy) {
        Print("ERROR: Failed to copy price data");
        return;
    }
    
    GpuBatchResult results[];
    int total_processed = g_gpu_processor.ProcessRollingWindows(prices, results);
    
    if(total_processed < 0) {
        Print("ERROR: Failed to process rolling windows");
        return;
    }
    
    Print("Successfully processed ", total_processed, " windows in ", ArraySize(results), " batches");
    
    for(int i = 0; i < ArraySize(results); i++) {
        Print("Batch ", i, ": ", GpuBatchResultToString(results[i]));
    }
    
    double fft_real[], fft_imag[], magnitude[];
    if(g_gpu_processor.ExtractWindowResult(results[0], 0, fft_real, fft_imag)) {
        g_gpu_processor.GetMagnitudeSpectrum(fft_real, fft_imag, magnitude);
        
        int dominant_idx = FindDominantFrequencyIndex(magnitude);
        Print("Dominant frequency index in first window: ", dominant_idx);
    }
}

//+------------------------------------------------------------------+
//| Exemplo 2: Processamento batch manual                            |
//+------------------------------------------------------------------+
void ExampleManualBatch() {
    double prices[];
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 5000, prices) != 5000) {
        Print("ERROR: Failed to copy price data");
        return;
    }
    
    GpuBatchResult result;
    if(!g_gpu_processor.ProcessBatch(prices, 0, 256, result)) {
        Print("ERROR: Failed to process batch");
        return;
    }
    
    Print("Batch processing completed: ", GpuBatchResultToString(result));
    
    double window_real[], window_imag[];
    for(int i = 0; i < result.processed_count; i++) {
        if(g_gpu_processor.ExtractWindowResult(result, i, window_real, window_imag)) {
            double magnitude[], power[];
            g_gpu_processor.GetMagnitudeSpectrum(window_real, window_imag, magnitude);
            g_gpu_processor.GetPowerSpectrum(window_real, window_imag, power);
            
            double total_power = CalculateTotalPower(power);
            int dominant_freq = FindDominantFrequencyIndex(magnitude);
            
            Print("Window ", i, " - Total Power: ", total_power, ", Dominant Freq Index: ", dominant_freq);
        }
    }
}

//+------------------------------------------------------------------+
//| Exemplo 3: Processamento de janela única                         |
//+------------------------------------------------------------------+
void ExampleSingleWindow() {
    double prices[];
    int window_size = g_gpu_processor.GetConfiguredWindowSize();
    
    if(CopyClose(_Symbol, PERIOD_CURRENT, 0, window_size, prices) != window_size) {
        Print("ERROR: Failed to copy price data");
        return;
    }
    
    double fft_real[], fft_imag[];
    if(!g_gpu_processor.ProcessSingleWindow(prices, fft_real, fft_imag)) {
        Print("ERROR: Failed to process single window");
        return;
    }
    
    Print("Single window FFT completed successfully");
    
    double magnitude[], phase[], power[];
    g_gpu_processor.GetMagnitudeSpectrum(fft_real, fft_imag, magnitude);
    g_gpu_processor.GetPhaseSpectrum(fft_real, fft_imag, phase);
    g_gpu_processor.GetPowerSpectrum(fft_real, fft_imag, power);
    
    double frequencies[];
    double sampling_rate = 1.0;
    CalculateFrequencyBins(window_size, sampling_rate, frequencies);
    
    int dominant_idx = FindDominantFrequencyIndex(magnitude);
    Print("Dominant frequency: ", frequencies[dominant_idx], " Hz");
    Print("Dominant magnitude: ", magnitude[dominant_idx]);
    Print("Total power: ", CalculateTotalPower(power));
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick() {
    static datetime last_execution = 0;
    datetime current_time = TimeCurrent();
    
    if(current_time - last_execution < 60) {
        return;
    }
    
    last_execution = current_time;
    
    Print("\n=== Running GPU Parallel Processing Examples ===");
    
    ExampleRollingWindowsBatch();
    Print("");
    
    ExampleManualBatch();
    Print("");
    
    ExampleSingleWindow();
    Print("");
}
//+------------------------------------------------------------------+
