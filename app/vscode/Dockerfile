#######################
# build base image
######################
FROM ubuntu:24.04 AS base

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai

RUN sed -i 's@http://archive.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's@http://security.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y curl wget gpg gosu \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*


####################
# build vscode image
####################
FROM base AS vscode

RUN sed -i 's@http://archive.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's@http://security.ubuntu.com@http://mirrors.aliyun.com@g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get remove --purge fcitx \
    && apt-get autoremove \ 
    && apt-get install -y fcitx5 fcitx5-chinese-addons fcitx5-configtool fcitx5-frontend-gtk3 fcitx5-frontend-gtk4 dbus-x11 \
    fonts-noto-cjk fonts-wqy-zenhei fonts-wqy-microhei fontconfig locales \
    && locale-gen zh_CN.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO- https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > /usr/share/keyrings/packages.microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/packages.microsoft.gpg] https://packages.microsoft.com/repos/vscode stable main" | tee /etc/apt/sources.list.d/vscode.list \
    && apt-get update \
    && apt-get install -y code \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

ARG HOME=/home/ubuntu

ENV LANG=en_US.UTF-8
ENV LC_CTYPE=zh_CN.UTF-8
ENV GTK_IM_MODULE=fcitx
ENV QT_IM_MODULE=fcitx
ENV XMODIFIERS=@im=fcitx
ENV DefaultIMModule=fcitx

COPY entrypoint.sh /entrypoint.sh
RUN chmod 777 /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

WORKDIR /home/ubuntu

