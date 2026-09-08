FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

ENTRYPOINT ["kopf", "run", "main.py", "--insecure", "-l", "INFO"]