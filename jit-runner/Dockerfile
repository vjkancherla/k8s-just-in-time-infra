FROM debian:bookworm-slim

WORKDIR /opt/jit-runner

RUN apt-get update && apt-get install -y wget unzip python3 python3-pip python3-venv curl jq bash && rm -rf /var/lib/apt/lists/*

RUN wget -qO /tmp/tofu.zip https://github.com/opentofu/opentofu/releases/download/v1.8.1/tofu_1.8.1_linux_arm64.zip && \
    unzip -q /tmp/tofu.zip -d /usr/local/bin && rm /tmp/tofu.zip && \
    chmod +x /usr/local/bin/tofu

COPY requirements.txt .
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --upgrade pip && \
    /opt/venv/bin/pip install -r requirements.txt

COPY main.py .

EXPOSE 8080

CMD ["/opt/venv/bin/uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]