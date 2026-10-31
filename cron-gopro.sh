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
PERMITIR_FORMATACAO=1     # Ativar somente apos validar os backups!
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
    local dep

    for dep in curl jq exiftool flock stat cmp comm; do
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

    # Impede execucoes simultaneas
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
    local endereco="${URL}/${caminho}?t=${GOPRO_SENHA}"

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

# ===== INVENTARIO DE MIDIAS =====

listar_midias() {
    local destino="$1"

    curl --noproxy '*' --interface "$WIFI_IFACE" -fLsS \
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
    jq -r '
        .media[] |
        .d as $pasta |
        .fs[] |
        [$pasta, .n, (.s // "" | tostring)] |
        @tsv
    ' "$1" | sort > "$2"
}

lista_de_fotos() {
    jq -r '
        .media[] |
        .d as $pasta |
        .fs[] |
        select(.n | test("\\.(jpe?g)$"; "i")) |
        "\($pasta)/\(.n)"
    ' "$1" | sort -u > "$2"
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
    local inicio novos="" tentativa qtd

    inicio="$(date +%Y%m%d_%H%M%S)"

    # Evita duplicar a foto do mesmo horario
    if [[ -n "$slot" &&
          -e "$ESTADO/foto_${slot}.tentada" ]]; then
        log "FOTO_JA_TENTADA slot=$slot"
        return 0
    fi

    listar_midias "$TMP/antes.json" || {
        erro "Inventario indisponivel antes da foto"
        return 1
    }

    lista_de_fotos "$TMP/antes.json" "$TMP/antes.txt"

    # Marca a tentativa antes do disparo
    [[ -z "$slot" ]] || \
        printf '%s\n' "$inicio" > "$ESTADO/foto_${slot}.tentada"

    log "Disparando FOTO_AVULSA slot=${slot:-manual}"

    comando camera/CM '%01' || return 1
    sleep 2

    comando camera/CS '%00' || return 1
    sleep 2

    comando bacpac/SH '%01' || {
        erro "Obturador falhou ou resposta incerta; nao repetir automaticamente"
        return 1
    }

    sleep 4

    # Descobre qual arquivo foi criado
    for tentativa in 1 2 3 4; do

        if listar_midias "$TMP/depois.json"; then
            lista_de_fotos "$TMP/depois.json" "$TMP/depois.txt"

            novos="$(comm -13 \
                "$TMP/antes.txt" "$TMP/depois.txt")"

            [[ -z "$novos" ]] || break
        fi

        sleep 3
    done

    qtd="$(printf '%s\n' "$novos" |
        sed '/^$/d' | wc -l)"

    [[ "$qtd" -eq 1 ]] || {
        erro "FOTO_NAO_IDENTIFICADA (novas=$qtd), nao repetir disparo"
        return 1
    }

    # Identifica a foto avulsa para renomear no backup
    printf '%s\t%s\n' "$novos" "$inicio" >> "$AVULSAS"

    log "FOTO_AVULSA_OK origem=$novos horario=$inicio"
}

# ===== DOWNLOAD =====

baixar_foto() {
    local origem="$1"
    local arquivo="$2"
    local tamanho="$3"

    local tentativa recebido="" resposta="" tipo=""
    local concluido=0

    log "Baixando $origem (esperado=$tamanho bytes)"

    for tentativa in 1 2 3; do
        rm -f "$arquivo.part" "$arquivo.part.headers"

        # Segue redirecionamentos e registra resposta HTTP
        if ! resposta="$(curl \
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
            -o "$arquivo.part")"; then

            log "DOWNLOAD_FALHOU arquivo=$origem tentativa=$tentativa detalhe=$resposta"
            sleep 2
            continue
        fi

        recebido="$(stat -c %s "$arquivo.part")"

        tipo="$(
            exiftool -s3 -FileType "$arquivo.part" \
                2>/dev/null || true
        )"

        log "DOWNLOAD_RESPOSTA arquivo=$origem tentativa=$tentativa esperado=$tamanho recebido=$recebido tipo=$tipo $resposta"

        if [[ "$recebido" -eq "$tamanho" &&
              "$tipo" == "JPEG" ]]; then

            mv -f "$arquivo.part" "$arquivo"
            rm -f "$arquivo.part.headers"

            concluido=1
            break
        fi

        sleep 2
    done

    [[ "$concluido" -eq 1 ]] || {
        erro "DOWNLOAD_INVALIDO arquivo=$origem esperado=$tamanho recebido=${recebido:-?} tipo=${tipo:-?} parte=$arquivo.part"
        return 1
    }

    log "DOWNLOAD_OK arquivo=$origem bytes=$recebido"
}

# ===== BACKUP =====

sincronizar_fotos() {
    local destino="$1"
    local linhas="$TMP/inventario.tsv"

    local pasta nome tamanho origem arquivo
    local horario tipo foto nome_final qt=0

    listar_midias "$TMP/midias.json" || {
        erro "Inventario indisponivel"
        return 1
    }

    inventario_tsv "$TMP/midias.json" "$linhas"
    mkdir -p "$destino/.originais"

    # Rejeita midias nao suportadas ou inventario invalido
    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue

        [[ "$nome" =~ \.[Jj][Pp][Ee]?[Gg]$ ]] || {
            erro "Midia nao-JPEG: $pasta/$nome"
            return 1
        }

        [[ "$pasta" =~ ^[A-Za-z0-9_-]+$ &&
           "$nome" =~ ^[A-Za-z0-9_.-]+$ ]] || {
            erro "Nome inesperado: $pasta/$nome"
            return 1
        }

        [[ "$tamanho" =~ ^[0-9]+$ &&
           "$tamanho" -gt 0 ]] || {
            erro "Tamanho invalido: $pasta/$nome"
            return 1
        }
    done < "$linhas"

    # Baixa cada fotografia e cria o nome cronologico
    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue

        origem="${pasta}/${nome}"
        arquivo="$destino/.originais/$origem"

        mkdir -p "$(dirname "$arquivo")"

        if [[ ! -f "$arquivo" ]] ||
           [[ "$(stat -c %s "$arquivo")" -ne "$tamanho" ]]; then

            baixar_foto "$origem" "$arquivo" "$tamanho" ||
                return 1
        fi

        tipo="TL"

        horario="$(
            exiftool -s3 \
                -d '%Y%m%d_%H%M%S' \
                -DateTimeOriginal "$arquivo" \
                2>/dev/null | head -n1 || true
        )"

        [[ "$horario" =~ ^[0-9]{8}_[0-9]{6}$ ]] || {
            erro "EXIF sem data valida: $origem"
            return 1
        }

        # Verifica se esta foto foi uma captura avulsa
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

        # Hardlink evita duplicar fisicamente a fotografia
        if [[ -e "$destino/$nome_final" ]]; then

            [[ "$arquivo" -ef "$destino/$nome_final" ]] || {
                erro "Colisao de nome: $nome_final"
                return 1
            }
        else
            ln "$arquivo" "$destino/$nome_final"
        fi

        [[ "$(stat -c %s "$destino/$nome_final")" -eq "$tamanho" ]] || {
            erro "Tamanho final invalido: $nome_final"
            return 1
        }

        ((qt+=1))

    done < "$linhas"

    # Confirma que nenhuma foto mudou durante o backup
    listar_midias "$TMP/conferencia.json" || return 1

    inventario_tsv \
        "$TMP/conferencia.json" \
        "$TMP/conferencia.tsv"

    cmp -s "$linhas" "$TMP/conferencia.tsv" || {
        erro "Inventario mudou durante backup; limpeza bloqueada"
        return 1
    }

    # Autoriza limpeza apenas nesta execucao
    cp "$linhas" "$TMP/inventario_validado.tsv"

    log "BACKUP_VALIDADO fotos=$qt diretorio=$destino"
}

# Fecha o backup sem alterar o cartao
fechar_ciclo() {
    local destino="$STAGING"

    if [[ -d "$FINAL" && -d "$STAGING" ]]; then
        erro "Existem STAGING e FINAL simultaneamente para $DIA"
        return 1
    fi

    [[ -d "$FINAL" ]] && destino="$FINAL"

    log "Fechando backup do ciclo $DIA"

    sincronizar_fotos "$destino" || return 1

    if [[ "$destino" == "$STAGING" ]]; then
        mv -T "$STAGING" "$FINAL"
        log "PASTA_DO_DIA_CRIADA $FINAL"
    fi

    log "CICLO_BACKUP_FECHADO (cartao nao foi alterado)"
}

# ===== LIMPEZA DO CARTAO =====

# Funcao interna: chamada apenas apos backup validado
limpar_cartao() {
    local destino="$1"
    local tentativa pasta nome tamanho origem arquivo

    [[ "$PERMITIR_FORMATACAO" == 1 ]] || {
        erro "LIMPEZA_CANCELADA: PERMITIR_FORMATACAO=0"
        return 1
    }

    [[ -f "$TMP/inventario_validado.tsv" ]] || {
        erro "LIMPEZA_BLOQUEADA: falta backup validado nesta execucao"
        return 1
    }

    [[ -d "$destino" ]] || {
        erro "LIMPEZA_BLOQUEADA: backup nao encontrado em $destino"
        return 1
    }

    # O inventario precisa ser identico ao do backup
    listar_midias "$TMP/antes_limpeza.json" || {
        erro "LIMPEZA_BLOQUEADA: camera sem inventario"
        return 1
    }

    inventario_tsv \
        "$TMP/antes_limpeza.json" \
        "$TMP/antes_limpeza.tsv"

    cmp -s \
        "$TMP/inventario_validado.tsv" \
        "$TMP/antes_limpeza.tsv" || {

        erro "LIMPEZA_BLOQUEADA: inventario mudou desde o backup"
        return 1
    }

    # Confere novamente os arquivos armazenados
    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "$pasta" ]] || continue

        origem="${pasta}/${nome}"
        arquivo="$destino/.originais/$origem"

        [[ -f "$arquivo" ]] &&
        [[ "$(stat -c %s "$arquivo")" -eq "$tamanho" ]] || {

            erro "LIMPEZA_BLOQUEADA: copia ausente/incompleta de $origem"
            return 1
        }

    done < "$TMP/inventario_validado.tsv"

    if [[ ! -s "$TMP/inventario_validado.tsv" ]]; then
        log "CARTAO_VAZIO: limpeza desnecessaria"
        : > "$AVULSAS"
        return 0
    fi

    log "LIMPEZA_INICIADA: apagando TODAS as midias da GoPro (backup=$destino)"

    # HERO3+: Delete All
    if ! comando camera/DA; then
        log "AVISO: resposta de camera/DA incerta; verificando o cartao"
    fi

    # Espera e confirma que nao restaram midias
    for tentativa in {1..12}; do
        sleep 5

        if listar_midias "$TMP/depois_limpeza.json" &&
           jq -e '([.media[]?.fs[]?] | length) == 0' \
               "$TMP/depois_limpeza.json" >/dev/null; then

            : > "$AVULSAS"

            log "CARTAO_LIMPO_CONFIRMADO"
            return 0
        fi
    done

    erro "LIMPEZA_NAO_CONFIRMADA: confira o cartao manualmente"
}

# Comando manual com confirmacao
limpar_interativo() {
    local confirmacao

    # Verifica a permissao antes de qualquer operacao
    [[ "$PERMITIR_FORMATACAO" == 1 ]] || {
        erro "LIMPEZA_CANCELADA: PERMITIR_FORMATACAO=0; altere a configuracao para 1"
        return 1
    }

    [[ -t 0 ]] || {
        erro "LIMPEZA_CANCELADA: comando limpar requer terminal interativo"
        return 1
    }

    printf 'ATENCAO: todas as midias do microSD serao apagadas APOS backup validado.\n'

    read -r -p 'Digite sim para continuar: ' confirmacao ||
        return 1

    if [[ "$confirmacao" != sim ]]; then
        log "LIMPEZA_CANCELADA: confirmacao diferente de sim"
        return 1
    fi

    verificar_conexao || return 1

    # Para a captura antes de copiar e limpar
    parar_timelapse || {
        erro "Nao foi possivel confirmar parada; limpeza cancelada"
        return 1
    }

    sincronizar_fotos "$STAGING" || return 1

    limpar_cartao "$STAGING"
}

# ===== ROTINA DO CRON =====

rotina() {
    local hora marcador
    hora="$(date +%H)"

    verificar_conexao || return 1

    case "$hora" in

        16)
            # Luz do grow apaga
            parar_timelapse || return 1

            log "PRE_BACKUP_INICIADO"
            sincronizar_fotos "$STAGING"
            ;;

        17|18|19|20|21)
            # Foto avulsa da hora
            foto_unica "$(date +%Y%m%d_%H)"
            ;;

        22)
            # Impede executar duas vezes no mesmo dia
            marcador="$ESTADO/ciclo_22_${DIA}.feito"

            if [[ -e "$marcador" ]]; then
                log "CICLO_22_JA_EXECUTADO dia=$DIA"
                return 0
            fi

            # Fecha o ciclo anterior
            parar_timelapse || return 1
            fechar_ciclo || return 1

            # Limpeza automatica somente se habilitada
            if [[ "$PERMITIR_FORMATACAO" == 1 ]]; then
                limpar_cartao "$FINAL" || return 1
            else
                log "AVISO: PERMITIR_FORMATACAO=0; limpeza ignorada, fotos permanecem na GoPro"
            fi

            # Inicia novo timelapse
            acertar_relogio || return 1
            iniciar_timelapse || return 1

            : > "$marcador"
            ;;

        *)
            log "Apenas monitoramento nesta hora"
            ;;
    esac
}

# ===== COMANDOS MANUAIS =====

main() {
    preparar || return 1

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

        limpar)
            limpar_interativo
            ;;

        uso)
            echo "Uso: $0 [cron|status|foto|iniciar|parar|bip-off|sincronizar|fechar|limpar]" >&2
            return 2
            ;;
    esac
}

main "$@"
