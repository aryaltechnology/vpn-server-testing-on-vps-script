# 1. Build Environment
FROM dart:stable AS build

WORKDIR /app

# Copy dependency info
COPY pubspec.* ./
RUN dart pub get

# Copy source code
COPY . .

# Compile the app to a binary
RUN dart compile exe bin/server.dart -o bin/server

# -----------------------------------------------

# 2. Runtime Environment (Lightweight Linux)
FROM debian:bookworm-slim

# Install runtime dependencies
# - openvpn: To connect
# - curl: For IP checks
# - sudo: To support existing code calls (Process.start('sudo'...))
# - iproute2: For 'ip' command
# - net-tools: For 'ifconfig' command
# - procps: For 'pkill'
RUN apt-get update && apt-get install -y \
    openvpn \
    curl \
    sudo \
    iproute2 \
    net-tools \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Setup 'root' to use sudo without password (so Dart code works as is)
RUN echo "root ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /app

# Copy compiled binary from build stage
COPY --from=build /app/bin/server /app/bin/server

# Copy .env (Will be injected by CI/CD, but needed for structure)
COPY .env /app/.env

# Expose the API port
EXPOSE 8080

# Command to start
CMD ["/app/bin/server"]