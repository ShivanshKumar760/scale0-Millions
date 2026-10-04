FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
RUN useradd --system app && chown -R app /app
USER app
EXPOSE 8000
# gunicorn reads the WEB_CONCURRENCY environment variable for its worker count
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--timeout", "30", "--access-logfile", "-", "wsgi:app"]