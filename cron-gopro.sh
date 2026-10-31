#!/usr/bin/env bash
# GoPro HERO3+ - ciclo do grow
# Timelapse: 22h ate 16h
# Fotos avulsas: 17h, 18h, 19h, 20h e 21h
set -Eeuo pipefail

# ===== CONFIGURACAO =====
GOPRO_IP="10.5.5.9"
GOPRO_SENHA="goprohero"
WIFI_IFACE="wlan0"
BACKUP="/srv/backup/gopro-grow"
ESTADO="/var/lib/gopro-grow"
INTERVALO_TIMELAPSE="%3c" # %05=5s, %0a=10s, %1e=30s, %3c=60s
PERMITIR_FORMATACAO=0     # Ativar somente apos validar os backups!
# =========================

URL="http://${GOPRO_IP}"
MEDIA_URL="${URL}:8080"

DIA="$(date +%F)"
STAGING="${BACKUP}/.em_andamento/${DIA}"
FINAL="${BACKUP}/${DIA}"
AVULSAS="${ESTADO}/avulsas.tsv"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

erro() {
    log "ERRO: $*" >&2
    return 1
}

preparar() {
    for dep in curl jq exiftool flock stat; do
        command -v "$dep" >/dev/null || {
            erro "Falta instalar: $dep"
            return 1
        }
    done

    [[ "$GOPRO_SENHA" != "ALTERE_AQUI" ]] || {
        erro "Configure GOPRO_SENHA"
        return 1
    }

    mkdir -p "$ESTADO" "$BACKUP/.em_andamento"
    chmod 700 "$ESTADO"

    # Impede duas execucoes simultaneas
    exec 9>"$ESTADO/execucao.lock"
    flock -n 9 || {
        erro "ROTINA_OCUPADA: outra execucao esta ativa"
        return 1
    }

    TMP="$(mktemp -d "${ESTADO}/tmp.XXXXXXXX")"
    trap 'rm -rf -- "$TMP"' EXIT
}

# Envia comandos HTTP para a HERO3+
comando() {
    local caminho="$1"
    local parametro="${2:-}"
    local endereco="${URL}/$1?t=${GOPRO_SENHA}"

    [[ -z "$parametro" ]] || endereco+="&p=${parametro}"

    curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
        --connect-timeout 5 --max-time 20 \
        "$endereco" -o /dev/null
}

# ===== CONECTIVIDADE =====

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

# ===== INVENTARIO DO CARTAO =====

listar_midias() {
    local destino="$1"

    curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
        --connect-timeout 5 --max-time 40 --retry 2 \
        "${MEDIA_URL}/gp/gpMediaList" \
        -o "$destino" || return 1

    jq -e '
        (.media | type == "array") and
        all(.media[];
            (.d | type == "string") and
            (.fs | type == "array")
        )
    ' "$destino" >/dev/null
}

inventario_tsv() {
    local json="$1"
    local destino="$2"

    jq -r '
        .media[] |
        .d as $pasta |
        .fs[] |
        [$pasta, .n, (.s // "" | tostring)] |
        @tsv
    ' "$json" | sort > "$destino"
}

lista_de_fotos() {
    local json="$1"
    local destino="$2"

    jq -r '
        .media[] |
        .d as $pasta |
        .fs[] |
        select(.n | test("\\.(jpe?g)$"; "i")) |
        "\($pasta)/\(.n)"
    ' "$json" | sort -u > "$destino"
}

# ===== CONTROLE DA CAMERA =====

desligar_bip() {
    log "Desativando bip"
    comando camera/BS '%00'
}

parar_timelapse() {
    log "Parando timelapse"
    comando bacpac/SH '%00'
    sleep 3
}

iniciar_timelapse() {
    desligar_bip

    log "Configurando timelapse: intervalo ${INTERVALO_TIMELAPSE}"

    comando camera/CM '%03'
    sleep 2

    comando camera/TI "$INTERVALO_TIMELAPSE"
    sleep 2

    comando bacpac/SH '%01'

    log "TIMELAPSE_INICIADO"
}

# Sincroniza o relogio da GoPro com o Raspberry Pi
acertar_relogio() {
    local aa mm dd hh mi ss v byte payload=""

    read -r aa mm dd hh mi ss <<< \
        "$(date '+%y %m %d %H %M %S')"

    for v in "$aa" "$mm" "$dd" "$hh" "$mi" "$ss"; do
        printf -v byte '%%%02x' "$((10#$v))"
        payload+="$byte"
    done

    comando camera/TM "$payload"
    log "RELOGIO_SINCRONIZADO"
}

# ===== FOTO AVULSA =====

foto_unica() {
    local slot="${1:-}"
    local inicio
    local novos=""
    local tentativa

    inicio="$(date +%Y%m%d_%H%M%S)"

    # Evita disparar duas vezes na mesma hora
    if [[ -n "$slot" ]]; then
        if [[ -e "$ESTADO/foto_${slot}.tentada" ]]; then
            log "FOTO_JA_TENTADA slot=$slot"
            return 0
        fi
    fi

    # Guarda a lista antes do disparo
    listar_midias "$TMP/antes.json" || {
        erro "Nao foi possivel listar fotos antes do disparo"
        return 1
    }

    lista_de_fotos "$TMP/antes.json" "$TMP/antes.txt"

    # Registra antes de disparar para evitar duplicatas
    if [[ -n "$slot" ]]; then
        printf '%s\n' "$inicio" \
            > "$ESTADO/foto_${slot}.tentada"
    fi

    log "Disparando FOTO_AVULSA slot=${slot:-manual}"

    comando camera/CM '%01' || {
        erro "Falha ao mudar para modo foto"
        return 1
    }
    sleep 2

    comando camera/CS '%00' || {
        erro "Falha ao selecionar foto unica"
        return 1
    }
    sleep 2

    comando bacpac/SH '%01' || {
        erro "Falha ou resposta incerta do obturador"
        return 1
    }

    sleep 4

    # Identifica o arquivo criado
    for tentativa in 1 2 3 4; do
        if listar_midias "$TMP/depois.json"; then
            lista_de_fotos "$TMP/depois.json" "$TMP/depois.txt"

            novos="$(comm -13 \
                "$TMP/antes.txt" "$TMP/depois.txt")"

            [[ -n "$novos" ]] && break
        fi

        sleep 3
    done

    if [[ "$(printf '%s\n' "$novos" |
        sed '/^$/d' | wc -l)" -ne 1 ]]; then

        erro "FOTO_NAO_IDENTIFICADA: nao vou repetir disparo"
        return 1
    fi

    # Registra qual foto foi tirada manualmente
    printf '%s\t%s\n' "$novos" "$inicio" >> "$AVULSAS"

    log "FOTO_AVULSA_OK origem=$novos horario=$inicio"
}

# ===== DOWNLOAD DE FOTO =====

baixar_foto() {
    local origem="$1"
    local arquivo="$2"
    local tamanho="$3"

    local tentativa
    local recebido=""
    local resposta=""
    local tipo_recebido=""
    local transferencia_ok=0

    log "Baixando $origem (esperado=$tamanho bytes)"

    for tentativa in 1 2 3; do

        rm -f "$arquivo.part" "$arquivo.part.headers"

        # Segue redirecionamentos e registra diagnostico HTTP
        resposta="$(curl \
            --noproxy '*' \
            --interface "$WIFI_IFACE" \
            -fLsS \
            --max-redirs 3 \
            --retry 2 \
            --retry-delay 2 \
            --connect-timeout 5 \
            --max-time 180 \
            -D "$arquivo.part.headers" \
            -w 'http=%{http_code} content_type=%{content_type} bytes_http=%{size_download}' \
            "${MEDIA_URL}/videos/DCIM/${origem}" \
            -o "$arquivo.part")" || {

            log "DOWNLOAD_FALHOU arquivo=$origem tentativa=$tentativa detalhe=$resposta"
            sleep 2
            continue
        }

        recebido="$(stat -c %s "$arquivo.part")"

        tipo_recebido="$(
            exiftool -s3 -FileType "$arquivo.part" \
                2>/dev/null || true
        )"

        log "DOWNLOAD_RESPOSTA arquivo=$origem tentativa=$tentativa esperado=$tamanho recebido=$recebido tipo=$tipo_recebido $resposta"

        # So aceita um JPEG com tamanho igual ao inventario
        if [[ "$recebido" -eq "$tamanho" &&
              "$tipo_recebido" == "JPEG" ]]; then

            mv -f "$arquivo.part" "$arquivo"
            rm -f "$arquivo.part.headers"

            transferencia_ok=1
            break
        fi

        log "DOWNLOAD_INVALIDO tentativa=$tentativa"
        sleep 2
    done

    if [[ "$transferencia_ok" -ne 1 ]]; then

        # Preserva arquivos para diagnostico
        erro "DOWNLOAD_INVALIDO arquivo=$origem esperado=$tamanho recebido=${recebido:-desconhecido} tipo=${tipo_recebido:-desconhecido} parte=$arquivo.part headers=$arquivo.part.headers"

        return 1
    fi

    log "DOWNLOAD_OK arquivo=$origem bytes=$recebido"
}

# ===== SINCRONIZACAO =====

sincronizar_fotos() {
    local destino="$1"
    local linhas="$TMP/inventario.tsv"

    local pasta nome tamanho origem arquivo
    local tipo horario foto nome_final
    local qt=0

    listar_midias "$TMP/midias.json" || {
        erro "Inventario da GoPro indisponivel"
        return 1
    }

    inventario_tsv "$TMP/midias.json" "$linhas"

    mkdir -p "$destino/.originais"

    # Verifica se existem arquivos inesperados no cartao
    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue

        [[ "$nome" =~ \.[Jj][Pp][Ee]?[Gg]$ ]] || {
            erro "Arquivo nao-JPEG no cartao: $pasta/$nome"
            return 1
        }

        [[ "$pasta" =~ ^[A-Za-z0-9_-]+$ &&
           "$nome" =~ ^[A-Za-z0-9_.-]+$ ]] || {
            erro "Nome de arquivo inesperado: $pasta/$nome"
            return 1
        }

        [[ "$tamanho" =~ ^[0-9]+$ &&
           "$tamanho" -gt 0 ]] || {
            erro "Tamanho indisponivel: $pasta/$nome"
            return 1
        }

    done < "$linhas"

    # Baixa e organiza as fotografias
    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue

        origem="${pasta}/${nome}"
        arquivo="$destino/.originais/$origem"

        mkdir -p "$(dirname "$arquivo")"

        # Nao baixa novamente um arquivo ja completo
        if [[ ! -f "$arquivo" ]] ||
           [[ "$(stat -c %s "$arquivo")" -ne "$tamanho" ]]; then

            baixar_foto "$origem" "$arquivo" "$tamanho" ||
                return 1
        fi

        tipo="TL"

        # Data da captura registrada no EXIF da foto
        horario="$(
            exiftool -s3 \
                -d '%Y%m%d_%H%M%S' \
                -DateTimeOriginal "$arquivo" | head -n1
        )"

        [[ "$horario" =~ ^[0-9]{8}_[0-9]{6}$ ]] || {
            erro "EXIF sem data valida: $origem"
            return 1
        }

        # Identifica as fotos avulsas
        if [[ -f "$AVULSAS" ]]; then
            foto="$(
                awk -F '\t' -v origem="$origem" \
                    '$1 == origem {print $2; exit}' "$AVULSAS"
            )"

            if [[ -n "$foto" ]]; then
                tipo="AVULSA"
                horario="$foto"
            fi
        fi

        nome_final="${horario}_${tipo}_${pasta}_${nome}"

        # Cria um hardlink com nome ordenavel
        if [[ -e "$destino/$nome_final" ]]; then

            [[ "$arquivo" -ef "$destino/$nome_final" ]] || {
                erro "Colisao de nome: $nome_final"
                return 1
            }

        else
            ln "$arquivo" "$destino/$nome_final"
        fi

        # Confere o tamanho do arquivo final
        [[ "$(stat -c %s "$destino/$nome_final")" -eq "$tamanho" ]] || {
            erro "Falha de verificacao: $nome_final"
            return 1
        }

        ((qt+=1))

    done < "$linhas"

    # Confirma que o cartao nao mudou durante o backup
    listar_midias "$TMP/conferencia.json" || return 1

    inventario_tsv \
        "$TMP/conferencia.json" \
        "$TMP/conferencia.tsv"

    cmp -s "$linhas" "$TMP/conferencia.tsv" || {
        erro "Inventario mudou durante o backup"
        return 1
    }

    log "BACKUP_VALIDADO fotos=$qt diretorio=$destino"
}

# ===== FECHAMENTO DO CICLO =====

fechar_ciclo() {
    local destino="$STAGING"
    local tentativa

    log "Fechando ciclo $DIA"

    if [[ -d "$FINAL" && -d "$STAGING" ]]; then
        erro "Existem STAGING e FINAL simultaneamente"
        return 1
    fi

    [[ -d "$FINAL" ]] && destino="$FINAL"

    # Sincronizacao completa antes de apagar qualquer coisa
    sincronizar_fotos "$destino" || return 1

    # Torna o backup definitivo
    if [[ "$destino" == "$STAGING" ]]; then
        mv -T "$STAGING" "$FINAL"
        log "PASTA_DO_DIA_CRIADA $FINAL"
    fi

    # Protecao contra limpeza acidental
    if [[ "$PERMITIR_FORMATACAO" != 1 ]]; then
        log "LIMPEZA_DESATIVADA: backup concluido; SD preservado"
        return 0
    fi

    # Cartao ja vazio
    if [[ ! -s "$TMP/inventario.tsv" ]]; then
        log "CARTAO_VAZIO: nenhuma limpeza necessaria"
        : > "$AVULSAS"
        return 0
    fi

    log "APAGANDO_MIDIAS_DO_CARTAO backup=$FINAL"

    # DA = Delete All, comando da HERO3+
    if ! comando camera/DA; then
        log "AVISO: resposta da exclusao incerta"
    fi

    # Confirma a limpeza consultando novamente o inventario
    for tentativa in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 5

        if listar_midias "$TMP/apos_limpeza.json" &&
           jq -e '([.media[]?.fs[]?] | length) == 0' \
               "$TMP/apos_limpeza.json" >/dev/null; then

            : > "$AVULSAS"

            log "CARTAO_LIMPO_CONFIRMADO"
            return 0
        fi
    done

    erro "LIMPEZA_NAO_CONFIRMADA; conferir antes do novo ciclo"
}

# ===== ROTINA DO CRON =====

rotina() {
    local hora
    hora="$(date +%H)"

    verificar_conexao || return 1

    case "$hora" in

        16)
            # Luz do grow apaga
            parar_timelapse

            log "PRE_BACKUP_INICIADO"
            sincronizar_fotos "$STAGING"
            ;;

        17|18|19|20|21)
            # Uma foto avulsa por hora
            foto_unica "$(date +%Y%m%d_%H)"
            ;;

        22)
            # Luz acende: fecha backup, limpa e reinicia
            parar_timelapse || return 1

            fechar_ciclo || return 1

            acertar_relogio || return 1

            iniciar_timelapse
            ;;

        *)
            # Demais horas: apenas conectividade
            log "Apenas monitoramento nesta hora"
            ;;

    esac
}

# ===== COMANDOS MANUAIS =====

main() {
    preparar

    case "${1:-uso}" in

        cron)
            rotina
            ;;

        status)
            verificar_conexao
            ;;

        foto)
            verificar_conexao && foto_unica
            ;;

        iniciar)
            verificar_conexao && iniciar_timelapse
            ;;

        parar)
            verificar_conexao && parar_timelapse
            ;;

        bip-off)
            verificar_conexao && desligar_bip
            ;;

        sincronizar)
            verificar_conexao && sincronizar_fotos "$STAGING"
            ;;

        fechar)
            verificar_conexao && fechar_ciclo
            ;;

        uso)
            echo "Uso: $0 [cron|status|foto|iniciar|parar|bip-off|sincronizar|fechar]" >&2
            exit 2
            ;;
    esac
}

main "$@"
