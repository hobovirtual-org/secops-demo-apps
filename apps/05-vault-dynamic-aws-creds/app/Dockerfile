FROM registry.redhat.io/ubi9/python-311-minimal:latest

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

USER 1001
ENV PORT=8080
EXPOSE 8080
CMD ["python", "app.py"]
