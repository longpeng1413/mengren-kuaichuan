# 猛人快传 v1.7.2 自建 VPS 中转指南

猛人快传不提供公共中转服务器。公网远程功能要求使用者部署自己的 VPS，
并在自己的设备上填写自己的域名、访问令牌和家庭加密口令。

不要填写软件作者或其他人的中转地址，也不要把 VPS 登录密码当作访问令牌。

## 一、准备条件

- 一台可以运行 Docker 的 Linux VPS，以下示例以 Debian 12 为准。
- 一个由你控制的域名，例如 `relay.example.com`。
- 域名 A/AAAA 记录指向你的 VPS。
- VPS 对公网开放 TCP 80 和 443；中转容器端口只监听本机。
- 已安装 Docker、Caddy、Git 和 OpenSSL。

## 二、获取源码并生成访问令牌

```bash
git clone https://github.com/longpeng1413/mengren-kuaichuan.git
cd mengren-kuaichuan
git checkout v1.7.2

MQT_TOKEN="$(openssl rand -hex 32)"
sudo sh -c 'umask 077; : > /etc/mengren-relay.env'
printf 'MQT_RELAY_TOKEN=%s\n' "$MQT_TOKEN" | \
  sudo tee /etc/mengren-relay.env >/dev/null
printf '请立即保存到密码管理器的 VPS 访问令牌：%s\n' "$MQT_TOKEN"
unset MQT_TOKEN
```

访问令牌至少 24 位。它只用于阻止陌生客户端接入中转服务，不是 SSH 密码，
也不能代替家庭加密口令。不要提交到 Git、镜像、截图或公开日志。

## 三、构建并启动中转容器

必须从项目根目录执行：

```bash
docker build -f relay_server/Dockerfile -t mengren-relay:1.7.2 .

docker run -d \
  --name mengren-relay \
  --restart unless-stopped \
  --env-file /etc/mengren-relay.env \
  -e MQT_RELAY_BIND=0.0.0.0 \
  -e MQT_RELAY_PORT=8080 \
  -e MQT_RELAY_DELIVERY_TIMEOUT_SECONDS=120 \
  -p 127.0.0.1:18080:8080 \
  mengren-relay:1.7.2
```

确认容器仅绑定到 VPS 本机：

```bash
curl http://127.0.0.1:18080/healthz
docker ps --filter name=mengren-relay
```

健康接口应返回类似 `{"ok":true,"online":0}`。不要把 18080 直接开放到公网。

## 四、配置域名和 TLS

在 Caddyfile 中添加一个独立站点。把示例域名换成你自己的域名：

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:18080
}
```

检查并重载 Caddy：

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
curl https://relay.example.com/healthz
```

如果 VPS 上已经有网站，只添加新的独立域名站点，不要覆盖原网站配置。

## 五、在 Android 和 Windows 中填写

在猛人快传的“设置 → 公网远程传输”中填写：

- 中转地址：`wss://relay.example.com/v1/relay`
- VPS 访问令牌：第二步生成并保存的令牌
- 家庭加密口令：自行设置的 12–256 位口令

参与传输的所有个人设备必须填写完全相同的三项配置。家庭加密口令只保存在
Android/Windows 系统安全存储中，不会发送给 VPS；可以比较软件显示的家庭口令
校验码，确认各设备填写一致。

## 六、安全与排错

- 只开放 80/443，容器端口保持 `127.0.0.1` 监听。
- 使用随机访问令牌，发现泄露后立即替换 `/etc/mengren-relay.env` 并重建容器。
- 不公开家庭加密口令、访问令牌、SSH 密码或私钥。
- 中转地址必须是 `wss://你的域名/v1/relay`，不能填写健康检查地址。
- 无令牌访问 `/v1/relay` 应返回 HTTP 401。
- 域名证书、DNS 和 Caddy 正常后，设备才会显示“公网 VPS 中转”。
- VPS 只在线转发端到端加密密文，不保存离线消息；双方需要同时在线。

## 七、升级中转服务

先保留旧容器和启动参数，再构建新镜像。候选容器应在备用本机端口完成健康检查，
通过后再切换正式容器。v1.7.2 的服务端默认保留送达回执 120 秒，客户端协议版本为 3。
