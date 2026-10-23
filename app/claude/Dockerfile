#######################
# build base image
######################
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

# install system packages
RUN sed -i 's@http://archive.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's@http://security.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y curl ca-certificates tcsh wget gnupg gpg gosu sudo unzip \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# install fonts
RUN sed -i 's@http://archive.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's@http://security.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y fontconfig language-pack-zh-hans locales fonts-wqy-microhei \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# 下载并安装编程字体（以 JetBrains Mono 为例，支持 Unicode 和连字）
RUN mkdir -p /usr/share/fonts/programming-fonts \
    && curl -fsSL https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip -o /tmp/fonts.zip \
    && unzip /tmp/fonts.zip -d /tmp/fonts \
    && cp /tmp/fonts/fonts/ttf/*.ttf /usr/share/fonts/programming-fonts/ \
    && rm -rf /tmp/fonts.zip /tmp/fonts \
    && fc-cache -fv


# install claude
RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN npm install --registry=https://registry.npmmirror.com/ -g @anthropic-ai/claude-code

RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor --batch --yes -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y python3-pip poppler-utils pandoc texlive-latex-base texlive-latex-extra texlive-xetex \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


# pdf python packages 
RUN pip3 install \
    pypdf pdfplumber defusedxml openpyxl openpyxl markitdown[all] \
    -i https://mirrors.aliyun.com/pypi/simple/ --break-system-packages 

RUN locale-gen zh_CN.UTF-8
ENV LANG=zh_CN.UTF-8 \
    LANGUAGE=zh_CN:zh \
    LC_ALL=zh_CN.UTF-8

RUN chmod 644 /usr/share/fonts/programming-fonts/*.ttf \
    && ls -l /usr/share/fonts/programming-fonts/* \
    && fc-cache -fv \
    && fc-list

ARG HOME=/home/ubuntu

COPY resource/claude.json $HOME/.claude.json
RUN chown ubuntu:ubuntu $HOME/.claude.json

COPY entrypoint.sh /entrypoint.sh
RUN chmod 777 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

WORKDIR /home/ubuntu/workspace
