# GPU Parallel Processor for MQL5

## Overview

Framework de alto desempenho para processamento paralelo FFT via CUDA em MQL5. Maximiza throughput através de batch processing e gerenciamento otimizado de memória GPU.

## Arquitetura

### Componentes Principais

**GpuBufferPool**
- Pool de buffers reutilizáveis para minimizar alocações
- Gerenciamento automático de capacidade
- Três buffers: input, real, imag

**CGpuParallelProcessor**
- Interface principal para operações GPU
- Suporte a batch processing automático
- Profiling integrado
- Gerenciamento de sessão GPU

### Especificações de Performance

```
Batch Size Padrão: 512 windows
Window Size Padrão: 512 samples
Throughput Esperado: 10.000-50.000 FFTs/segundo (GPU RTX 3060)
Latência por Batch: 5-20ms
Memory Overhead: ~12MB para config padrão
```

## API Reference

### Inicialização

```cpp
CGpuParallelProcessor processor;

GpuProcessingConfig config;
config.batch_size = 512;
config.window_size = 512;
config.enable_profiling = true;
config.gpu_device_id = 0;

if(!processor.Initialize(config)) {
    // Erro de inicialização
}
```

### ProcessRollingWindows

Processa múltiplas janelas deslizantes em paralelo.

**Signature:**
```cpp
int ProcessRollingWindows(const double &prices[], GpuBatchResult &results[])
```

**Parâmetros:**
- `prices[]`: Array de dados fonte (preços, sinais, etc)
- `results[]`: Array de saída com resultados batch (redimensionado automaticamente)

**Retorno:**
- Total de janelas processadas (>0)
- -1 em caso de erro

**Exemplo:**
```cpp
double prices[];
CopyClose(_Symbol, PERIOD_CURRENT, 0, 10000, prices);

GpuBatchResult results[];
int total = processor.ProcessRollingWindows(prices, results);

Print("Processadas ", total, " janelas em ", ArraySize(results), " batches");
```

### ProcessBatch

Processa batch específico de janelas.

**Signature:**
```cpp
bool ProcessBatch(const double &source_data[], 
                  int start_offset,
                  int batch_count,
                  GpuBatchResult &result)
```

**Parâmetros:**
- `source_data[]`: Dados fonte completos
- `start_offset`: Índice inicial no array fonte
- `batch_count`: Quantidade de janelas a processar (≤ batch_size configurado)
- `result`: Estrutura de saída com resultados

**Retorno:**
- true se sucesso
- false se erro

**Exemplo:**
```cpp
GpuBatchResult result;
if(processor.ProcessBatch(prices, 0, 256, result)) {
    Print(GpuBatchResultToString(result));
}
```

### ProcessSingleWindow

Processa uma única janela FFT.

**Signature:**
```cpp
bool ProcessSingleWindow(const double &window_data[], 
                         double &fft_real[],
                         double &fft_imag[])
```

**Parâmetros:**
- `window_data[]`: Janela de dados (tamanho = window_size configurado)
- `fft_real[]`: Saída componente real
- `fft_imag[]`: Saída componente imaginária

**Retorno:**
- true se sucesso
- false se erro

### ExtractWindowResult

Extrai resultado de janela específica de um batch.

**Signature:**
```cpp
bool ExtractWindowResult(const GpuBatchResult &batch_result,
                         int window_index,
                         double &fft_real[],
                         double &fft_imag[])
```

**Parâmetros:**
- `batch_result`: Resultado batch contendo múltiplas janelas
- `window_index`: Índice da janela desejada (0 a processed_count-1)
- `fft_real[]`: Saída componente real
- `fft_imag[]`: Saída componente imaginária

## Estruturas de Dados

### GpuBatchResult

```cpp
struct GpuBatchResult {
    double real_data[];          // Dados reais concatenados (window_size * batch_size)
    double imag_data[];          // Dados imaginários concatenados
    int    processed_count;      // Quantidade de janelas processadas
    int    window_size;          // Tamanho de cada janela
    int    batch_size;           // Tamanho do batch
    ulong  execution_time_us;    // Tempo de execução em microssegundos
    bool   success;              // Status de sucesso
};
```

### GpuProcessingConfig

```cpp
struct GpuProcessingConfig {
    int  batch_size;           // Janelas processadas simultaneamente (32-2048)
    int  window_size;          // Tamanho de cada janela FFT
    bool enable_profiling;     // Habilita medição de tempo
    int  gpu_device_id;        // ID do dispositivo GPU (default: 0)
};
```

## Métodos Auxiliares de Análise Espectral

### GetMagnitudeSpectrum

```cpp
void GetMagnitudeSpectrum(const double &fft_real[], 
                          const double &fft_imag[],
                          double &magnitude[])
```

Calcula magnitude: `sqrt(real² + imag²)`

### GetPhaseSpectrum

```cpp
void GetPhaseSpectrum(const double &fft_real[], 
                      const double &fft_imag[],
                      double &phase[])
```

Calcula fase: `atan2(imag, real)`

### GetPowerSpectrum

```cpp
void GetPowerSpectrum(const double &fft_real[], 
                      const double &fft_imag[],
                      double &power[])
```

Calcula potência: `real² + imag²`

## Funções Globais Auxiliares

### CalculateFrequencyBins

```cpp
void CalculateFrequencyBins(int fft_size, 
                            double sampling_rate, 
                            double &frequencies[])
```

Calcula bins de frequência para FFT.

### FindDominantFrequencyIndex

```cpp
int FindDominantFrequencyIndex(const double &magnitude[])
```

Retorna índice da frequência dominante (maior magnitude).

### CalculateTotalPower

```cpp
double CalculateTotalPower(const double &power_spectrum[])
```

Soma total da potência espectral.

## Estatísticas e Profiling

### GetStatistics

```cpp
void GetStatistics(ulong &total_processed, 
                   ulong &total_batches, 
                   ulong &total_time_us)
```

### GetAverageProcessingTimeMs

```cpp
double GetAverageProcessingTimeMs()
```

Retorna tempo médio de processamento por batch em milissegundos.

### GetThroughputFFTsPerSecond

```cpp
double GetThroughputFFTsPerSecond()
```

Retorna throughput em FFTs por segundo.

### ResetStatistics

```cpp
void ResetStatistics()
```

Reseta contadores de estatísticas.

## Otimização de Performance

### Seleção de Batch Size

```
Batch Size    | Latência  | Throughput | Uso Memória
------------- | --------- | ---------- | -----------
32            | 2-5ms     | Baixo      | 2MB
128           | 5-10ms    | Médio      | 6MB
512 (default) | 10-20ms   | Alto       | 12MB
1024          | 20-40ms   | Muito Alto | 24MB
2048          | 40-80ms   | Máximo     | 48MB
```

**Recomendações:**
- Trading de alta frequência: batch_size = 128-256
- Análise batch offline: batch_size = 512-1024
- Datasets massivos: batch_size = 1024-2048

### Window Size

Potências de 2 otimizadas pela cuFFT: 64, 128, 256, 512, 1024, 2048, 4096

### UpdateBatchSize

```cpp
bool UpdateBatchSize(int new_batch_size)
```

Atualiza batch size em runtime (realoca buffers).

## Limitações e Considerações

### MQL5 Thread Model

MQL5 opera em single-thread. Paralelismo real ocorre **internamente na GPU via CUDA**, não no nível MQL5.

### Overhead de Transferência

- Host→Device: ~1-2ms para batch de 512 janelas
- Device→Host: ~1-2ms para resultados
- Processamento GPU: ~5-15ms (depende da GPU)

### Memory Footprint

```
Total Memory = 3 * window_size * batch_size * sizeof(double)
             = 3 * 512 * 512 * 8 bytes
             = ~12MB para configuração padrão
```

## Requisitos

- CUDA Toolkit 11.0+
- GPU com compute capability 3.5+
- Driver NVIDIA atualizado
- GpuBridge.dll compilado
- cudart64_13.dll
- cufft64_12.dll

## Workflow Típico

```cpp
// 1. Inicializar
CGpuParallelProcessor processor;
GpuProcessingConfig config;
processor.Initialize(config);

// 2. Carregar dados
double prices[10000];
CopyClose(_Symbol, PERIOD_CURRENT, 0, 10000, prices);

// 3. Processar em paralelo
GpuBatchResult results[];
processor.ProcessRollingWindows(prices, results);

// 4. Extrair e analisar
double fft_real[], fft_imag[], magnitude[];
processor.ExtractWindowResult(results[0], 0, fft_real, fft_imag);
processor.GetMagnitudeSpectrum(fft_real, fft_imag, magnitude);

// 5. Shutdown
processor.Shutdown();
```

## Status Codes (GPU_STATUS_*)

```
GPU_STATUS_OK                    =  0
GPU_STATUS_ERROR                 = -1
GPU_STATUS_ALREADY_INITIALIZED   = -2
GPU_STATUS_INVALID_LENGTH        = -3
GPU_STATUS_PLAN_FAILURE          = -4
GPU_STATUS_MEMORY_FAILURE        = -5
GPU_STATUS_CUDA_FAILURE          = -6
GPU_STATUS_NOT_INITIALISED       = -100
GPU_STATUS_INVALID_ARGUMENT      = -101
```
