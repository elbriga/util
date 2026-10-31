#!/usr/bin/env bash
# GoPro HERO3+ - fotos a cada 2 min (22h-15h58) e avulsas (17h-21h)
# Cada JPEG vai direto para a pasta diaria no Raspberry Pi.
# Add no crontab -e
# */2 * * * * /usr/local/bin/cron-gopro.sh cron >> /var/log/cron-gopro.log 2>&1
set -Eeuo pipefail

# ===== CONFIGURACAO =====
GOPRO_IP="10.5.5.9"
GOPRO_SENHA="goprohero"
WIFI_IFACE="wlan0"
BACKUP="/srv/backup/gopro"
ESTADO="/var/lib/gopro"
MAX_FOTOS_SYNC=3                  # fotos sync por rodada
PERMITIR_FORMATACAO=1             # 0 bloqueia inclusive 'limpar force'
# =========================

URL="http://${GOPRO_IP}"
MEDIA_URL="${URL}:8080"
INDICE="${ESTADO}/sincronizados.tsv"
CAPTURAS="${ESTADO}/capturas.tsv"

declare -A COPIADOS=()

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
erro() { log "ERRO: $*" >&2; return 1; }

interromper_cron_anterior() {
    local pid inicio atual sid cmd

    [[ -r "$ESTADO/cron.pid" ]] || return 1
    read -r pid inicio < "$ESTADO/cron.pid" || return 1

    [[ "$pid" =~ ^[0-9]+$ &&
       "$inicio" =~ ^[0-9]+$ &&
       -r "/proc/$pid/stat" ]] || return 1

    atual="$(awk '{print $22}' "/proc/$pid/stat")"
    sid="$(ps -o sid= -p "$pid" | tr -d '[:space:]')"
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline")"

    # Confere a identidade para nao matar outro processo
    [[ "$atual" == "$inicio" &&
       "$sid" == "$pid" &&
       "$cmd" == *"$(basename "$0")"* &&
       "$cmd" == *" cron"* ]] || return 1

    # Nao interrompe exclusao de midias em andamento
    if [[ -e "$ESTADO/limpeza_critica_$pid" ]]; then
        log "CRON_ANTERIOR_EM_LIMPEZA: pid=$pid; nao interrompido"
        return 1
    fi

    log "ENCERRANDO_CRON_ANTERIOR pid=$pid"

    # Encerra toda a sessao anterior, inclusive curls filhos
    kill -TERM -- "-$pid" || return 1

    if flock -w 4 9; then
        return 0
    fi

    # Se necessario, forca o encerramento da mesma sessao
    if [[ -r "/proc/$pid/stat" &&
          "$(awk '{print $22}' "/proc/$pid/stat")" == "$inicio" ]]; then
        kill -KILL -- "-$pid" 2>/dev/null || true
    fi

    flock -w 5 9
}

finalizar() {
    local pid inicio

    [[ -z "${TMP:-}" ]] || rm -rf -- "$TMP"

    # Remove o registro somente se esta execucao for a proprietaria
    if [[ "${MODO:-}" == cron && -f "$ESTADO/cron.pid" ]]; then
        read -r pid inicio < "$ESTADO/cron.pid" || true

        if [[ "${pid:-}" == "$$" &&
              "${inicio:-}" == "${CRON_START:-}" ]]; then
            rm -f "$ESTADO/cron.pid" \
                  "$ESTADO/limpeza_critica_$$"
        fi
    fi
}

preparar() {
    local dep
    MODO="${1:-}"

    for dep in curl jq jpeginfo exiftool flock stat date sort comm \
               cmp mktemp ps setsid; do
        command -v "$dep" >/dev/null || {
            erro "Dependencia ausente: $dep"
            return 1
        }
    done

    mkdir -p "$ESTADO/tentativas" "$ESTADO/slots" "$BACKUP"
    chmod 700 "$ESTADO"

    exec 9>"$ESTADO/execucao.lock"

    # Serializa a inicializacao de dois crons concorrentes
    if [[ "$MODO" == cron ]]; then
        exec 8>"$ESTADO/cron-start.lock"
        flock -x 8
    fi

    if ! flock -n 9; then
        if [[ "$MODO" != cron ]] ||
           ! interromper_cron_anterior; then

            log "ROTINA_OCUPADA: execucao manual ou cron nao interrompido"
            return 1
        fi
    fi

    if [[ "$MODO" == cron ]]; then
        CRON_START="$(awk '{print $22}' "/proc/$$/stat")"

        printf '%s %s\n' "$$" "$CRON_START" \
            > "$ESTADO/cron.pid"

        flock -u 8
        exec 8>&-
    fi

    TMP="$(mktemp -d "$ESTADO/tmp.XXXXXXXX")"

    trap finalizar EXIT
    trap 'exit 143' TERM INT

    touch "$INDICE" "$CAPTURAS"
}

verificar_backup() {
    [[ -d "$BACKUP" && -w "$BACKUP" ]] || {
        erro "Diretorio de backup ausente ou sem permissao de escrita: $BACKUP"
        return 1
    }
}

comando() {
    local endereco="${URL}/$1?t=${GOPRO_SENHA}"
    [[ -z "${2:-}" ]] || endereco+="&p=$2"

    curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
        --connect-timeout 5 --max-time 20 "$endereco" -o /dev/null
}

verificar_conexao() {
    local tentativa

    for tentativa in 1 2 3; do
        if curl --noproxy '*' --interface "$WIFI_IFACE" -fsS \
            --connect-timeout 3 --max-time 7 \
            "${URL}/bacpac/sd" -o /dev/null 2>/dev/null; then

            log "GOPRO_ONLINE ip=$GOPRO_IP"
            return 0
        fi

        if (( tentativa < 3 )); then
            log "GOPRO_SEM_RESPOSTA tentativa=$tentativa/3; tentando novamente"
            sleep 2
        fi
    done

    erro "GOPRO_OFFLINE ip=$GOPRO_IP apos 3 tentativas"
}

desligar_bip() {
    comando camera/BS '%00'
    log 'BIP_DESLIGADO'
}

acertar_relogio() {
    local aa mm dd hh mi ss v byte payload=""
    read -r aa mm dd hh mi ss <<< "$(date '+%y %m %d %H %M %S')"

    for v in "$aa" "$mm" "$dd" "$hh" "$mi" "$ss"; do
        printf -v byte '%%%02x' "$((10#$v))"
        payload+="$byte"
    done

    comando camera/TM "$payload"
    log 'RELOGIO_SINCRONIZADO'
}

# ===== INVENTARIO =====

listar_midias() {
    local saida="$1" tentativa http

    for tentativa in 1 2 3; do
        http="$(curl --noproxy '*' --interface "$WIFI_IFACE" -LsS \
            --connect-timeout 5 --max-time 30 \
            -o "$saida" -w '%{http_code}' \
            "${MEDIA_URL}/gp/gpMediaList")" || http='000'

        if [[ "$http" == 200 ]] && jq -e '
            (.media | type == "array") and
            all(.media[];
                (.d | type == "string") and
                (.fs | type == "array")
            )
        ' "$saida" >/dev/null 2>&1; then
            return 0
        fi

        log "INVENTARIO_FALHOU http=$http tentativa=$tentativa/3"
        [[ "$tentativa" == 3 ]] || sleep 3
    done

    return 1
}

# Expande fotos agrupadas de timelapses antigos ainda no cartao.
inventario_tsv() {
    jq -r '
        .media[] | .d as $pasta | .fs[] |
        if (has("g") or has("b") or has("l")) then
            if (has("g") and has("b") and has("l") and
                (.n | test("^G[0-9]{7}\\.JPG$"))) then

                . as $grupo |
                range(
                    ($grupo.b | tonumber);
                    (($grupo.l | tonumber) + 1)
                ) as $n |

                [
                    $pasta,
                    (
                        $grupo.n[0:4] +
                        ("0000" + ($n | tostring))[-4:] +
                        ".JPG"
                    ),
                    "0"
                ] | @tsv
            else
                error("Grupo de midias nao suportado")
            end
        else
            [$pasta, .n, (.s // 0 | tostring)] | @tsv
        end
    ' "$1" | sort -u > "$2"
}

origens_tsv() {
    awk -F '\t' 'NF >= 2 {print $1 "/" $2}' "$1" |
        sort -u > "$2"
}

# Identifica fotos cujo obturador respondeu, mas o inventario falhou em seguida.
reconciliar_tentativas() {
    local inventario="$1" antes meta slot novas n origem tipo instante

    origens_tsv "$inventario" "$TMP/todas.txt"

    for antes in "$ESTADO"/tentativas/*.antes; do
        [[ -f "$antes" ]] || continue

        slot="$(basename "$antes" .antes)"
        meta="$ESTADO/tentativas/$slot.meta"
        [[ -f "$meta" ]] || continue

        novas="$(comm -13 "$antes" "$TMP/todas.txt")"
        n="$(printf '%s\n' "$novas" | sed '/^$/d' | wc -l)"

        if [[ "$n" -eq 1 ]]; then
            IFS=$'\t' read -r tipo instante < "$meta"
            origem="$novas"

            printf '%s\t%s\t%s\n' \
                "$origem" "$tipo" "$instante" >> "$CAPTURAS"

            rm -f "$antes" "$meta"
            log "FOTO_IDENTIFICADA origem=$origem tipo=$tipo"

        elif [[ "$n" -gt 1 ]]; then
            log "AVISO: tentativa $slot tem $n arquivos novos; identificacao manual necessaria"
        fi
    done
}

# ===== DISPARO =====
luz_auxiliar() {
    local comando="${1:-}"
    [[ "$comando" == "ON" || "$comando" == "OFF" ]] || return 2

    [[ -f /etc/etomada-server.conf ]] || return 0
    source /etc/etomada-server.conf

    [[ -n "${LUZ_AUXILIAR_ID:-}" ]] || return 0

    /usr/local/bin/serverAPI.sh resources/${LUZ_AUXILIAR_ID}/commands \
            POST "{\"command\":\"$comando\"}" &> /dev/null

    log "Luz auxiliar: ${comando}"
}

preparar_foto_unica() {
    # Para qualquer captura anterior e sai do modo timelapse.
    comando bacpac/SH '%00' || return 1
    sleep 1

    comando camera/CM '%01' || return 1
    sleep 1

    comando camera/CS '%00' || return 1
    sleep 1

    log 'MODO_FOTO_UNICA_CONFIGURADO'
}

foto_unica() {
    local tipo="$1" slot="$2" instante
    local antes="$ESTADO/tentativas/$slot.antes"
    local meta="$ESTADO/tentativas/$slot.meta"

    if [[ -e "$ESTADO/slots/$slot" ]]; then
        log "FOTO_JA_TENTADA slot=$slot"
        return 0
    fi

    # Configura foto unica antes de consultar o cartao ou disparar.
    preparar_foto_unica || {
        erro 'Nao foi possivel selecionar foto unica'
        return 1
    }

    listar_midias "$TMP/antes.json" || {
        erro 'Inventario indisponivel antes da foto'
        return 1
    }

    inventario_tsv "$TMP/antes.json" "$TMP/antes.tsv" || return 1
    reconciliar_tentativas "$TMP/antes.tsv"
    origens_tsv "$TMP/antes.tsv" "$antes"

    instante="$(date '+%Y%m%d_%H%M%S')"
    printf '%s\t%s\n' "$tipo" "$instante" > "$meta"

    # Nao repetimos um obturador de resultado incerto.
    touch "$ESTADO/slots/$slot"

    [[ "$tipo" == "AVULSA" || "$tipo" == "MANUAL" ]] && {
        luz_auxiliar ON
        sleep 1
    }

    comando bacpac/SH '%01' || {
        erro 'Obturador sem confirmacao; nao repetir automaticamente'
        return 1
    }

    log "FOTO_DISPARADA tipo=$tipo slot=$slot"
    [[ "$tipo" == "AVULSA" || "$tipo" == "MANUAL" ]] && {
        sleep 1
        luz_auxiliar OFF
    }
    sleep 3

    if listar_midias "$TMP/depois.json" &&
        inventario_tsv "$TMP/depois.json" "$TMP/depois.tsv"; then
        reconciliar_tentativas "$TMP/depois.tsv"
    else
        log "AVISO: foto disparada, identificacao pendente para proxima execucao"
    fi
}

# ===== NOME E DESTINO =====

# Pastas representam o ciclo iniciado as 22h;
# 00h-21h59 pertence ao dia anterior.
ciclo_da_foto() {
    local data="${1:0:8}" hora="${1:9:2}"
    local iso="${data:0:4}-${data:4:2}-${data:6:2}"

    if (( 10#$hora >= 22 )); then
        printf '%s\n' "$iso"
    else
        date -d "$iso - 1 day" '+%F'
    fi
}

carregar_indice() {
    local origem tamanho caminho
    COPIADOS=()

    while IFS=$'\t' read -r origem tamanho caminho; do
        [[ -n "${origem:-}" && -n "${caminho:-}" ]] || continue
        COPIADOS["$origem"]="$tamanho"$'\t'"$caminho"
    done < "$INDICE"
}

jpeg_valido() {
    local arquivo="$1" esperado="$2" bytes

    [[ -s "$arquivo" && "$esperado" =~ ^[0-9]+$ ]] || return 1

    bytes="$(stat -c %s "$arquivo")" || return 1

    # Verifica se o JPEG pode ser decodificado
    jpeginfo -c "$arquivo" >/dev/null 2>&1 || return 1

    if (( esperado > 0 && bytes != esperado )); then
        # Aceita diferenca de apenas um byte, com fim de JPEG intacto
        (( esperado == bytes + 1 )) || return 1

        [[ "$(tail -c 2 "$arquivo" |
            od -An -tx1 | tr -d '[:space:]')" == ffd9 ]] || return 1
    fi

    return 0
}

# Salva o JPEG primeiro como .part;
# publica o nome final somente apos validacao.
baixar_foto() {
    local origem="$1" esperado="$2" destino="$3"
    local tentativa bytes http rc

    mkdir -p "$(dirname "$destino")" || return 1

    for tentativa in 1 2; do
        rm -f "$destino.part"
        rc=0

        http="$(curl --noproxy '*' --interface "$WIFI_IFACE" -fLsS \
            --retry 0 --connect-timeout 5 --max-time 30 \
            -w '%{http_code}' \
            "${MEDIA_URL}/videos/DCIM/${origem}" \
            -o "$destino.part")" || rc=$?

        bytes=0
        [[ ! -f "$destino.part" ]] ||
            bytes="$(stat -c %s "$destino.part")"

        log "DOWNLOAD_RESPOSTA origem=$origem tentativa=$tentativa http=$http curl_rc=$rc bytes=$bytes esperado=$esperado"

        # Mesmo com timeout, aceita o JPEG se estiver integro
        if [[ "$http" == 200 ]] &&
           jpeg_valido "$destino.part" "$esperado"; then

            if (( rc != 0 )); then
                log "AVISO: curl_rc=$rc, mas JPEG foi validado"
            fi

            mv -f -- "$destino.part" "$destino"

            log "DOWNLOAD_OK origem=$origem bytes=$bytes destino=$destino"
            return 0
        fi

        [[ "$tentativa" == 2 ]] || sleep 1
    done

    erro "DOWNLOAD_INVALIDO origem=$origem; preservado $destino.part"
}

# Importa o que ainda estiver no SD. Pula os itens ja copiados.
sincronizar_fotos() {
    local pasta nome tamanho origem linha caminho instante tipo data ciclo destino
    local qt=0
    local limite="${1:-$MAX_FOTOS_SYNC}"

    verificar_backup || return 1

    listar_midias "$TMP/midias.json" || {
        erro 'Inventario indisponivel'
        return 1
    }

    inventario_tsv "$TMP/midias.json" "$TMP/inventario.tsv" || return 1
    reconciliar_tentativas "$TMP/inventario.tsv"
    carregar_indice

    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "${pasta:-}" ]] || continue

        [[ "$pasta" =~ ^[A-Za-z0-9_-]+$ &&
           "$nome" =~ ^[A-Za-z0-9_.-]+\.[Jj][Pp][Ee]?[Gg]$ &&
           "$tamanho" =~ ^[0-9]+$ ]] || {
            erro "Midia nao suportada ou dados invalidos: $pasta/$nome ($tamanho)"
            return 1
        }

        origem="$pasta/$nome"
        linha="${COPIADOS[$origem]:-}"

        if [[ -n "$linha" ]]; then
            IFS=$'\t' read -r data caminho <<< "$linha"
            if [[ "$data" == "$tamanho" && -s "$caminho" ]]; then
                continue
            fi
        fi

        # Limita apenas novos downloads, sem contar fotos ja copiadas
        if (( limite > 0 && qt >= limite )); then
            log "SYNC_LIMITE_ATINGIDO fotos=$qt limite=$limite"
            break
        fi

        # Primeiro baixa em arquivo temporario;
        # data EXIF define o nome definitivo.
        local ciclo_atual agora tmpfoto

        agora="$(date '+%Y%m%d_%H%M%S')"
        ciclo_atual="$(ciclo_da_foto "$agora")"

        mkdir -p "$BACKUP/$ciclo_atual"
        tmpfoto="$BACKUP/$ciclo_atual/.download_${pasta}_${nome}"

        baixar_foto "$origem" "$tamanho" "$tmpfoto" || return 1

        tipo='TL'

        instante="$(exiftool -s3 -d '%Y%m%d_%H%M%S' \
            -DateTimeOriginal "$tmpfoto" 2>/dev/null || true)"

        # Para fotos disparadas pelo script, usa o horario do Raspberry Pi.
        local registro
        registro="$(awk -F '\t' -v id="$origem" \
            '$1==id {print $2 "\t" $3}' "$CAPTURAS" | tail -n 1)"

        if [[ -n "$registro" ]]; then
            IFS=$'\t' read -r tipo instante <<< "$registro"
        fi

        [[ "$instante" =~ ^[0-9]{8}_[0-9]{6}$ ]] || {
            erro "Sem horario confiavel para $origem; preservado $tmpfoto"
            return 1
        }

        ciclo="$(ciclo_da_foto "$instante")"
        destino="$BACKUP/$ciclo/${instante}_${tipo}_${pasta}_${nome}"

        mkdir -p "$(dirname "$destino")"

        if [[ -e "$destino" ]]; then
            # Recupera falha apos mv, antes do registro no indice.
            if cmp -s -- "$tmpfoto" "$destino"; then
                rm -f -- "$tmpfoto"
            else
                erro "Colisao de nome: $destino (nao sobrescrito)"
                return 1
            fi
        else
            mv -- "$tmpfoto" "$destino"
        fi

        printf '%s\t%s\t%s\n' \
            "$origem" "$tamanho" "$destino" >> "$INDICE"

        COPIADOS["$origem"]="$tamanho"$'\t'"$destino"
        ((qt+=1))
    done < "$TMP/inventario.tsv"

    log "SINCRONIZACAO_OK novas=$qt"
}

# ===== LIMPEZA =====

# Limpa o indice apenas apos confirmar cartao vazio.
limpar_cartao() {
    local tentativa

    [[ "$PERMITIR_FORMATACAO" == 1 ]] || {
        erro 'LIMPEZA_BLOQUEADA: PERMITIR_FORMATACAO=0'
        return 1
    }

    # Nao permitir interrupcao durante exclusao do cartao
    if [[ "${MODO:-}" == cron ]]; then
        : > "$ESTADO/limpeza_critica_$$"
    fi

    log 'LIMPEZA_INICIADA: camera/DA (todas as midias do cartao)'

    if ! comando camera/DA; then
        log 'AVISO: resposta incerta de camera/DA; checando inventario'
    fi

    for tentativa in {1..12}; do
        sleep 5

        if listar_midias "$TMP/apos_limpeza.json" &&
            jq -e '([.media[]?.fs[]?] | length) == 0' \
                "$TMP/apos_limpeza.json" >/dev/null; then

            : > "$INDICE"
            : > "$CAPTURAS"

            rm -f "$ESTADO"/tentativas/*.antes \
                  "$ESTADO"/tentativas/*.meta

            log 'CARTAO_LIMPO_CONFIRMADO'
            return 0
        fi
    done

    erro 'LIMPEZA_NAO_CONFIRMADA: confira o cartao antes de continuar'
}

# Compara o inventario e testa todos os JPEGs antes da limpeza normal.
validar_backup_para_limpeza() {
    local pasta nome tamanho origem linha esperado caminho

    # Limite 0 significa sincronizar tudo (uso na limpeza manual)
    sincronizar_fotos "${1:-0}" || return 1

    cp "$TMP/inventario.tsv" "$TMP/validado.tsv"

    listar_midias "$TMP/antes_limpeza.json" || return 1
    inventario_tsv "$TMP/antes_limpeza.json" \
        "$TMP/antes_limpeza.tsv" || return 1

    cmp -s "$TMP/validado.tsv" "$TMP/antes_limpeza.tsv" || {
        erro 'Inventario mudou durante o backup; limpeza bloqueada'
        return 1
    }

    carregar_indice

    while IFS=$'\t' read -r pasta nome tamanho; do
        [[ -n "${pasta:-}" ]] || continue

        origem="$pasta/$nome"
        linha="${COPIADOS[$origem]:-}"

        [[ -n "$linha" ]] || {
            erro "Sem copia de $origem"
            return 1
        }

        IFS=$'\t' read -r esperado caminho <<< "$linha"

        [[ "$esperado" == "$tamanho" && -s "$caminho" ]] &&
                jpeg_valido "$caminho" "$tamanho" || {
            erro "JPEG nao validado para exclusao: $origem"
            return 1
        }
    done < "$TMP/validado.tsv"

    # Timelapses antigos: o campo 's' representa o tamanho do grupo.
    local p n b l s soma i membro caminho esperado grupo

    jq -r '
        .media[] | .d as $p | .fs[] |
        select(has("g") and has("b") and has("l")) |
        [$p,.n,.b,.l,.s] | @tsv
    ' "$TMP/antes_limpeza.json" > "$TMP/grupos.tsv" || return 1

    while IFS=$'\t' read -r p n b l s; do
        [[ -n "${p:-}" ]] || continue

        [[ "$n" =~ ^G[0-9]{7}\.JPG$ &&
           "$b" =~ ^[0-9]+$ &&
           "$l" =~ ^[0-9]+$ &&
           "$s" =~ ^[0-9]+$ ]] || return 1

        soma=0

        for ((i=10#$b; i<=10#$l; i++)); do
            printf -v membro '%s%04d.JPG' "${n:0:4}" "$i"
            grupo="$p/$membro"
            linha="${COPIADOS[$grupo]:-}"

            [[ -n "$linha" ]] || {
                erro "Grupo incompleto: $grupo"
                return 1
            }

            IFS=$'\t' read -r esperado caminho <<< "$linha"
            soma=$((soma + $(stat -c %s "$caminho")))
        done

        [[ "$soma" -eq "$s" ]] || {
            erro "GRUPO_INCOMPLETO $n esperado=$s recebido=$soma"
            return 1
        }
    done < "$TMP/grupos.tsv"

    log 'BACKUP_VALIDADO_PARA_LIMPEZA'
}

limpar_interativo() {
    local modo="${1:-}" confirmacao

    [[ -z "$modo" || "$modo" == force ]] || {
        erro "Argumento invalido: $modo"
        return 2
    }

    [[ "$PERMITIR_FORMATACAO" == 1 ]] || {
        erro 'LIMPEZA_CANCELADA: PERMITIR_FORMATACAO=0'
        return 1
    }

    [[ -t 0 ]] || {
        erro 'LIMPEZA_CANCELADA: requer terminal'
        return 1
    }

    if [[ "$modo" == force ]]; then
        printf 'PERIGO: limpar force APAGA O CARTAO SEM BACKUP OU VALIDACAO.\n'
    else
        printf 'Limpeza normal: sincroniza, valida todas as fotos e APAGA O CARTAO.\n'
    fi

    read -r -p 'Digite sim para confirmar: ' confirmacao || return 1

    [[ "$confirmacao" == sim ]] || {
        erro 'LIMPEZA_CANCELADA: confirmacao diferente de sim'
        return 1
    }

    verificar_conexao || return 1

    if [[ "$modo" != force ]]; then
        validar_backup_para_limpeza || return 1
    fi

    limpar_cartao
}

# ===== AGENDAMENTO =====


rotina() {
    local hora minuto tipo slot marcador
    hora="$(date +%H)"
    minuto="$(date +%M)"

    verificar_conexao || return 1

    # Capturas normais: 22h ate 15h58, a cada 2 minutos
    if (( 10#$hora >= 22 || 10#$hora < 16 )); then
        if (( 10#$minuto % 2 == 0 )); then
            tipo=TL
            slot="$(date '+%Y%m%d_%H%M')"

            if [[ "$hora" == 22 && "$minuto" == 00 ]]; then
                acertar_relogio || return 1
            fi

            foto_unica "$tipo" "$slot" ||
                log "AVISO: falha no disparo do slot $slot"
        fi

    # Capturas avulsas: 17h, 18h, 19h, 20h e 21h
    elif (( 10#$hora >= 17 && 10#$hora <= 21 &&
            10#$minuto == 0 )); then

        tipo=AVULSA
        slot="$(date '+%Y%m%d_%H%M')"

        foto_unica "$tipo" "$slot" ||
            log "AVISO: falha no disparo avulso do slot $slot"
    fi

    # Limpeza diaria: primeira execucao bem-sucedida entre 00h e 00h59
    if [[ "$hora" == 00 ]]; then
        marcador="$ESTADO/limpeza_$(date +%F).ok"

        if [[ -e "$marcador" ]]; then
            sincronizar_fotos

        elif [[ "$PERMITIR_FORMATACAO" != 1 ]]; then
            sincronizar_fotos || return 1
            log "AVISO: limpeza diaria bloqueada (PERMITIR_FORMATACAO=0)"

        else
            log "LIMPEZA_DIARIA: sincronizando e validando cartao"

            # Sincroniza e valida tudo que ainda estiver no cartao
            validar_backup_para_limpeza "$MAX_FOTOS_SYNC" || {
                erro "LIMPEZA_DIARIA_CANCELADA: backup nao validado; cartao preservado"
                return 1
            }

            # Apaga somente depois da validacao completa
            limpar_cartao || return 1

            # Marca a limpeza concluida para nao repetir no mesmo dia
            : > "$marcador"

            log "LIMPEZA_DIARIA_OK: cartao zerado; backup preservado no Raspberry Pi"
        fi

    else
        # Nas demais horas, somente sincroniza
        sincronizar_fotos
    fi
}


uso() {
    echo "Uso: $0 [cron|status|foto|sincronizar|relogio|bip-off|limpar [force]]"
}

main() {
    preparar "${1:-}" || return 1

    case "${1:-}" in
        cron)
            rotina
            ;;
        status)
            verificar_conexao
            ;;
        foto)
            verificar_conexao || return 1
            foto_unica "${2:-MANUAL}" \
                "manual_$(date '+%Y%m%d_%H%M%S')" || return 1
            sincronizar_fotos
            ;;
        sincronizar)
            verificar_conexao && sincronizar_fotos
            ;;
        relogio)
            verificar_conexao && acertar_relogio
            ;;
        bip-off)
            verificar_conexao && desligar_bip
            ;;
        limpar)
            limpar_interativo "${2:-}"
            ;;
        *)
            uso
            return 2
            ;;
    esac
}

# Cada cron roda em uma sessao isolada, permitindo encerrar
# o script anterior e todos os seus subprocessos.
if [[ "${1:-}" == cron &&
      "${GOPRO_CRON_WORKER:-0}" != 1 ]]; then
    exec env GOPRO_CRON_WORKER=1 setsid -w bash "$0" "$@"
fi

main "$@"
