#!/usr/bin/env bash
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# GoPro Grow: cria um MP4 por dia, a partir da data presente no nome dos JPGs.
# Exemplos: 20261107_155805_TL_....JPG / 20261107_170005_AVULSA_....JPG
#
# TL:     1 foto = 1 frame. A 30 fps, 30 fotos (uma hora) = 1 segundo.
# AVULSA: 1 foto = 30 frames repetidos. Cada foto fica 1 segundo na tela.
#
# Uso: ./gopro-timelapse.sh cron
#      ./gopro-timelapse.sh dia 20261107
# -----------------------------------------------------------------------------

# AJUSTE: diretório que recebe as fotos por rsync. Pode ter subpastas por dia.
DIR_FOTOS="/home/gabriel/fotos"

# Guarde os MP4 FORA da árvore sincronizada via rsync --delete.
DIR_VIDEOS="${DIR_FOTOS%/}-videos"

# 0: conserva JPGs; 1: apaga apenas JPGs incluídos no vídeo validado.
# Também funciona se você ativar 1 depois de já ter gerado os vídeos.
REMOVER_PROCESSADOS=0

FPS=30
LARGURA=1920
ALTURA=1080
CRF=20                      # Qualidade H.264: menor = melhor e maior arquivo.
PRESET="medium"             # Mais lento = melhor compressão (ex.: slow).
ATRASO_FECHAMENTO_MIN=100   # Só fecha um dia 1h40 após a meia-noite seguinte.
SEM_ALTERACOES_MIN=15       # Não trabalha com arquivos recebidos recentemente.

log() { printf '[%(%F %T)T] %s\n' -1 "$*"; }

# Impede duas execuções simultâneas e remove os links temporários no final.
TEMP_DIR=""
limpar_temporarios() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap limpar_temporarios EXIT

for programa in ffmpeg ffprobe flock find stat sha256sum; do
    command -v "$programa" >/dev/null || { log "ERRO: instale $programa"; exit 1; }
done
[[ -d "$DIR_FOTOS" ]] || { log "ERRO: pasta inexistente: $DIR_FOTOS"; exit 1; }
mkdir -p -- "$DIR_VIDEOS"
DIR_FOTOS="$(cd -- "$DIR_FOTOS" && pwd -P)"
DIR_VIDEOS="$(cd -- "$DIR_VIDEOS" && pwd -P)"

exec 9>"$DIR_VIDEOS/.gopro-timelapse.lock"
flock -n 9 || { log "Outra execução já está em andamento; saindo."; exit 0; }

# Confere FPS, quantidade EXATA de frames e integridade decodificando o MP4.
# A exclusão de fotos só acontece após passar por todas as verificações.
verificar_video() {
    local video="$1" esperado="$2" quantidade taxa
    [[ -s "$video" ]] || return 1
    quantidade="$(ffprobe -v error -select_streams v:0 -count_frames \
        -show_entries stream=nb_read_frames -of default=noprint_wrappers=1:nokey=1 \
        "$video")" || return 1
    taxa="$(ffprobe -v error -select_streams v:0 \
        -show_entries stream=avg_frame_rate -of default=noprint_wrappers=1:nokey=1 \
        "$video")" || return 1
    [[ "$quantidade" == "$esperado" && "$taxa" == "$FPS/1" ]] || return 1
    ffmpeg -v error -xerror -i "$video" -f null - >/dev/null 2>&1 || return 1
}

processar_dia() {
    local dia="$1" data_iso inicio_proximo limite agora
    local arquivo nome repeticoes link i total_frames=0 total_fotos=0
    local assinatura ctime video manifest hash_ant frames_ant fotos_ant
    local -a nomes=()
    local -A caminho_por_nome=()

    [[ "$dia" =~ ^[0-9]{8}$ ]] || { log "Data inválida: $dia"; return 1; }
    data_iso="${dia:0:4}-${dia:4:2}-${dia:6:2}"
    [[ "$(date -d "$data_iso" +%Y%m%d 2>/dev/null)" == "$dia" ]] || {
        log "Data inválida: $dia"; return 1;
    }

    # Fechamento é por DATA DO NOME, não pela pasta nem pela hora do rsync.
    # Nunca gera vídeo do dia de hoje, mesmo que ainda não tenham chegado fotos.
    inicio_proximo="$(date -d "$data_iso +1 day" +%s)"
    agora="$(date +%s)"
    limite=$(( inicio_proximo + ATRASO_FECHAMENTO_MIN * 60 ))
    (( agora >= limite )) || return 0

    # Localiza as fotos em qualquer subpasta e ignora arquivos .part/incompletos.
    # Usa o nome (que começa com timestamp) para ordenar, não o caminho.
    while IFS= read -r -d '' arquivo; do
        nome="${arquivo##*/}"
        [[ "$nome" =~ ^${dia}_[0-9]{6}_(TL|AVULSA)_.+\.[Jj][Pp][Gg]$ ]] || continue
        if [[ -n "${caminho_por_nome[$nome]+presente}" ]]; then
            log "ERRO $dia: nome duplicado em pastas diferentes: $nome"
            return 1
        fi
        caminho_por_nome["$nome"]="$arquivo"
    done < <(find "$DIR_FOTOS" -type f -iname "${dia}_*.jpg" -print0)

    (( ${#caminho_por_nome[@]} > 0 )) || return 0
    mapfile -t nomes < <(printf '%s\n' "${!caminho_por_nome[@]}" | LC_ALL=C sort)
    total_fotos="${#nomes[@]}"

    # Se alguma foto teve alterações recentes (ex.: chegada via rsync), adia.
    for nome in "${nomes[@]}"; do
        arquivo="${caminho_por_nome[$nome]}"
        ctime="$(stat -c %Z -- "$arquivo")" || return 1
        if (( ctime > agora - SEM_ALTERACOES_MIN * 60 )); then
            log "$dia: rsync/arquivo recente; tentando novamente no próximo cron."
            return 0
        fi
    done

    # Assinatura de nomes e tamanhos: protege contra fotos novas ou modificadas
    # após um MP4 já ter sido feito, sem ler gigabytes de conteúdo em todo cron.
    assinatura="$(
        for nome in "${nomes[@]}"; do
            printf '%s\t%s\n' "$nome" "$(stat -c %s -- "${caminho_por_nome[$nome]}")"
        done | sha256sum | cut -d ' ' -f 1
    )" || return 1

    # Calcula quantos frames o vídeo DEVE conter antes da codificação.
    for nome in "${nomes[@]}"; do
        if [[ "$nome" == *_AVULSA_* ]]; then
            (( total_frames += FPS ))
        else
            (( total_frames += 1 ))
        fi
    done

    video="$DIR_VIDEOS/$data_iso.mp4"
    manifest="$DIR_VIDEOS/$data_iso.manifest"

    # Se o vídeo já existe, nunca o sobrescreve automaticamente.
    # Quando a exclusão for ativada depois, usa o manifesto para garantir que
    # todos os JPGs ainda correspondem exatamente ao vídeo gerado anteriormente.
    if [[ -e "$video" ]]; then
        if [[ ! -f "$manifest" ]]; then
            log "AVISO $dia: MP4 existe sem manifesto; não vou apagar JPGs."
            return 1
        fi
        read -r hash_ant frames_ant fotos_ant < "$manifest" || return 1
        if [[ "$hash_ant" != "$assinatura" || "$frames_ant" != "$total_frames" || "$fotos_ant" != "$total_fotos" ]]; then
            log "AVISO $dia: fotos diferem do MP4 existente! Não apagarei nada."
            return 1
        fi
        if (( REMOVER_PROCESSADOS == 1 )); then
            verificar_video "$video" "$total_frames" || {
                log "ERRO $dia: validação do MP4 antigo falhou; JPGs preservados."
                return 1
            }
            for nome in "${nomes[@]}"; do
                rm -- "${caminho_por_nome[$nome]}" || return 1
            done
            log "$dia: MP4 conferido; $total_fotos JPGs removidos."
        fi
        return 0
    fi

    # Links simbólicos evitam copiar os JPGs. A sequência numerada faz o FFmpeg
    # receber um frame por foto TL e 30 frames iguais por foto AVULSA.
    TEMP_DIR="$(mktemp -d "$DIR_VIDEOS/.processando_${dia}.XXXXXX")" || return 1
    local quadro=0
    for nome in "${nomes[@]}"; do
        arquivo="${caminho_por_nome[$nome]}"
        repeticoes=1
        [[ "$nome" == *_AVULSA_* ]] && repeticoes="$FPS"
        for (( i=0; i<repeticoes; i++ )); do
            printf -v link '%s/frame_%06d.jpg' "$TEMP_DIR" "$quadro"
            ln -s -- "$arquivo" "$link" || return 1
            (( quadro += 1 ))
        done
    done

    log "$dia: codificando $total_fotos JPGs em $total_frames frames a ${FPS}fps."
    # Ajuste ao quadro 1920x1080 SEM deformar a imagem; adiciona barras se
    # a proporção original da GoPro não for 16:9. H.264 é fácil de reproduzir.
    ffmpeg -hide_banner -loglevel error -stats -nostdin -y \
        -framerate "$FPS" -start_number 0 -i "$TEMP_DIR/frame_%06d.jpg" \
        -vf "scale=${LARGURA}:${ALTURA}:force_original_aspect_ratio=decrease,pad=${LARGURA}:${ALTURA}:(ow-iw)/2:(oh-ih)/2,setsar=1" \
        -c:v libx264 -preset "$PRESET" -crf "$CRF" -pix_fmt yuv420p \
        -r "$FPS" -movflags +faststart "$TEMP_DIR/video.mp4" || return 1

    # Move atomicamente o MP4 concluído; depois valida o arquivo definitivo.
    mv -- "$TEMP_DIR/video.mp4" "$video" || return 1
    if ! verificar_video "$video" "$total_frames"; then
        log "ERRO $dia: vídeo inválido; fotos preservadas."
        rm -f -- "$video"
        return 1
    fi

    # O manifesto torna uma execução futura idempotente e protege a limpeza.
    printf '%s %s %s\n' "$assinatura" "$total_frames" "$total_fotos" > "$TEMP_DIR/manifest"
    mv -- "$TEMP_DIR/manifest" "$manifest" || return 1
    log "$dia: vídeo OK: $video ($total_frames frames a ${FPS}fps)."

    if (( REMOVER_PROCESSADOS == 1 )); then
        for nome in "${nomes[@]}"; do
            rm -- "${caminho_por_nome[$nome]}" || return 1
        done
        log "$dia: $total_fotos fotos processadas e removidas."
    fi

    limpar_temporarios
    TEMP_DIR=""
}

case "${1:-}" in
    cron)
        # Processa todos os dias com arquivos presentes, inclusive dias antigos.
        # Os nomes foram gerados pela GoPro (sem quebras de linha).
        mapfile -t dias < <(
            find "$DIR_FOTOS" -type f -iname '*.jpg' -printf '%f\n' |
            sed -nE 's/^([0-9]{8})_[0-9]{6}_(TL|AVULSA)_.+\.[Jj][Pp][Gg]$/\1/p' |
            LC_ALL=C sort -u
        )
        falhas=0
        for dia in "${dias[@]}"; do
            processar_dia "$dia" || falhas=1
        done
        exit "$falhas"
        ;;
    dia)
        [[ "${2:-}" =~ ^[0-9]{8}$ ]] || { log 'Uso: dia AAAAMMDD'; exit 2; }
        processar_dia "$2"
        ;;
    *)
        echo "Uso: $0 cron | dia AAAAMMDD" >&2
        exit 2
        ;;
esac
