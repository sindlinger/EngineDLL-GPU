# GpuEngine Streams & Buffer Management

Este documento descreve a arquitetura pretendida para a versão CUDA do `GpuEngine.dll`,
com foco em execução assíncrona, uso de múltiplos streams e buffers pinados.

## Objetivos
- **Pipeline contínuo**: sobrepor transferência host↔device com execução de kernels.
- **Múltiplos jobs simultâneos**: permitir que vários lotes sejam processados em paralelo
  (um lote por stream).
- **Baixa latência**: evitar `cudaDeviceSynchronize`; usar `cudaEventRecord` por stream para
  sinalizar conclusão.

## Estrutura proposta
```
GpuContext
 ├─ std::vector<StreamContext> streams
 │    ├─ cudaStream_t stream
 │    ├─ cudaEvent_t  finished_event
 │    ├─ pinned_host_buffers (input/output)
 │    └─ device_buffers      (input/output)
 ├─ cufftHandle fft_plan_fwd
 ├─ cufftHandle fft_plan_inv
 └─ JobQueue (lock-free ou mutex com condvar)
```

Cada `StreamContext` mantém seus próprios buffers pinados e device buffers para minimizar
realocações. O scheduler atribui jobs a streams livres; quando o evento registra conclusão,
o stream volta para o pool.

## Fluxo por job (pseudocode)
```
1. memcpy host -> pinned buffer (async ou memcpy normal se dados já pinados)
2. cudaMemcpyAsync(pinned_input, device_input, stream)
3. launch kernel detrend (stream)
4. launch kernel janela    (stream)
5. cufftExecZ2Z(plan_fwd, stream)
6. launch kernel máscara   (stream)
7. cufftExecZ2Z(plan_inv, stream)
8. launch kernel métricas  (stream)  // opcional (magnitude, ciclos, etc.)
9. cudaMemcpyAsync(device_output, pinned_output, stream)
10. cudaEventRecord(stream_event)
11. scheduler marca job como `RUNNING(stream)`
```

O worker em `GpuEngineCore` passa a:
- Verificar streams disponíveis.
- Submeter job no stream escolhido.
- Armazenar `cudaEvent_t` no `JobRecord`.
- Periodicamente consultar `cudaEventQuery` para mudar o status para `READY` sem bloquear.

## Flags de job sugeridas
- `JOB_FLAG_STFT` (FFT completa + IFFT + Wave/Preview)
- `JOB_FLAG_CYCLES` (cálculo de cada banda/ciclo)
- `JOB_FLAG_SUPDEM`, `JOB_FLAG_WAVELET`, etc.

Cada flag habilita kernels adicionais após a FFT.

## Tratamento de erro
- `cudaGetLastError` após cada etapa.
- Em caso de falha, o job é marcado como `STATUS_ERROR` e o log armazena o contexto.

## Próximos passos
1. Implementar `StreamContext` em C++.
2. Substituir o placeholder atual (copia de input->output) pela sequência real de kernels.
3. Expor estatísticas por stream (tempo médio, throughput).
