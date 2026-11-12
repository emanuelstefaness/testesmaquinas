param([switch]$SoListar, [switch]$Autoteste)

$ErrorActionPreference = 'Stop'
$Base = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $Base 'logs'
New-Item -ItemType Directory -Force $LogDir | Out-Null
$script:LogArquivo = Join-Path $LogDir 'geral.txt'

$Bauds = 9600, 1200, 2400, 4800, 19200
$Formatos = @(
    @{ Nome = '8N1'; Bits = 8; Paridade = [System.IO.Ports.Parity]::None },
    @{ Nome = '7E1'; Bits = 7; Paridade = [System.IO.Ports.Parity]::Even }
)

# Comando = o que mandar pra máquina responder sozinha; Janela = segundos esperando o resultado
$Maquinas = [ordered]@{
    '1' = @{ Nome = 'Balança Mettler Toledo'; Arquivo = 'mettler'; Comando = 'SI'; Baud = 9600; Janela = 2
             Acao = 'deixe algo no prato (a balança responde ao comando SI)' }
    '2' = @{ Nome = 'Contador Pfeuffer'; Arquivo = 'contador'; Comando = $null; Baud = 9600; Janela = 60
             Acao = 'faça uma contagem completa (Start) e espere terminar' }
    '3' = @{ Nome = 'Balança Shimadzu'; Arquivo = 'shimadzu'; Comando = $null; Baud = 1200; Janela = 10
             Acao = 'aperte a tecla PRINT da balança' }
    '4' = @{ Nome = 'Outra máquina'; Arquivo = 'outra'; Comando = $null; Baud = 9600; Janela = 20
             Acao = 'faça a máquina enviar um resultado' }
}

function Escrever-Log([string]$texto) {
    $linha = '{0:yyyy-MM-dd HH:mm:ss.fff}  {1}' -f (Get-Date), $texto
    Add-Content -LiteralPath $script:LogArquivo -Value $linha -Encoding UTF8
}

function Formatar-Bytes([byte[]]$bytes) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        if ($b -eq 13) { [void]$sb.Append('<CR>') }
        elseif ($b -eq 10) { [void]$sb.Append('<LF>') }
        elseif ($b -ge 32 -and $b -lt 127) { [void]$sb.Append([char]$b) }
        else { [void]$sb.Append(('<{0:X2}>' -f $b)) }
    }
    $sb.ToString()
}

function Hex([byte[]]$bytes) { ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' ' }

# % de bytes que são texto comum; configuração errada costuma gerar lixo binário
function Nota-Legibilidade([byte[]]$bytes) {
    if (-not $bytes -or $bytes.Length -eq 0) { return 0 }
    $ok = @($bytes | Where-Object { ($_ -ge 32 -and $_ -lt 127) -or $_ -in 9, 10, 13 }).Count
    [math]::Round(100 * $ok / $bytes.Length)
}

function Get-Portas {
    $nomes = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique
    $pnp = @(Get-CimInstance Win32_PnPEntity -Filter "Name LIKE '%(COM%'" -ErrorAction SilentlyContinue)
    foreach ($n in $nomes) {
        $d = ($pnp | Where-Object { $_.Name -match "\($n\)" } | Select-Object -First 1).Name
        if (-not $d) { $d = '(sem descrição)' }
        [pscustomobject]@{ Porta = $n; Descricao = $d }
    }
}

function Abrir-Porta($porta, [int]$baud, $formato) {
    $sp = New-Object System.IO.Ports.SerialPort($porta, $baud, $formato.Paridade, $formato.Bits, [System.IO.Ports.StopBits]::One)
    $sp.Handshake = [System.IO.Ports.Handshake]::None
    $sp.DtrEnable = $true
    $sp.RtsEnable = $true
    $sp.ReadTimeout = 200
    $sp.WriteTimeout = 1000
    $sp.Open()
    $sp.DiscardInBuffer()
    $sp
}

function Ler-Bytes($sp, $lista) {
    $n = $sp.BytesToRead
    if ($n -le 0) { return 0 }
    $tmp = New-Object byte[] $n
    $lidos = $sp.Read($tmp, 0, $n)
    for ($i = 0; $i -lt $lidos; $i++) { $lista.Add($tmp[$i]) }
    $lidos
}

function Tecla-Esc {
    [Console]::KeyAvailable -and [Console]::ReadKey($true).Key -eq 'Escape'
}

# Lê até o tempo acabar, ou 1 s depois que os dados param de chegar
function Ler-Por($sp, [double]$segundos) {
    $lista = New-Object System.Collections.Generic.List[byte]
    $fim = (Get-Date).AddSeconds($segundos)
    $ultimo = $null
    while ((Get-Date) -lt $fim) {
        if ((Ler-Bytes $sp $lista) -gt 0) { $ultimo = Get-Date }
        else {
            if ($ultimo -and ((Get-Date) - $ultimo).TotalMilliseconds -gt 1000) { break }
            Start-Sleep -Milliseconds 50
        }
        if (Tecla-Esc) { break }
    }
    , $lista.ToArray()
}

function Mostrar-Recebido([byte[]]$bytes) {
    $texto = Formatar-Bytes $bytes
    $nota = Nota-Legibilidade $bytes
    $cor = if ($nota -ge 90) { 'Green' } else { 'Yellow' }
    Write-Host ('  {0:HH:mm:ss}  {1}' -f (Get-Date), $texto) -ForegroundColor $cor
    Write-Host ('            {0} bytes, {1}% legível' -f $bytes.Length, $nota) -ForegroundColor DarkGray
    Escrever-Log ("RX {0}" -f $texto)
    Escrever-Log ("   HEX {0}" -f (Hex $bytes))
}

function Descobrir($porta, $maq) {
    Write-Host ''
    Write-Host 'Testando as configurações mais comuns. Esc pula uma tentativa.' -ForegroundColor Cyan
    if (-not $maq.Comando) {
        Write-Host "Em cada tentativa: $($maq.Acao)." -ForegroundColor Cyan
    }
    Escrever-Log "DESCOBRIR $porta ($($maq.Nome))"
    $resultados = @()
    $ordem = @($maq.Baud) + @($Bauds | Where-Object { $_ -ne $maq.Baud })
    foreach ($baud in $ordem) {
        foreach ($f in $Formatos) {
            $rotulo = "$baud $($f.Nome)"
            try { $sp = Abrir-Porta $porta $baud $f }
            catch {
                Write-Host "  [$rotulo] erro ao abrir a porta: $($_.Exception.Message)" -ForegroundColor Red
                Escrever-Log "[$rotulo] ERRO $($_.Exception.Message)"
                return $null
            }
            try {
                if ($maq.Comando) {
                    $sp.Write($maq.Comando + "`r`n")
                    $bytes = Ler-Por $sp $maq.Janela
                }
                else {
                    Write-Host "  [$rotulo] agora: $($maq.Acao)... (até $($maq.Janela) s)" -ForegroundColor Yellow
                    $bytes = Ler-Por $sp $maq.Janela
                }
            }
            finally { $sp.Close() }
            $nota = Nota-Legibilidade $bytes
            $amostra = Formatar-Bytes $bytes
            if ($amostra.Length -gt 60) { $amostra = $amostra.Substring(0, 60) + '...' }
            if ($bytes.Length -eq 0) { Write-Host "  [$rotulo] nada recebido" -ForegroundColor DarkGray }
            else {
                $cor = if ($nota -ge 90) { 'Green' } else { 'Yellow' }
                Write-Host "  [$rotulo] $($bytes.Length) bytes, $nota% legível: $amostra" -ForegroundColor $cor
            }
            Escrever-Log ("[{0}] {1} bytes, {2}% legível: {3}" -f $rotulo, $bytes.Length, $nota, (Formatar-Bytes $bytes))
            $resultados += [pscustomobject]@{ Baud = $baud; Formato = $f; Bytes = $bytes.Length; Nota = $nota }
            # Resposta limpa ao comando: não precisa testar o resto
            if ($maq.Comando -and $nota -ge 95 -and $bytes.Length -ge 3) { break }
        }
        if ($maq.Comando -and ($resultados | Where-Object { $_.Nota -ge 95 -and $_.Bytes -ge 3 })) { break }
    }
    $melhor = $resultados | Where-Object { $_.Bytes -gt 0 } | Sort-Object Nota, Bytes -Descending | Select-Object -First 1
    Write-Host ''
    if (-not $melhor) {
        Write-Host 'Nenhuma configuração recebeu dados.' -ForegroundColor Red
        Write-Host 'Confira: cabo bem encaixado, máquina ligada, saída serial habilitada no menu dela.' -ForegroundColor Red
        Write-Host 'Se continuar sem nada, provavelmente falta o null modem.' -ForegroundColor Red
        Escrever-Log 'RESULTADO nenhuma configuração recebeu dados'
        return $null
    }
    Write-Host ("Melhor configuração: {0} {1} ({2}% legível)" -f $melhor.Baud, $melhor.Formato.Nome, $melhor.Nota) -ForegroundColor Green
    Escrever-Log ("RESULTADO {0} {1} ({2}% legível)" -f $melhor.Baud, $melhor.Formato.Nome, $melhor.Nota)
    $melhor
}

function Escutar($porta, [int]$baud, $formato) {
    $sp = Abrir-Porta $porta $baud $formato
    Write-Host ''
    Write-Host "Escutando $porta em $baud $($formato.Nome). Faça a máquina enviar resultados. Esc para parar." -ForegroundColor Cyan
    Escrever-Log "ESCUTAR $porta $baud $($formato.Nome)"
    $pend = New-Object System.Collections.Generic.List[byte]
    $ultimo = Get-Date
    try {
        while ($true) {
            if ((Ler-Bytes $sp $pend) -gt 0) { $ultimo = Get-Date }
            else { Start-Sleep -Milliseconds 50 }
            $parado = ((Get-Date) - $ultimo).TotalMilliseconds -gt 400
            if ($pend.Count -gt 0 -and ($pend.Contains([byte]10) -or $parado)) {
                Mostrar-Recebido $pend.ToArray()
                $pend.Clear()
            }
            if (Tecla-Esc) { break }
        }
    }
    finally { $sp.Close() }
}

function Enviar-Comando($porta, [int]$baud, $formato, [string]$cmd) {
    $sp = Abrir-Porta $porta $baud $formato
    try {
        $sp.Write($cmd + "`r`n")
        Escrever-Log "TX $cmd ($baud $($formato.Nome))"
        $bytes = Ler-Por $sp 3
    }
    finally { $sp.Close() }
    if ($bytes.Length -gt 0) { Mostrar-Recebido $bytes }
    else {
        Write-Host '  Sem resposta.' -ForegroundColor Yellow
        Escrever-Log 'RX (nada)'
    }
}

function Escolher([string]$pergunta, [string[]]$validas) {
    while ($true) {
        $r = (Read-Host $pergunta).Trim()
        if ($r -in $validas) { return $r }
        Write-Host '  Opção inválida.' -ForegroundColor Red
    }
}

if ($Autoteste) {
    $falhas = 0
    $exemplo = [byte[]][char[]]"S S     100.00 g`r`n"
    $t = Formatar-Bytes $exemplo
    if ($t -ne 'S S     100.00 g<CR><LF>') { $falhas++; Write-Host "FALHA Formatar-Bytes: $t" }
    if ((Nota-Legibilidade $exemplo) -ne 100) { $falhas++; Write-Host 'FALHA nota de texto limpo' }
    $lixo = [byte[]](0xF8, 0x00, 0x80, 0xFE, 0x41, 0x9C, 0xE0, 0x03)
    if ((Nota-Legibilidade $lixo) -gt 20) { $falhas++; Write-Host 'FALHA nota de lixo binário' }
    if ((Nota-Legibilidade ([byte[]]@())) -ne 0) { $falhas++; Write-Host 'FALHA nota vazia' }
    if ((Hex ([byte[]](0x0D, 0x0A))) -ne '0D 0A') { $falhas++; Write-Host 'FALHA Hex' }
    if ($falhas -eq 0) { Write-Host 'Autoteste OK' } else { exit 1 }
    return
}

$portas = @(Get-Portas)
if ($SoListar) {
    if ($portas.Count -eq 0) { Write-Host 'Nenhuma porta COM encontrada.' } else { $portas | Format-Table -AutoSize }
    return
}

Write-Host ''
Write-Host '=== Teste de comunicação serial das máquinas ===' -ForegroundColor Cyan
if ($portas.Count -eq 0) {
    Write-Host 'Nenhuma porta COM encontrada. Ligue o conversor USB-serial e rode de novo.' -ForegroundColor Red
    return
}
Write-Host ''
for ($i = 0; $i -lt $portas.Count; $i++) {
    Write-Host ("  {0}) {1}  {2}" -f ($i + 1), $portas[$i].Porta, $portas[$i].Descricao)
}
$ip = Escolher 'Número da porta' (1..$portas.Count | ForEach-Object { "$_" })
$porta = $portas[[int]$ip - 1].Porta

Write-Host ''
foreach ($k in $Maquinas.Keys) { Write-Host "  $k) $($Maquinas[$k].Nome)" }
$maq = $Maquinas[(Escolher 'Qual máquina está ligada' @($Maquinas.Keys))]

$script:LogArquivo = Join-Path $LogDir ('{0}_{1:yyyyMMdd_HHmmss}.txt' -f $maq.Arquivo, (Get-Date))
Escrever-Log "INICIO $($maq.Nome) em $porta"
$baud = $maq.Baud
$formato = $Formatos[0]

while ($true) {
    Write-Host ''
    Write-Host "$($maq.Nome) em $porta | configuração atual: $baud $($formato.Nome)" -ForegroundColor Cyan
    Write-Host '  1) Descobrir a configuração automaticamente'
    Write-Host '  2) Escutar com a configuração atual'
    Write-Host '  3) Enviar um comando'
    Write-Host '  4) Trocar a configuração na mão'
    Write-Host '  0) Sair'
    $op = Escolher 'Opção' @('1', '2', '3', '4', '0')
    try {
        switch ($op) {
            '1' {
                $m = Descobrir $porta $maq
                if ($m) { $baud = $m.Baud; $formato = $m.Formato }
            }
            '2' { Escutar $porta $baud $formato }
            '3' {
                if ($maq.Comando) {
                    Write-Host '  Comandos da Mettler: SI = peso agora, S = peso estável, I2 = modelo, I4 = nº de série'
                }
                $cmd = (Read-Host 'Comando').Trim()
                if ($cmd) { Enviar-Comando $porta $baud $formato $cmd }
            }
            '4' {
                $b = (Read-Host "Velocidade ($($Bauds -join ', '))").Trim()
                if ($b -match '^\d+$') { $baud = [int]$b }
                $fo = Escolher 'Formato: 1) 8N1  2) 7E1' @('1', '2')
                $formato = $Formatos[[int]$fo - 1]
            }
            '0' {
                Escrever-Log 'FIM'
                Write-Host "Registro salvo em: $script:LogArquivo" -ForegroundColor Green
                return
            }
        }
    }
    catch {
        Write-Host "  Erro: $($_.Exception.Message)" -ForegroundColor Red
        Escrever-Log "ERRO $($_.Exception.Message)"
    }
}
