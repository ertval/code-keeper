# syntax=docker/dockerfile:1
FROM alpine:3.23

WORKDIR /usr/src/app

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apk add --no-cache \
    python3 \
    py3-pip \
    py3-psycopg2

# Security: Create non-root unprivileged service user
RUN addgroup -g 10001 -S appgroup && \
    adduser -u 10001 -S appuser -G appgroup

COPY requirements.txt .
RUN pip install --no-cache-dir --break-system-packages -r requirements.txt

COPY server.py .
COPY app/ ./app/

RUN chown -R appuser:appgroup /usr/src/app

EXPOSE 8080

USER appuser

HEALTHCHECK --interval=10s --timeout=5s --start-period=30s --retries=6 \
    CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')" || exit 1

CMD ["python3", "server.py"]
