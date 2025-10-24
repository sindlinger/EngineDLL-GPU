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
    double sigma_period   = 48.0;
    double threshold      = 0.05;
    double softness       = 0.20;
    double min_period     = 8.0;
    double max_period     = 512.0;
    int    max_candidates = 12;
};

struct CycleParams {
    const double* periods = nullptr;
    int           count   = 0;
    double        width   = 0.25;
};

enum class KalmanPreset : int {
    Smooth   = 0,
    Balanced = 1,
    Reactive = 2,
    Manual   = 3
};

struct KalmanParams {
    KalmanPreset preset            = KalmanPreset::Balanced;
    double       process_noise     = 1.0e-4;
    double       measurement_noise = 2.5e-3;
    double       init_variance     = 0.5;
    double       plv_threshold     = 0.65;
    int          max_iterations    = 48;
    double       convergence_eps   = 1.0e-4;
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
    KalmanParams  kalman{};
};

struct ResultInfo {
    std::uint64_t user_tag    = 0ULL;
    int           frame_count = 0;
    int           frame_length= 0;
    int           cycle_count = 0;
    int           dominant_cycle = -1;
    double        dominant_period = 0.0;
    double        dominant_snr = 0.0;
    double        dominant_confidence = 0.0;
    double        line_phase_deg = 0.0;
    double        line_amplitude = 0.0;
    double        line_period = 0.0;
    double        line_eta = 0.0;
    double        line_confidence = 0.0;
    double        line_value = 0.0;
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
                                    double mask_min_period,
                                    double mask_max_period,
                                    int upscale_factor,
                                    const double* cycle_periods,
                                    int cycle_count,
                                    double cycle_width,
                                    int kalman_preset,
                                    double kalman_process_noise,
                                    double kalman_measurement_noise,
                                    double kalman_init_variance,
                                    double kalman_plv_threshold,
                                    int    kalman_max_iterations,
                                    double kalman_epsilon,
                                    std::uint64_t* out_handle);

GPU_EXPORT int  GpuEngine_PollStatus(std::uint64_t handle_value,
                                     int* out_status);

GPU_EXPORT int  GpuEngine_FetchResult(std::uint64_t handle_value,
                                      double* wave_out,
                                      double* preview_out,
                                      double* cycles_out,
                                      double* noise_out,
                                      double* phase_out,
                                      double* phase_unwrapped_out,
                                      double* amplitude_out,
                                      double* period_out,
                                      double* frequency_out,
                                      double* eta_out,
                                      double* recon_out,
                                      double* kalman_out,
                                      double* confidence_out,
                                      double* amp_delta_out,
                                      double* turn_signal_out,
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
- `preview_mask` pode ser `nullptr`; a DLL gera automaticamente uma máscara gaussiana baseada em `mask_sigma_period`, `mask_threshold`, `mask_softness`, `mask_min_period` e `mask_max_period`.
- `cycle_periods` pode ser `nullptr`. Quando `cycle_count > 0` e o primeiro elemento não é `EMPTY_VALUE`, os períodos são tratados como fixos. Caso contrário (`cycle_periods == nullptr` ou contém `EMPTY_VALUE`), o motor seleciona automaticamente os `cycle_count` bins de maior energia dentro da banda.
- O chamador deve garantir que `cycles_out` tenha `frame_count * frame_length * cycle_count` posições. Quando `cycle_count == 0`, passe `nullptr`.
- Parâmetros adicionais (Kalman/EKF): `kalman_preset` seleciona uma configuração (`0` suave, `1` balanceada, `2` reativa, `3` manual). Quando em modo manual, os valores informados em `kalman_process_noise`, `kalman_measurement_noise`, `kalman_init_variance`, `kalman_plv_threshold`, `kalman_max_iterations` e `kalman_epsilon` são utilizados para o filtro estocástico que estima fase/amplitude/ETA sem PLL.
- Os buffers `phase_out`, `phase_unwrapped_out`, `amplitude_out`, `period_out`, `frequency_out`, `eta_out`, `recon_out`, `kalman_out`, `confidence_out`, `amp_delta_out` e `turn_signal_out` devem ter `frame_count * frame_length` posições; passe `nullptr` para omitir alguma cópia.
- `flags` aceita `JOB_FLAG_STFT (1)` e `JOB_FLAG_CYCLES (2)`; novos bits podem ser adicionados no futuro.

### Status
- `STATUS_OK (0)` — operação concluída.
- `STATUS_READY (1)` — job finalizado (usado em `PollStatus`).
- `STATUS_IN_PROGRESS (2)` — job em andamento.
- Negativos indicam erro (`STATUS_INVALID_CONFIG`, `STATUS_NOT_INITIALISED`, `STATUS_QUEUE_FULL`, etc.). Utilize `GpuEngine_GetLastError` para strings diagnósticas.

## Sequência Interna (Resumo)
1. Cópia host→device (`cudaMemcpyAsync`) para o lote.
2. Execução do plano `cuFFT_D2Z` batelado.
3. Supressão do componente DC e aplicação da máscara gaussiana/banda definida por `mask_*`.
4. Reconstrução com `cuFFT_Z2D`, normalização e cálculo do ruído (original − filtrado).
5. O espectro mascarado é copiado para o host, agrega-se energia por bin e são mantidos os `max_candidates` de maior energia dentro dos limites de período solicitados. Para cada candidato selecionado é aplicada uma máscara gaussiana dedicada e executado `cuFFT_Z2D` para gerar o ciclo no domínio do tempo.
6. No host, cada ciclo passa por um filtro de Kalman harmônico (preset ou manual). O EKF gera fase/amplitude/ETA/contagem, calcula o PLV e descarta automaticamente ciclos que não convergem ou ficam abaixo do `plv_threshold`. O ciclo dominante alimenta os buffers “linha” (fase, amplitude, período, confiança, valor reconstruído).
7. Cópia device→host e atualização de `ResultInfo`, incluindo métricas do ciclo dominante.

## Integração MQL5
- `Include/GPU/GPU_Engine.mqh` implementa `CGpuEngineClient::SubmitJobEx`, alinhada ao protótipo acima.
- O EA `GPU_EngineHub.mq5` prepara as janelas a partir do ZigZag, monta os parâmetros (incluindo a configuração do PLL) e publica todos os buffers em `GPUShared`.
- `GPU_WaveViz.mq5` visualiza Wave/Noise/Ciclos; `GPU_PhaseViz.mq5` consome diretamente os buffers de fase/amplitude/ETA/confiança gerados pela DLL.

## Referências Relacionadas
- [`docs/GpuEngine_Architecture.md`](GpuEngine_Architecture.md) — visão detalhada de buffers, threads e sincronização.
- [`docs/GpuEngine_Streams.md`](GpuEngine_Streams.md) — estratégias de stream/batching.
- [`docs/DeployGpuDLL.md`](DeployGpuDLL.md) — distribuição da DLL para múltiplos agentes MetaTrader.
