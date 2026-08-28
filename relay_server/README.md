# 猛人快传 v1.7.0 在线中转服务

这是不落盘的 WebSocket 在线中转服务。客户端先用家庭口令完成 AES-GCM 端到端加密，服务端只能看到设备 ID、时间、目标设备和密文大小，不能读取文字、链接或文件内容。

## 本地运行

```powershell
$env:MQT_RELAY_TOKEN = '至少24位的随机访问令牌'
$env:MQT_RELAY_BIND = '127.0.0.1'
$env:MQT_RELAY_PORT = '8080'
dart run bin/mengren_relay.dart
```

- 健康检查：`http://127.0.0.1:8080/healthz`
- WebSocket：`ws://127.0.0.1:8080/v1/relay`
- 公网部署必须由 Caddy 或 nginx 提供 TLS，客户端只接受 `wss://`。
- 服务端不保存消息，收件人离线时返回 `recipient_offline`。

## Docker 构建

Dockerfile 的构建上下文必须是项目根目录：

```bash
docker build -f relay_server/Dockerfile -t mengren-relay:1.7.2-ack120 .
docker run -d --name mengren-relay --restart unless-stopped \
  -e MQT_RELAY_TOKEN='至少24位的高强度随机令牌' \
  -e MQT_RELAY_DELIVERY_TIMEOUT_SECONDS=120 \
  -p 127.0.0.1:8080:8080 mengren-relay:1.7.2-ack120
```

公网文件采用有限流水发送。服务端回执记录默认保留 120 秒，可通过
`MQT_RELAY_DELIVERY_TIMEOUT_SECONDS` 设置为 30–600 秒；迟到或重复回执只记录日志，
不再向接收端返回会误导用户的 `unknown_receipt` 错误。

不要把令牌写入仓库、镜像或公开截图。VPS 防火墙只需开放 Caddy 使用的 80/443；8080 保持仅本机访问。

## Caddy 示例

将 `relay.example.com` 换成自己的域名：

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Caddy 自动申请 HTTPS 证书后，应用填写 `wss://relay.example.com/v1/relay`。
