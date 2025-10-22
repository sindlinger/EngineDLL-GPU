# Arquitetura da Ponte GPU ↔ MT5

Este documento resume como a `GpuEngine.dll` se integra com o código MQL5 (EA Hub,
indicadores, agentes) e como evoluir os módulos CUDA.

## Visão Geral

```
+-------------------+        +-------------------+        +-------------------+
|  Indicadores/EAs  | <----> |    EA Hub (MQL)   | <----> |   GpuEngine.dll   |
+-------------------+        +-------------------+        +-------------------+
                                                CUDA Streams / cuFFT / Kernels
```

1. **GpuEngine.dll** (C++/CUDA)
   - Mantém fila de jobs com buffers pinados e múltiplos streams.
   - Executa: detrend → janela → FFT → máscara → IFFT → cálculo de ruído/ciclos.
   - No host (parte da DLL) calcula energia/SNR, seleciona o ciclo dominante e roda o PLL/Adaptive Notch para gerar fase, amplitude, período instantâneo, ETA, linha reconstruída, confiança e Δamplitude.
   - Expõe API assíncrona: `Init`, `SubmitJob`, `PollStatus`, `FetchResult`, `Shutdown`.

2. **EA Hub (ex.: `WaveSpecGPU_Hub.mq5`)**
   - Único responsável por conversar com a DLL.
   - Monta batches (frames STFT), chama `SubmitJob`, monitora `PollStatus`, e publica os
     buffers prontos em estruturas compartilhadas (`WaveSpecShared` ou variáveis globais).
   - Pode gerar eventos (`EventChartCustom`) para outros módulos.

3. **Indicadores / Agentes de Negociação**
   - Consumidores dos dados publicados; não falam com a GPU.
   - `WaveSpecZZ_GaussGPU` mostra Wave/Noise/Ciclos; `PhaseViz_GPU` exibe fase/amplitude/ETA/confiança.
   - Outros agentes podem ler `WaveSpecShared` para usar as mesmas métricas.

## API Exposta pela DLL (resumo)

```c
int  GpuEngine_Init(int device_id, int window_size, int hop_size,
                    int max_batch_size, bool enable_profiling);
void GpuEngine_Shutdown();
int  GpuEngine_SubmitJob(const double* frames, int frame_count, int frame_length,
                         uint64_t user_tag, uint32_t flags,
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
                         uint64_t* out_handle);
int  GpuEngine_PollStatus(uint64_t handle, int* out_status);
int  GpuEngine_FetchResult(uint64_t handle,
                           double* wave_out, double* preview_out,
                           double* cycles_out, double* noise_out,
                           double* phase_out, double* amplitude_out,
                           double* period_out, double* eta_out,
                           double* recon_out, double* confidence_out,
                           double* amp_delta_out,
                           ResultInfo* info);
int  GpuEngine_GetStats(double* avg_ms, double* max_ms);
int  GpuEngine_GetLastError(char* buffer, int buffer_len);
```
- `flags` permite habilitar sub-pipelines (ex.: `JOB_FLAG_STFT`, `JOB_FLAG_CYCLES`).
- O EA recebe `GpuEngineResultInfo` (frames processados, tempo, status, `user_tag`).

## Pipeline CUDA Interno

1. Copia frames (`frame_count × frame_length`) para buffer pinado.
2. Enfileira no stream livre: `cudaMemcpyAsync` → `cufftExecD2Z` batelado → kernel de máscara
   (gaussiana adaptativa ou personalizada) → `cufftExecZ2D` → kernels de ruído/ciclos (um
   `cufftExecZ2D` adicional por ciclo configurado).
3. No host, o worker avalia o SNR de cada ciclo, escolhe o dominante e roda o PLL/Adaptive Notch
   com os parâmetros fornecidos (blend, ganhos, limites de período), produzindo fase/amplitude,
   período instantâneo, ETA, reconstrução e métricas de confiança para cada amostra do frame.
4. `cudaMemcpyAsync` de volta para o host → `cudaEventRecord`. Worker marca status READY quando
   o evento sinaliza fim e os buffers PLL já foram preenchidos.
5. Estatísticas: tempo médio/máximo por job, contagem de jobs concluídos.

## Boas Práticas MQL5

- **EA Hub**
  - Iniciar a engine no `OnInit` e chamar `Shutdown` no `OnDeinit`.
  - Submeter jobs em `OnTick`/`OnTimer` sem bloquear (não usar `GpuEngine_Wait`).
  - Publicar os buffers resultantes antes de sinalizar indicadores/agentes.
- **Consumidores**
  - Ler `WaveSpecShared::last_update` e somente redesenhar/atuar quando houver mudança.
  - Não fazer cálculos pesados; quem processa é a GPU.
- **Eventos/Globais**
  - Caso use `EventChartCustom`, mande o `user_tag` do job para permitir sincronização.
  - Variáveis globais do MT5 são úteis para sinais simples (ex.: `GlobalVariableSet("WaveTrend", wave_value)`).

## Expansão da DLL

- Adicionar novas flags (ex.: `JOB_FLAG_SUPDEM`) e kernels correspondentes dentro do pipeline.
- Criar novos buffers de saída (`ResultInfo` pode incluir offsets ou tamanhos adicionais).
- Expor funções extras (`GpuEngine_ComputeMagnitudeBatch`, etc.) se precisar de operações
  independentes do fluxo STFT.

## Fluxo de Desenvolvimento

1. Editar/expandir o código C++/CUDA (`gpu_engine/src`).
2. Recompilar a DLL (`cmake --build build --config Release`).
3. Copiar para todas as instâncias usando o script (`deploy_gpu_dll.py` ou `.ps1`).
4. Recompilar indicadores/EAs no MetaEditor e testar.

## Referências
- [GpuEngine_API.md](GpuEngine_API.md) – detalhes da API e estrutura das structs.
- [GpuEngine_Streams.md](GpuEngine_Streams.md) – explicações sobre o uso de streams, buffers pinados, cuFFT.
- [DeployGpuDLL.md](DeployGpuDLL.md) – como distribuir a DLL para várias instâncias/agents.
