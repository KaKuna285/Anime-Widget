ARG BUILD_FROM
FROM ${BUILD_FROM}

# Stdlib-only Python app: no pip dependencies needed.
RUN apk add --no-cache python3 tzdata

COPY app /app

# with-contenv: give the app the env HA passes in (SUPERVISOR_TOKEN, TZ),
# which s6-overlay otherwise withholds from the CMD.
CMD [ "/usr/bin/with-contenv", "python3", "-u", "/app/server.py" ]
