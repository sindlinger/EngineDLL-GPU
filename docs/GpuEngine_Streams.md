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
5. cufftExecD2Z(plan_fwd, stream)
6. launch kernel máscara   (stream)
7. cufftExecZ2D(plan_inv, stream)
8. launch kernel ciclos    (stream)  // aplica máscaras por banda e executa Z2D adicionais
9. cudaMemcpyAsync(device_output, pinned_output, stream)
10. cudaEventRecord(stream_event)
11. no host, após o evento sinalizar, roda-se o PLL (Adaptive Notch) com os parâmetros do job
12. scheduler marca job como `RUNNING(stream)`
```

O worker em `GpuEngineCore` passa a:
- Verificar streams disponíveis.
- Submeter job no stream escolhido.
- Armazenar `cudaEvent_t` no `JobRecord`.
- Periodicamente consultar `cudaEventQuery` para mudar o status para `READY` sem bloquear.

## Flags de job (atual)
- `JOB_FLAG_STFT` — executa FFT/IFFT para gerar Wave/Preview/Noise.
- `JOB_FLAG_CYCLES` — ativa a etapa de máscaras gaussianas por banda e os `cufftExecZ2D`
  adicionais para cada ciclo informado.

Flags futuros podem ser adicionados seguindo o mesmo padrão (habilitando kernels extras após
a FFT principal).

## Tratamento de erro
- `cudaGetLastError` após cada etapa.
- Em caso de falha, o job é marcado como `STATUS_ERROR` e o log armazena o contexto.

## Observações finais
- O uso de streams hoje permite sobrepor transferência e cálculo espectral; o PLL roda na etapa host após o evento de conclusão de cada stream.
- Estatísticas de tempo médio/máximo por job podem ser consultadas via `GpuEngine_GetStats`.
- Caso novos kernels sejam adicionados (ex.: detecção de suportes, wavelets), basta inseri-los entre os passos 6 e 9 mantendo a mesma estrutura de streams.
