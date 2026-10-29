# llama-server (nur CPU) als Backend für Open WebUI und die optionale
# Autovervollständigung.
#
# Basis ist das offizielle llama.cpp-Server-Image. Es enthält alle
# CPU-Varianten (u.a. AVX2, AVX-512) und lädt zur Laufzeit automatisch
# die passende Variante. Ein eigener Build aus dem Quellcode ist daher
# nicht notwendig.
#
# Das Basis-Image wird über LLAMA_CPP_IMAGE in setup.conf festgelegt.
# Für reproduzierbare Builds statt des rollierenden Tags "server" ein
# festes Versions-Tag aus ghcr.io/ggml-org/llama.cpp verwenden.
#
# Gebaut wird das Image von setup.sh, nicht von compose.
ARG LLAMA_CPP_IMAGE=ghcr.io/ggml-org/llama.cpp:server
FROM ${LLAMA_CPP_IMAGE}

# Kennzeichnung, damit cleanup.sh nur eigene Images und Build-Reste entfernt
LABEL io.local-coder.project="local-coder"

ENV LC_ALL=C.utf8

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh \
 && mkdir -p /models

# Modelle werden schreibgeschützt nach /models eingebunden
VOLUME ["/models"]

# 8080 = Chat-API für Open WebUI, 8012 = Autovervollständigung (FIM)
EXPOSE 8080 8012

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
