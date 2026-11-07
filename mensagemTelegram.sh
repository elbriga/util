#!/usr/bin/env bash
# Uso: mensagemTelegram.sh "Mensagem para enviar"
# Configure o bot do etomada-server em /etc/etomada-server.conf:
# TELEGRAM_BOT_TOKEN="seu-token"
# TELEGRAM_CHAT_ID="seu-chat-id"
# Tambem aceita variaveis de ambiente e TELEGRAM_CONFIG para outro arquivo.
set -Eeuo pipefail

if [[ "$#" != 1 || -z "$1" ]]; then
    printf 'Uso: %s "mensagem"\n' "$0" >&2
    exit 2
fi

TELEGRAM_CONFIG="${TELEGRAM_CONFIG:-/etc/etomada-server.conf}"
if [[ -r "$TELEGRAM_CONFIG" ]]; then
    source "$TELEGRAM_CONFIG"
fi

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]]; then
    printf 'Telegram nao configurado: defina TELEGRAM_BOT_TOKEN e TELEGRAM_CHAT_ID.\n' >&2
    exit 1
fi

if (( ${#1} > 4096 )); then
    printf 'Mensagem excede o limite de 4096 caracteres.\n' >&2
    exit 2
fi

# Usa a rota padrao de internet. Oculta erros do curl que podem conter o token.
if ! resposta="$(curl -fsS --connect-timeout 3 --max-time 10 \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=$1" \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    2>/dev/null)"; then
    printf 'Falha ao enviar mensagem pelo Telegram.\n' >&2
    exit 1
fi

if ! jq -e '.ok == true' <<< "$resposta" >/dev/null 2>&1; then
    printf 'Telegram retornou uma resposta invalida ou recusou a mensagem.\n' >&2
    exit 1
fi
