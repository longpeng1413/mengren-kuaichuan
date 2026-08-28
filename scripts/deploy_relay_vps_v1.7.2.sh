#!/bin/sh
set -eu

IMAGE="mengren-relay:1.7.2-ack120"
CONTAINER="mengren-relay"
ENV_FILE="/etc/mengren-relay.env"
CANARY="mengren-relay-v172-check"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="mengren-relay-backup-${STAMP}"
INSPECT_BACKUP="/root/mengren-relay-${STAMP}.inspect.json"

if [ "$(id -u)" -ne 0 ]; then
  echo "请使用 root 运行此脚本。" >&2
  exit 1
fi

if [ ! -f "relay_server/Dockerfile" ] || [ ! -d "packages/remote_protocol" ]; then
  echo "请在部署包根目录运行此脚本。" >&2
  exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "缺少 $ENV_FILE，已停止，未改动现有容器。" >&2
  exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "找不到现有容器 $CONTAINER，已停止，未改动现有服务。" >&2
  exit 1
fi

cleanup_canary() {
  docker rm -f "$CANARY" >/dev/null 2>&1 || true
}
trap cleanup_canary EXIT INT TERM

echo "[1/5] 记录现有容器配置（不会输出访问令牌）..."
docker inspect "$CONTAINER" >"$INSPECT_BACKUP"
OLD_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$CONTAINER")"
echo "现有镜像：$OLD_IMAGE"
echo "配置备份：$INSPECT_BACKUP"

echo "[2/5] 构建新镜像 $IMAGE ..."
docker build -f relay_server/Dockerfile -t "$IMAGE" .

echo "[3/5] 使用 127.0.0.1:18081 进行候选容器健康检查..."
cleanup_canary
docker run -d --name "$CANARY" \
  --env-file "$ENV_FILE" \
  -e MQT_RELAY_BIND=0.0.0.0 \
  -e MQT_RELAY_PORT=8080 \
  -e MQT_RELAY_DELIVERY_TIMEOUT_SECONDS=120 \
  -p 127.0.0.1:18081:8080 \
  "$IMAGE" >/dev/null

CANARY_OK=0
i=0
while [ "$i" -lt 20 ]; do
  if curl -fsS http://127.0.0.1:18081/healthz >/dev/null; then
    CANARY_OK=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$CANARY_OK" -ne 1 ]; then
  echo "候选容器健康检查失败，现有服务未改动。" >&2
  docker logs --tail 80 "$CANARY" >&2 || true
  exit 1
fi
cleanup_canary

echo "[4/5] 替换正式容器；旧容器保留为 $BACKUP ..."
docker stop "$CONTAINER" >/dev/null
docker rename "$CONTAINER" "$BACKUP"

rollback() {
  echo "新容器启动失败，正在自动恢复旧容器..." >&2
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker rename "$BACKUP" "$CONTAINER"
  docker start "$CONTAINER" >/dev/null
}

if ! docker run -d --name "$CONTAINER" \
  --restart unless-stopped \
  --env-file "$ENV_FILE" \
  -e MQT_RELAY_BIND=0.0.0.0 \
  -e MQT_RELAY_PORT=8080 \
  -e MQT_RELAY_DELIVERY_TIMEOUT_SECONDS=120 \
  -p 127.0.0.1:18080:8080 \
  "$IMAGE" >/dev/null; then
  rollback
  exit 1
fi

NEW_OK=0
i=0
while [ "$i" -lt 20 ]; do
  if curl -fsS http://127.0.0.1:18080/healthz >/dev/null; then
    NEW_OK=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$NEW_OK" -ne 1 ]; then
  docker logs --tail 80 "$CONTAINER" >&2 || true
  rollback
  exit 1
fi

echo "[5/5] 部署成功。"
docker ps --filter "name=^/${CONTAINER}$" \
  --format '容器={{.Names}}  镜像={{.Image}}  状态={{.Status}}  端口={{.Ports}}'
echo "旧容器已停止并保留：$BACKUP"
echo "如需回滚，请依据配置备份：$INSPECT_BACKUP"
