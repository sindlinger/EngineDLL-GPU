# Deploying `GpuEngine.dll` to Multiple MT5 Agents

Depois de compilar o projeto (`WaveSpecGPURefactor/bin/GpuEngine.dll`), use o script PowerShell
`scripts/DeployGpuDLL.ps1` para copiá-lo em lote para todas as instâncias/agents do MetaTrader 5.

## Passos
1. **Compile** o projeto com CMake + CUDA Toolkit (11.8+). Exemplo rápido:
   ```powershell
   cd WaveSpecGPURefactor
   cmake -S . -B build -G "Visual Studio 17 2022" -A x64
   cmake --build build --config Release
   ```
   O artefato final fica em `WaveSpecGPURefactor\bin\GpuEngine.dll`
2. **Edite** `scripts/targets.txt`, listando um caminho raiz por linha. Para cada caminho o script copia a DLL para:
   - `<raiz>\Libraries`
   - `<raiz>\MQL5\Libraries`

   Exemplo (simplificado):
   ```
   C:\Program Files\MetaTrader 5
   C:\Program Files\MetaTrader 5\Tester\Agent-0.0.0.0-2000
   C:\Users\pichau\AppData\Roaming\MetaQuotes\Tester\3CA1B4AB7DFED5C81B1C7F1007926D06\Agent-127.0.0.1-3000
   ```

3. **Execute** o script no PowerShell (da raiz do projeto):
   ```powershell
   cd "C:\Users\pichau\AppData\Roaming\MetaQuotes\Terminal\3CA1B4AB7DFED5C81B1C7F1007926D06\MQL5\WaveSpecGPURefactor"
   powershell -ExecutionPolicy Bypass -File scripts/DeployGpuDLL.ps1
   ```
   Você pode substituir `-ExecutionPolicy Bypass` pela política de sua preferência (garanta que o script possa ser executado).

4. O script registra os destinos e cria as pastas se necessário. 
   Se alguma linha do `targets.txt` não existir, ele mostra um aviso e continua.

### Alternativa em Python

Se preferir, execute a versão em Python (requer Python 3.8+ instalado):

```powershell
python scripts\deploy_gpu_dll.py
```

Os parâmetros `--source` e `--targets` seguem a mesma lógica do script PowerShell.

## Parâmetros opcionais
```
powershell -ExecutionPolicy Bypass -File scripts/DeployGpuDLL.ps1 `
    -SourceDll "C:\caminho\custom\GpuEngine.dll" `
    -TargetsFile "scripts\meus_targets.txt"
```
- `-SourceDll`: caminho completo da DLL a copiar (por padrão usa `bin\GpuEngine.dll`).
- `-TargetsFile`: arquivo com a lista de caminhos (por padrão `scripts/targets.txt`).

## Observações
- O script não remove DLLs antigas, apenas sobrescreve `GpuEngine.dll` com `/Force`.
- É recomendado fechar o MetaTrader/Agents antes de sobrescrever a DLL.
- Mantenha o `targets.txt` sob controle de versão se quiser replicar a configuração em outras máquinas.
