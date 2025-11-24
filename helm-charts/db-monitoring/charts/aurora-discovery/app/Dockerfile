# Use Python 3.11 slim image as base for smaller size and security
FROM python:3.11-slim

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies required for Python packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libc6-dev \
    && rm -rf /var/lib/apt/lists/*

# Create non-root user for security
RUN groupadd --gid 1000 aurora && \
    useradd --uid 1000 --gid aurora --shell /bin/bash --create-home aurora

# Set working directory
WORKDIR /app

# Copy requirements first for better Docker layer caching
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY *.py ./

# Create entrypoint script
COPY entrypoint.sh ./
RUN chmod +x entrypoint.sh

# Change ownership of the app directory to aurora user
RUN chown -R aurora:aurora /app

# Switch to non-root user
USER aurora

# Expose health check port (if needed)
EXPOSE 8080

# Set entrypoint
ENTRYPOINT ["./entrypoint.sh"]

# Default command
CMD ["python", "main.py"]