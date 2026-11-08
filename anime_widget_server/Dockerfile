ARG BUILD_FROM
FROM ${BUILD_FROM}

# Stdlib-only Python app: no pip dependencies needed.
RUN apk add --no-cache python3 tzdata

COPY app /app

CMD [ "python3", "-u", "/app/server.py" ]
