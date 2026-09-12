# syntax=docker/dockerfile:1
FROM alpine:3.23

WORKDIR /usr/src/app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apk add --no-cache \
    python3 \
    py3-pip

# Security: Create non-root unprivileged service user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S appuser -G appgroup

COPY requirements.txt .
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt

COPY server.py openapi.yaml ./
COPY app/ ./app/

RUN mkdir -p /usr/src/logs && \
    chown -R appuser:appgroup /usr/src/app /usr/src/logs

EXPOSE 3000

USER appuser

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=6 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:3000/health')" || exit 1

CMD ["python3", "server.py"]
