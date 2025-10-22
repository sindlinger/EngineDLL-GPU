# GpuEngine.dll – Assíncrona para WaveSpec

## Objetivo
Centralizar todo o pipeline CUDA (FFT batelada, filtragem espectral, reconstrução, métricas) em uma única DLL assíncrona. A DLL expõe uma fila de jobs; o EA Hub envia dados crus, a DLL processa em background (GPU + threads C++), e os resultados são buscados sob demanda.

## Fluxo de Alto Nível
1. `GpuEngine_Init(const GpuEngineConfig* cfg)` cria o contexto CUDA, aloca buffers pinados e threads de worker.
2. O EA empacota janelas STFT (ou outros sinais) e chama `GpuEngine_SubmitJob`.
3. As threads da DLL movem dados para a GPU (via `cudaMemcpyAsync`), executam kernels (cuFFT, máscaras, IFFT, métricas) e escrevem o resultado num buffer de saída associado ao job.
4. O EA verifica com `GpuEngine_PollStatus(handle)` se o job terminou. Quando terminar, chama `GpuEngine_FetchResult` para copiar os dados filtrados/ciclos/etc. para os arrays MQL5.
5. `GpuEngine_Shutdown()` fecha a fila, sincroniza as threads e libera recursos.

## Estruturas C++ (lado DLL)
```cpp
struct GpuEngineConfig {
    int device_id;          // GPU física (0 = default)
    int window_size;        // Tamanho da janela FFT (potência de 2)
    int hop_size;           // Passo entre janelas
    int max_batch_size;     // Número máximo de frames por job
    int overlap_mode;       // Futuro (OLA, OLS, etc.)
    bool enable_profiling;  // Coletar métricas internas
};

struct GpuEngineJobDesc {
    const double* host_input;  // ponteiro para sinais (múltiplas janelas concatenadas)
    int frame_count;           // quantas janelas há nesse job
    int input_stride;          // opcional (caso frames não sejam contíguos)
    uint64_t user_tag;         // identificador arbitrário do chamador
    uint32_t flags;            // bits (ex.: aplicar detrend, calcular ciclos)
};

struct GpuEngineJobHandle {
    uint64_t internal_id;      // id interno (fila)
    uint64_t user_tag;         // ecoado do job
};

struct GpuEngineResultInfo {
    uint64_t user_tag;         // identificação
    int frame_count;           // frames processados
    int window_size;           // confirma window size
    double elapsed_ms;         // tempo GPU
};
```

### Estado Interno
- **GpuContext**: cuFFT plans, streams, buffers device/host (pinados).
- **Worker threads**: cada job entra em uma `std::queue`; as threads pegam, executam e marcam status.
- **Job table**: vetor com `RUNNING / READY / FAILED`; ponteiros para buffers de saída.

### Sequência de Kernels (job STFT)
1. `cudaMemcpyAsync` para buffer device.
2. Kernel detrend/detrend EMA (opcional).
3. Kernel de janela (Hamming/Hann/etc.).
4. `cuFFT` batelado (`cufftPlanMany`)
5. Kernel de máscara espectral (por período) + fades.
6. `cuFFT` inverso.
7. Kernel OLA (opcional) ou deixa para MQL.
8. Kernel de cálculo de magnitude/ciclos (opcional).
9. `cudaMemcpyAsync` de saída para host.
10. `cudaStreamSynchronize` → marca job concluído.

## API Exportada (C)
```cpp
extern "C" {
    // Inicialização / finalização
    DLL_EXPORT int  GpuEngine_Init(const GpuEngineConfig* cfg);
    DLL_EXPORT void GpuEngine_Shutdown();

    // Submissão / polling
    DLL_EXPORT int  GpuEngine_SubmitJob(const GpuEngineJobDesc* job,
                                        GpuEngineJobHandle* out_handle);
    DLL_EXPORT int  GpuEngine_PollStatus(const GpuEngineJobHandle* handle,
                                         int* out_status);
    DLL_EXPORT int  GpuEngine_Wait(const GpuEngineJobHandle* handle,
                                   double timeout_ms);

    // Resultado (cópia host)
    DLL_EXPORT int  GpuEngine_FetchResult(const GpuEngineJobHandle* handle,
                                          GpuEngineResultInfo* info,
                                          double* wave_out,
                                          double* preview_out,
                                          double* cycles_out,
                                          double* noise_out);

    // Profiling opcional
    DLL_EXPORT int  GpuEngine_GetLastError(char* buffer, int buffer_len);
    DLL_EXPORT int  GpuEngine_GetStats(double* avg_ms, double* max_ms);
}
```
`out_status`: 0 = running, 1 = ready, <0 = erro (usar `GetLastError`).

## Wrapper MQL5
Será criado em `Include/WaveSpecGPU/GpuEngine.mqh`, com classes `GpuEngineConfig`, `GpuEngineJob`, `CGpuEngineClient`. O EA Hub chamará:
1. `CGpuEngineClient::Initialize(config)`
2. `SubmitStftJob(t`, data[])` retornando `GpuJobHandle`.
3. `Poll(handle)` até `JOB_READY`, então `Fetch(handle, out_struct)`.

## Próximos Passos
1. Implementar a DLL (C++/CUDA) com fila, buffers pinados, cuFFT.
2. Criar wrapper MQL e um EA de teste (“WaveSpec_Hub”).
3. Ajustar indicadores para consumir os buffers do Hub.
