FROM registry.redhat.io/ubi9/python-312-minimal:latest

WORKDIR /app

# Install dependencies as root before dropping privileges
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application source
COPY src/ ./src/

# Non-root user (UID 1001 is the default non-root user in UBI images)
USER 1001

WORKDIR /app/src

CMD ["python", "agent.py"]
