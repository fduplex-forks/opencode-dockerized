ARG USER_NAME
ARG USER_UID
ARG OPENCODE_BUILD_TIME

FROM debian:trixie-slim
ARG USER_NAME
ARG USER_UID
ARG OPENCODE_BUILD_TIME

ARG GIT_LFS_INSTALL_SRC="https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh"
ARG DOCKER_REPO="https://download.docker.com/linux/debian"
ARG OPENCODE_INSTALL_SRC="https://opencode.ai/install"
ARG AWS_CLI_SRC="https://awscli.amazonaws.com"

ARG DEBIAN_FRONTEND="noninteractive"

ENV USER_NAME="${USER_NAME}"

# Install base dependencies
RUN bash -e <<EOF
apt-get install -Uy \
    git gh curl ca-certificates sudo zip unzip wget gnupg lsb-release apt-transport-https groff less
rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*
EOF

# Install git-lfs via packagecloud repository
RUN bash -e <<EOF
curl -s "${GIT_LFS_INSTALL_SRC}" | bash
apt-get install -Uy git-lfs
rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*
EOF

# Install Docker CLI only (uses host Docker daemon via mounted socket)
RUN bash -e <<EOF
install -m 0755 -d /etc/apt/keyrings
curl -fsSL "${DOCKER_REPO}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] ${DOCKER_REPO} \
    \$(. /etc/os-release && echo "\$VERSION_CODENAME") stable" \
    | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get install -Uy docker-ce-cli docker-buildx-plugin docker-compose-plugin
rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*
EOF

# Create non-root user
# Note: Docker socket group membership is handled dynamically in entrypoint.sh
# based on the host's actual Docker socket GID
RUN useradd -m -s /bin/bash -u $USER_UID ${USER_NAME} && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
USER ${USER_NAME}

RUN curl -fsSL "${OPENCODE_INSTALL_SRC}" | bash
RUN mkdir -p $HOME/.config/opencode $HOME/.local/share/opencode $HOME/.cache/opencode

WORKDIR /workspace

# Switch back to root for entrypoint setup
USER root

RUN bash <<EOF
cd /usr/local/src
curl "${AWS_CLI_SRC}/awscli-exe-linux-$(uname -m).zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws*
EOF

# ── Python environment (via uv) ──────────────────────────────────────
# uv: fast Python package manager (single static binary, no dependencies)
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv

# Where uv stores the managed Python installation
ENV UV_PYTHON_INSTALL_DIR=/opt/python
# Put python/python3 symlinks in /usr/local/bin (globally available)
ENV UV_PYTHON_BIN_DIR=/usr/local/bin
# Performance: compile bytecode, use copy mode (needed for bind-mounted sources)
ENV UV_COMPILE_BYTECODE=1
ENV UV_LINK_MODE=copy

# Install Python 3.11 with global symlinks (python, python3 → /usr/local/bin)
RUN uv python install 3.11 --default

# Create global virtual environment for packages
# All uv pip install commands target this venv by default via VIRTUAL_ENV
RUN uv venv /opt/venv --python 3.11

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Ensure venv PATH survives login shells (bash -l re-reads /etc/profile which resets PATH)
RUN echo 'export VIRTUAL_ENV=/opt/venv' > /etc/profile.d/python-venv.sh && \
    echo 'export PATH="/opt/venv/bin:$PATH"' >> /etc/profile.d/python-venv.sh && \
    chmod +x /etc/profile.d/python-venv.sh

# Install baseline packages (always available in the container)
RUN uv pip install boto3

# Make the venv world-writable so the runtime user can install packages ad-hoc
# (The actual user UID is determined at runtime via entrypoint.sh)
RUN chmod -R a+rwX /opt/venv

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Set the entrypoint (runs as root, then switches to USER_NAME)
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

CMD ["opencode"]
