ARG UBUNTU_VERSION=25.10

FROM ubuntu:${UBUNTU_VERSION}

ARG USERNAME=vscode
ARG USER_UID=1000
ARG USER_GID=$USER_UID

RUN userdel --force --remove ubuntu 2>/dev/null || true && \
	groupadd --gid $USER_GID $USERNAME && \
	useradd --create-home --shell /bin/bash --uid $USER_UID --gid $USER_GID $USERNAME

RUN apt-get update && apt-get install -y \
	bash-completion \
	bat \
	curl \
	direnv \
	file \
	git \
	jq \
	shellcheck \
	shfmt \
	ripgrep

RUN curl -fsSL https://github.com/tamasfe/taplo/releases/latest/download/taplo-linux-x86_64.gz \
	| gzip -d - | install -m 755 /dev/stdin /usr/local/bin/taplo

RUN (type -p wget >/dev/null || (apt update && apt install wget -y)) \
	&& mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& apt update \
	&& apt install gh -y \
	&& rm -fr $out

RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && \
	apt update && \
	apt install -y nodejs

RUN npm install -g \
	opencode-ai \
	@google/gemini-cli

RUN apt install zig -y
RUN mkdir -p /home/$USERNAME/.config /home/$USERNAME/.local/share && \
	chown -R $USERNAME:$USERNAME /home/$USERNAME/.config /home/$USERNAME/.local

USER $USERNAME
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root

RUN apt install -y --no-install-recommends \
	libasound2-dev \
	libgl1-mesa-dev \
	libglu1-mesa-dev \
	libwayland-dev \
	libx11-dev \
	libxcb-composite0-dev \
	libxcb-damage0-dev \
	libxcb-image0-dev \
	libxcb-util0-dev \
	libxcb1-dev \
	libxcursor-dev \
	libxi-dev \
	libxinerama-dev \
	libxkbcommon-dev \
	libx11-xcb-dev \
	libglfw3-dev \
	libxrandr-dev \
	libxcb-keysyms1-dev
