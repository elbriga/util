#!/usr/bin/env bash
# GoPro HERO3+ - ciclo do grow: 22h -> 16h, fotos avulsas: 17h -> 21h.
# Requisitos: bash, curl, jq, exiftool, flock, stat.
set -Eeuo pipefail

# ===== CONFIGURACAO =====
GOPRO_IP="10.5.5.9"
GOPRO_SENHA="goprohero"
WIFI_IFACE="wlan0"
BACKUP="/srv/backup/gopro-grow"
ESTADO="/var/lib/gopro-grow"
INTERVALO_TIMELAPSE="%3c"  # %05=5s, %0a=10s, %1e=30s, %3c=60s
PERMITIR_FORMATACAO=0      # Mude para 1 SOMENTE apos validar os backups!
# =========================

URL="http://${GOPRO_IP}"
MEDIA_URL="${URL}:8080"
DIA="$(date +%F)"
STAGING="${BACKUP}/.em_andamento/${DIA}"
FINAL="${BACKUP}/${DIA}"
AVULSAS="${ESTADO}/avulsas.tsv"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
erro() { log "ERRO: $*" >&2; return 1; }

preparar() {
    for dep in curl jq exiftool flock stat; do
        command -v "$dep" >/dev/null || { erro "Falta instalar: $dep"; return 1; }
    done
    [[ "$GOPRO_SENHA" != "ALTERE_AQUI" ]] || { erro "Configure GOPRO_SENHA"; return 1; }
    mkdir -p "$ESTADO" "$BACKUP/.em_andamento"
    chmod 700 "$ESTADO"
    exec 9>"$ESTADO/execucao.lock"
    flock -n 9 || { erro "ROTINA_OCUPADA: outra execucao esta ativa"; return 1; }
    TMP="$(mktemp -d "${ESTADO}/tmp.XXXXXXXX")"
    trap 'rm -rf -- "$TMP"' EXIT
}

# Comandos HTTP legados da HERO3+, com a senha em 't' e byte em 'p'.
comando() {
    local caminho="$1" parametro="${2:-}" endereco="${URL}/$1?t=${GOPRO_SENHA}"
    [[ -z "$parametro" ]] || endereco+="&p=${parametro}"
    curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
        --connect-timeout 5 --max-time 20 "$endereco" -o /dev/null
}

camera_online() {
    curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
        --connect-timeout 3 --max-time 7 \
        "${URL}/bacpac/sd" -o /dev/null
}

verificar_conexao() {
    if camera_online; then
        log "GOPRO_ONLINE ip=$GOPRO_IP"
    else
        erro "GOPRO_OFFLINE ip=$GOPRO_IP"
    fi
}

# Pede um inventario completo do microSD e valida a estrutura JSON.
listar_midias() {
    local destino="$1"
    curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
        --connect-timeout 5 --max-time 40 --retry 2 \
        "${MEDIA_URL}/gp/gpMediaList" -o "$destino" || return 1
    jq -e '(.media | type == "array") and
           all(.media[]; (.d | type == "string") and (.fs | type == "array"))' \
        "$destino" >/dev/null
}

inventario_tsv() {
    local json="$1" destino="$2"
    jq -r '.media[] | .d as $pasta | .fs[] |
           [$pasta, .n, (.s // "" | tostring)] | @tsv' "$json" | sort > "$destino"
}

lista_de_fotos() {
    local json="$1" destino="$2"
    jq -r '.media[] | .d as $pasta | .fs[] |
           select(.n | test("\\.(jpe?g)$"; "i")) |
           "\($pasta)/\(.n)"' "$json" | sort -u > "$destino"
}

parar_timelapse() {
    log "Parando timelapse"
    comando bacpac/SH '%00'
    sleep 3
}

iniciar_timelapse() {
    log "Configurando timelapse: intervalo ${INTERVALO_TIMELAPSE}"
    comando camera/CM '%03'
    sleep 2
    comando camera/TI "$INTERVALO_TIMELAPSE"
    sleep 2
    comando bacpac/SH '%01'
    log "TIMELAPSE_INICIADO"
}

# Sincroniza o relogio da camera com o horario local do Raspberry Pi.
acertar_relogio() {
    local aa mm dd hh mi ss v byte payload=""
    read -r aa mm dd hh mi ss <<< "$(date '+%y %m %d %H %M %S')"
    for v in "$aa" "$mm" "$dd" "$hh" "$mi" "$ss"; do
        printf -v byte '%%%02x' "$((10#$v))"
        payload+="$byte"
    done
    comando camera/TM "$payload"
    log "RELOGIO_SINCRONIZADO"
}

# Captura uma unica imagem e guarda o nome real que a camera lhe deu.
foto_unica() {
    local slot="${1:-}" inicio="$(date +%Y%m%d_%H%M%S)" novos=""
    if [[ -n "$slot" ]]; then
        if [[ -e "$ESTADO/foto_${slot}.tentada" ]]; then
            log "FOTO_JA_TENTADA slot=$slot (evitando disparo duplicado)"
            return 0
        fi
    fi

    listar_midias "$TMP/antes.json" || { erro "Nao foi possivel listar fotos antes do disparo"; return 1; }
    lista_de_fotos "$TMP/antes.json" "$TMP/antes.txt"

    # Marcador anterior ao comando: mesmo que haja timeout, nao duplica o disparo.
    if [[ -n "$slot" ]]; then
        printf '%s\n' "$inicio" > "$ESTADO/foto_${slot}.tentada"
    fi

    log "Disparando FOTO_AVULSA slot=${slot:-manual}"
    comando camera/CM '%01' || { erro "Falha ao mudar para modo foto"; return 1; }
    sleep 2
    comando camera/CS '%00' || { erro "Falha ao selecionar foto unica"; return 1; }
    sleep 2
    comando bacpac/SH '%01' || { erro "Falha ou resposta incerta do obturador"; return 1; }
    sleep 4

    local tentativa
    for tentativa in 1 2 3 4; do
        if listar_midias "$TMP/depois.json"; then
            lista_de_fotos "$TMP/depois.json" "$TMP/depois.txt"
            novos="$(comm -13 "$TMP/antes.txt" "$TMP/depois.txt")"
            [[ -n "$novos" ]] && break
        fi
        sleep 3
    done

    if [[ "$(printf '%s\n' "$novos" | sed '/^$/d' | wc -l)" -ne 1 ]]; then
        erro "FOTO_NAO_IDENTIFICADA: verifique camera e inventario; nao vou repetir disparo"
        return 1
    fi
    printf '%s\t%s\n' "$novos" "$inicio" >> "$AVULSAS"
    log "FOTO_AVULSA_OK origem=$novos horario=$inicio"
}

# Baixa originais para um diretorio oculto e cria hardlinks com nomes ordenaveis.
# Guardar o original permite retomar um backup interrompido sem repetir transferencias.
sincronizar_fotos() {
    local destino="$1" linhas="$TMP/inventario.tsv"
    local pasta nome tamanho origem arquivo tipo horario foto nome_final qt=0
    listar_midias "$TMP/midias.json" || { erro "Inventario da GoPro indisponivel"; return 1; }
    inventario_tsv "$TMP/midias.json" "$linhas"
    mkdir -p "$destino/.originais"

    # Nunca formatar um cartao que contenha videos ou arquivos desconhecidos.
    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue
        [[ "$nome" =~ \.[Jj][Pp][Ee]?[Gg]$ ]] || {
            erro "Arquivo nao-JPEG no cartao: ${pasta}/${nome}"; return 1;
        }
        [[ "$pasta" =~ ^[A-Za-z0-9_-]+$ && "$nome" =~ ^[A-Za-z0-9_.-]+$ ]] || {
            erro "Nome de arquivo inesperado: ${pasta}/${nome}"; return 1;
        }
        [[ "$tamanho" =~ ^[0-9]+$ && "$tamanho" -gt 0 ]] || {
            erro "Tamanho indisponivel: ${pasta}/${nome}"; return 1;
        }
    done < "$linhas"

    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue
        origem="${pasta}/${nome}"
        arquivo="$destino/.originais/$origem"
        mkdir -p "$(dirname "$arquivo")"

        if [[ ! -f "$arquivo" ]] || [[ "$(stat -c %s "$arquivo")" -ne "$tamanho" ]]; then
            log "Baixando $origem ($tamanho bytes)"
            rm -f "$arquivo.part"
            if ! curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
                --retry 3 --retry-delay 2 --connect-timeout 5 --max-time 180 \
                "${MEDIA_URL}/videos/DCIM/${origem}" -o "$arquivo.part"; then
                rm -f "$arquivo.part"
                erro "Falha no download de $origem"; return 1
            fi
            if [[ "$(stat -c %s "$arquivo.part")" -ne "$tamanho" ]]; then
                rm -f "$arquivo.part"
                erro "Tamanho incorreto de $origem"; return 1
            fi
            mv -f "$arquivo.part" "$arquivo"
        fi

        tipo="TL"
        horario="$(exiftool -s3 -d '%Y%m%d_%H%M%S' -DateTimeOriginal "$arquivo" | head -n1)"
        [[ "$horario" =~ ^[0-9]{8}_[0-9]{6}$ ]] || {
            erro "EXIF sem data valida em $origem; preservando o cartao"; return 1;
        }

        if [[ -f "$AVULSAS" ]]; then
            foto="$(awk -F '\t' -v origem="$origem" '$1 == origem {print $2; exit}' "$AVULSAS")"
            if [[ -n "$foto" ]]; then
                tipo="AVULSA"
                horario="$foto"
            fi
        fi

        nome_final="${horario}_${tipo}_${pasta}_${nome}"
        if [[ -e "$destino/$nome_final" ]]; then
            [[ "$arquivo" -ef "$destino/$nome_final" ]] || {
                erro "Colisao de nome: $nome_final"; return 1;
            }
        else
            ln "$arquivo" "$destino/$nome_final"
        fi
        [[ "$(stat -c %s "$destino/$nome_final")" -eq "$tamanho" ]] || {
            erro "Falha de verificacao do backup: $nome_final"; return 1;
        }
        ((qt+=1))
    done < "$linhas"

    # Verifica que nao houve mudancas na camera durante a transferencia.
    listar_midias "$TMP/conferencia.json" || return 1
    inventario_tsv "$TMP/conferencia.json" "$TMP/conferencia.tsv"
    cmp -s "$linhas" "$TMP/conferencia.tsv" || {
        erro "Inventario mudou durante o backup: nao formatar"; return 1;
    }
    log "BACKUP_VALIDADO fotos=$qt diretorio=$destino"
}

# A camera deve estar parada. So formata apos backup e verificacao completa.
fechar_ciclo() {
    local destino="$STAGING" tentativa
    log "Fechando ciclo $DIA"
    if [[ -d "$FINAL" && -d "$STAGING" ]]; then
        erro "Existem STAGING e FINAL simultaneamente; resolva antes de apagar o SD"; return 1
    fi
    [[ -d "$FINAL" ]] && destino="$FINAL"

    sincronizar_fotos "$destino" || return 1
    if [[ "$destino" == "$STAGING" ]]; then
        mv -T "$STAGING" "$FINAL"
        log "PASTA_DO_DIA_CRIADA $FINAL"
    fi

    if [[ "$PERMITIR_FORMATACAO" != 1 ]]; then
        log "FORMATACAO_DESATIVADA: backup concluido; SD foi preservado"
        return 0
    fi

    # Um inventario vazio nao demanda formatacao.
    if [[ ! -s "$TMP/inventario.tsv" ]]; then
        log "CARTAO_VAZIO: nenhuma limpeza necessaria"
        : > "$AVULSAS"
        return 0
    fi

    log "FORMATANDO_CARTAO (backup verificado em $FINAL)"
    # Mesmo se a resposta HTTP falhar, a camera pode ter formatado; conferir o estado.
    if ! comando camera/DA; then
        log "AVISO: resposta de formatacao incerta; consultando o cartao"
    fi
    for tentativa in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5
        if listar_midias "$TMP/apos_formatacao.json" &&
           jq -e '([.media[]?.fs[]?] | length) == 0' "$TMP/apos_formatacao.json" >/dev/null; then
            : > "$AVULSAS"
            log "CARTAO_LIMPO_CONFIRMADO"
            return 0
        fi
    done
    erro "FORMATACAO_NAO_CONFIRMADA; conferir antes de novo ciclo"
}

rotina() {
    local hora="$(date +%H)" falhou=0
    verificar_conexao || return 1
    case "$hora" in
        16)
            parar_timelapse
            log "PRE_BACKUP_INICIADO"
            sincronizar_fotos "$STAGING"
            ;;
        17|18|19|20|21)
            foto_unica "$(date +%Y%m%d_%H)"
            ;;
        22)
            # Nao apagar fotos em caso de falha: tentar iniciar mesmo assim.
            parar_timelapse || falhou=1
            if ((falhou == 0)); then
                fechar_ciclo || falhou=1
            fi
            acertar_relogio || falhou=1
            iniciar_timelapse || falhou=1
            ((falhou == 0)) || return 1
            ;;
        *) log "Apenas monitoramento nesta hora" ;;
    esac
}

main() {
    preparar
    case "${1:-cron}" in
        cron)               rotina ;;
        status)             verificar_conexao ;;
        foto)               verificar_conexao && foto_unica ;;
        iniciar)            verificar_conexao && iniciar_timelapse ;;
        parar)              verificar_conexao && parar_timelapse ;;
        sincronizar)        verificar_conexao && sincronizar_fotos "$STAGING" ;;
        fechar)             verificar_conexao && fechar_ciclo ;;
        *) echo "Uso: $0 [cron|status|foto|iniciar|parar|sincronizar|fechar]" >&2; exit 2 ;;
    esac
}
main "$@"
