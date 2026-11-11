# Apple TV now-playing bridge.
# Run with HOST networking: mDNS discovery (and Apple TV connections back to the
# bridge) do not work through Docker's default bridge network.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    ATV_BRIDGE_CONFIG_DIR=/data

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY atv_bridge ./atv_bridge

RUN useradd --system --uid 10001 --home-dir /data --shell /usr/sbin/nologin bridge \
    && mkdir -p /data && chown bridge:bridge /data && chmod 700 /data
USER bridge
VOLUME ["/data"]
EXPOSE 8765

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s \
    CMD python -c "import os,urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/v1/health' % os.environ.get('ATV_BRIDGE_PORT','8765'), timeout=4)" || exit 1

ENTRYPOINT ["python", "-m", "atv_bridge"]
CMD ["serve"]
