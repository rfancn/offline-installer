1. 安装`docker-ce`



按照software/docker中的README安装



2\. 导入docker镜像

```
docker load -i xxx
```

3\.  启动docker容器

```
docker compose up -d
```

4\. 浏览器访问`http://服务IP:8080`, 按安装提示完成安装步骤

>>> 安装脚本会提示输入 MySQL root 密码（至少 8 位，回车自动生成），
>>> 并将密码写入服务目录下的 `.env`，供 MySQL 与 ZenTao 容器共同使用。