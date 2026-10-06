FROM python:3.12-slim
RUN ln -sf /usr/local/bin/python3 /usr/bin/python3
RUN useradd --uid 10001 --create-home runner
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
COPY templates ./templates
USER runner
ENV PORT=5000 MAX_CONCURRENT=2
EXPOSE 5000
CMD ["gunicorn","app:app","--workers","1","--threads","4","--bind","0.0.0.0:5000","--timeout","30"]
