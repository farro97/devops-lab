# syntax=docker/dockerfile:1
# -----------------------------------------------------------------------------
# Multi-stage build:
#   1. "build" stage installs dependencies into a virtualenv
#   2. "runtime" stage copies only the virtualenv + app code
# The final image has no pip cache or build tools, so it's smaller and
# gives security scanners (Trivy, ECR scan) less to complain about.
# -----------------------------------------------------------------------------

FROM python:3.13-slim AS build

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install -r requirements.txt


FROM python:3.13-slim AS runtime

# Pull in OS security patches available since the base image was published.
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/*

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8000

# Never run containers as root.
RUN useradd --create-home --uid 10001 appuser

WORKDIR /srv
COPY --from=build /opt/venv /opt/venv
COPY app ./app

USER appuser

EXPOSE 8000

# Container-level health check (ECS can use this too). Uses Python so we
# don't need to install curl in the image.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c "import os,urllib.request; urllib.request.urlopen(f'http://127.0.0.1:{os.environ[\"PORT\"]}/health', timeout=3)" || exit 1

# `exec` makes uvicorn PID 1, so it receives SIGTERM from ECS and shuts
# down gracefully during deployments.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --proxy-headers"]
