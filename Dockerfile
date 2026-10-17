FROM debian:latest AS builder
RUN sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && apt-get install -y ca-certificates curl gnupg pkg-config build-essential libssl-dev && \
    rm -rf /var/lib/apt/lists/*

# 导入 NodeSource 官方 GPG Key 并配置 Node.js 20.x 仓库
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" > /etc/apt/sources.list.d/nodesource.list && \
    apt-get update && apt-get install -y nodejs && \
    rm -rf /var/lib/apt/lists/*

RUN npm config set registry https://registry.npmmirror.com

ENV RUSTUP_DIST_SERVER=https://mirrors.ustc.edu.cn/rust-static \
    RUSTUP_UPDATE_ROOT=https://mirrors.ustc.edu.cn/rust-static/rustup

RUN curl --proto '=https' --tlsv1.2 -sSf https://mirrors.ustc.edu.cn/misc/rustup-install.sh | sh -s -- -y && \
    . /root/.cargo/env && rustup target add x86_64-unknown-linux-gnu

RUN mkdir -vp ${CARGO_HOME:-$HOME/.cargo} && \
    printf '%s\n' \
    '[source.crates-io]' "replace-with = 'ustc'" '' \
    '[source.ustc]' 'registry = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"' '' \
    '[registries.ustc]' 'index = "sparse+https://mirrors.ustc.edu.cn/crates.io-index/"' \
    | tee -a ${CARGO_HOME:-$HOME/.cargo}/config.toml

WORKDIR /app
COPY . /app
RUN . /root/.cargo/env && npm run build

# ── Runtime image ──────────────────────────────────────────────────────────────
FROM debian:latest
RUN sed -i 's/deb.debian.org/mirrors.ustc.edu.cn/g' /etc/apt/sources.list.d/debian.sources && \
    apt-get update && apt-get install -y ffmpeg ca-certificates libssl3 && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app/stripchat-recorder/logs \
             /app/stripchat-recorder/recordings \
             /app/stripchat-recorder/modules.default \
             /app/stripchat-recorder/modules \
             /app/stripchat-recorder/config
WORKDIR /app

COPY --from=builder /app/build/stripchat-recorder /app/stripchat-recorder/
COPY --from=builder /app/build/modules/ /app/stripchat-recorder/modules.default/
COPY --from=builder /app/config/ /app/stripchat-recorder/config/

RUN chmod +x /app/stripchat-recorder/stripchat-recorder

RUN printf '%s\n' \
    '#!/bin/sh' \
    'set -eu' \
    '# 1. 启动时自动从 Cloudflare Worker 拉取最新配置到本地' \
    'if [ -n "${CF_CONFIG_URL:-}" ] && [ -n "${CF_TOKEN:-}" ]; then' \
    '    echo "Fetching config from Cloudflare..."' \
    '    curl -s -H "Authorization: Bearer ${CF_TOKEN}" "${CF_CONFIG_URL}" -o /app/stripchat-recorder/config/settings.json || true' \
    'fi' \
    'cp -an /app/stripchat-recorder/modules.default/. /app/stripchat-recorder/modules/' \
    'if [ -f /app/stripchat-recorder/config/settings.json ]; then' \
    '    if [ -n "${LANGUAGE:-}" ]; then' \
    '        sed -i "s/\"language\": \"[^\"]*\"/\"language\": \"${LANGUAGE}\"/" /app/stripchat-recorder/config/settings.json' \
    '    fi' \
    '    if [ -n "${PORT:-}" ]; then' \
    '        sed -i "s/\"server_port\": [0-9]*/\"server_port\": ${PORT}/" /app/stripchat-recorder/config/settings.json' \
    '    fi' \
    'fi' \
    'exec /app/stripchat-recorder/stripchat-recorder "$@"' \
    > /entrypoint.sh && chmod +x /entrypoint.sh

VOLUME ["/app/stripchat-recorder/logs", "/app/stripchat-recorder/recordings", "/app/stripchat-recorder/modules", "/app/stripchat-recorder/config"]
EXPOSE ${PORT:-3030}
ENTRYPOINT ["/entrypoint.sh"]
