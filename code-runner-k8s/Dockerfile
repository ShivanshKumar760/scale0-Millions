FROM python:3.12-slim

RUN useradd --uid 10001 --create-home runner
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py runner.py ./
COPY templates ./templates

USER 10001
ENV PORT=5000
EXPOSE 5000

# API role (default). The sandbox Jobs override this with: python -I /app/runner.py
CMD ["gunicorn", "app:app", "--workers", "1", "--threads", "16", "--bind", "0.0.0.0:5000", "--timeout", "60"]