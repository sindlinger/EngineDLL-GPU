# GpuEngine.dll – Referência de API

## Objetivo
Documentar a API pública exposta por `GpuEngine.dll` após a refatoração CUDA/STFT. A DLL atua como motor assíncrono batelado: recebe frames do EA Hub (`GPU_EngineHub`), processa FFT + máscaras + ciclos na GPU e devolve buffers consolidados para os indicadores.

## Estruturas Principais

```cpp
namespace gpuengine {

struct Config {
    int  device_id        = 0;
    int  window_size      = 0;
    int  hop_size         = 0;
    int  max_batch_size   = 0;
    int  max_cycle_count  = 12;
    int  stream_count     = 2;
    bool enable_profiling = false;
};

struct MaskParams {
    double sigma_period = 48.0;
    double threshold    = 0.05;
    double softness     = 0.20;
};

struct CycleParams {
    const double* periods = nullptr;
    int           count   = 0;
    double        width   = 0.25;
};

struct PhaseParams {
    double blend            = 0.65;
    double phase_gain       = 0.08;
    double freq_gain        = 0.002;
    double amp_gain         = 0.08;
    double freq_prior_blend = 0.15;
    double min_period       = 8.0;
    double max_period       = 512.0;
    double snr_floor        = 0.25;
    int    frames_for_snr   = 1;
};

struct JobDesc {
    const double* frames        = nullptr;
    const double* preview_mask  = nullptr;
    int           frame_count   = 0;
    int           frame_length  = 0;
    std::uint64_t user_tag      = 0ULL;
    std::uint32_t flags         = 0U;
    int           upscale       = 1;
    MaskParams    mask{};
    CycleParams   cycles{};
    PhaseParams   phase{};
};

struct ResultInfo {
    std::uint64_t user_tag    = 0ULL;
    int           frame_count = 0;
    int           frame_length= 0;
    int           cycle_count = 0;
    int           dominant_cycle = -1;
    double        dominant_period = 0.0;
    double        dominant_snr = 0.0;
    double        pll_phase_deg = 0.0;
    double        pll_amplitude = 0.0;
    double        pll_period = 0.0;
    double        pll_eta = 0.0;
    double        pll_confidence = 0.0;
    double        pll_reconstructed = 0.0;
    double        elapsed_ms  = 0.0;
    int           status      = STATUS_ERROR;
};

} // namespace gpuengine
```

## Funções Exportadas (C)

```cpp
extern "C" {

GPU_EXPORT int  GpuEngine_Init(int device_id,
                               int window_size,
                               int hop_size,
                               int max_batch_size,
                               bool enable_profiling);

GPU_EXPORT void GpuEngine_Shutdown();

GPU_EXPORT int  GpuEngine_SubmitJob(const double* frames,
                                    int frame_count,
                                    int frame_length,
                                    std::uint64_t user_tag,
                                    std::uint32_t flags,
                                    const double* preview_mask,
                                    double mask_sigma_period,
                                    double mask_threshold,
                                    double mask_softness,
                                    int upscale_factor,
                                    const double* cycle_periods,
                                    int cycle_count,
                                    double cycle_width,
                                    double phase_blend,
                                    double phase_gain,
                                    double freq_gain,
                                    double amp_gain,
                                    double freq_prior_blend,
                                    double min_period,
                                    double max_period,
                                    double snr_floor,
                                    int    frames_for_snr,
                                    std::uint64_t* out_handle);

GPU_EXPORT int  GpuEngine_PollStatus(std::uint64_t handle_value,
                                     int* out_status);

GPU_EXPORT int  GpuEngine_FetchResult(std::uint64_t handle_value,
                                      double* wave_out,
                                      double* preview_out,
                                      double* cycles_out,
                                      double* noise_out,
                                      double* phase_out,
                                      double* amplitude_out,
                                      double* period_out,
                                      double* eta_out,
                                      double* recon_out,
                                      double* confidence_out,
                                      double* amp_delta_out,
                                      gpuengine::ResultInfo* info);

GPU_EXPORT int  GpuEngine_GetStats(double* avg_ms,
                                   double* max_ms);

GPU_EXPORT int  GpuEngine_GetLastError(char* buffer,
                                       int buffer_len);
}
```

### Convenções e Notas
- `frame_length` deve casar com `window_size` definido em `GpuEngine_Init`.
- `frames` deve conter `frame_count * frame_length` amostras contíguas (frames ordenados do mais antigo para o mais recente).
- `preview_mask` pode ser `nullptr`; a DLL gera automaticamente uma máscara gaussiana baseada em `mask_sigma_period`, `mask_threshold` e `mask_softness`.
- `cycle_periods` pode ser `nullptr` quando `cycle_count == 0`.
- O chamador deve garantir que `cycles_out` tenha `frame_count * frame_length * cycle_count` posições. Quando `cycle_count == 0`, passe `nullptr`.
- Parâmetros adicionais (phase"): `phase_blend`, `phase_gain`, `freq_gain`, `amp_gain`, `freq_prior_blend`, `min_period`, `max_period`, `snr_floor` e `frames_for_snr` controlam o PLL embarcado que gera fase/amplitude/ETA.
- Os buffers `phase_out`, `amplitude_out`, `period_out`, `eta_out`, `recon_out`, `confidence_out` e `amp_delta_out` devem ter `frame_count * frame_length` posições; passe `nullptr` para omitir alguma cópia.
- `flags` aceita `JOB_FLAG_STFT (1)` e `JOB_FLAG_CYCLES (2)`; novos bits podem ser adicionados no futuro.

### Status
- `STATUS_OK (0)` — operação concluída.
- `STATUS_READY (1)` — job finalizado (usado em `PollStatus`).
- `STATUS_IN_PROGRESS (2)` — job em andamento.
- Negativos indicam erro (`STATUS_INVALID_CONFIG`, `STATUS_NOT_INITIALISED`, `STATUS_QUEUE_FULL`, etc.). Utilize `GpuEngine_GetLastError` para strings diagnósticas.

## Sequência Interna (Resumo)
1. Cópia host→device (`cudaMemcpyAsync`) para o lote.
2. Execução do plano `cuFFT_D2Z` batelado.
3. Aplicação da máscara adaptativa ou personalizada (`preview_mask`).
4. Reconstrução com `cuFFT_Z2D`, normalização e cálculo do ruído (original − filtrado).
5. Para cada ciclo configurado: aplica-se máscara gaussiana centrada no bin do período e executa-se `cuFFT_Z2D` dedicado.
6. No host, a DLL avalia o SNR de cada ciclo, seleciona o dominante e roda o PLL/Adaptive Notch com os parâmetros enviados (blend, ganhos, limites de período). Isso gera fase, amplitude, período instantâneo, ETA, linha reconstruída, confiança e Δamplitude para cada amostra do frame.
7. Cópia device→host e atualização de `ResultInfo`, incluindo métricas do ciclo dominante.

## Integração MQL5
- `Include/GPU/GPU_Engine.mqh` implementa `CGpuEngineClient::SubmitJobEx`, alinhada ao protótipo acima.
- O EA `GPU_EngineHub.mq5` prepara as janelas a partir do ZigZag, monta os parâmetros (incluindo a configuração do PLL) e publica todos os buffers em `GPUShared`.
- `GPU_WaveViz.mq5` visualiza Wave/Noise/Ciclos; `GPU_PhaseViz.mq5` consome diretamente os buffers de fase/amplitude/ETA/confiança gerados pela DLL.

## Referências Relacionadas
- [`docs/GpuEngine_Architecture.md`](GpuEngine_Architecture.md) — visão detalhada de buffers, threads e sincronização.
- [`docs/GpuEngine_Streams.md`](GpuEngine_Streams.md) — estratégias de stream/batching.
- [`docs/DeployGpuDLL.md`](DeployGpuDLL.md) — distribuição da DLL para múltiplos agentes MetaTrader.
