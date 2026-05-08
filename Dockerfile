FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DATA_DIR=/data

# Drop privileges
RUN groupadd --system --gid 1000 app \
 && useradd  --system --uid 1000 --gid 1000 --home /app --shell /usr/sbin/nologin app \
 && mkdir -p /app /data \
 && chown -R app:app /app /data

WORKDIR /app

COPY --chown=app:app requirements.txt ./
RUN pip install -r requirements.txt

COPY --chown=app:app server.py index.html editor.html ./

USER app:app

EXPOSE 8000
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/api/projects', timeout=2).status == 200 else 1)"

CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
