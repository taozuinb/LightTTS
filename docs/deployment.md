# 部署指南

## 部署模式

### 1. 开发环境部署

适用于开发测试和快速原型验证。

```bash
# 基础启动
python -m light_tts.server.api_server \
  --model_dir ./pretrained_models/CosyVoice2-0.5B-latest \
  --host localhost \
  --port 8080 \
  --load_trt True
```

**特点**:
- 单进程部署
- 默认参数配置
- 适合调试和开发

### 2. 生产环境部署

#### Gunicorn 多Worker部署

```bash
# 使用预设配置（推荐）
python wsgi_wrapper.py

# 或手动启动
gunicorn -w 3 \
    -k uvicorn.workers.UvicornWorker \
    -b 0.0.0.0:8080 \
    --timeout 300 \
    wsgi_wrapper:app
```

**配置优化**:
```python
# wsgi_wrapper.py 中的配置
CONFIG = {
    "model_dir": "./pretrained_models/CosyVoice2-0.5B-latest",
    "load_trt": True,
    "max_total_token_num": 131072,  # 增加token容量
    "max_req_total_len": 32768,
    "host": "0.0.0.0",
    "port": 8080,
    "httpserver_workers": 3,        # Gunicorn workers数量
    "encode_process_num": 2,        # Encode进程数
    "decode_process_num": 2,        # Decode进程数
    "gpt_paral_num": 100,           # LLM并行度
    "decode_paral_num": 2,          # Decode并行度
    "decode_max_batch_size": 4,     # Decode batch大小
}
```

### 3. Docker 容器化部署

#### 使用现有 Python 环境构建

在已有 `/usr/local/tts/.venv` 的 Linux x86_64 服务器上执行。需要 Docker Buildx，运行容器的服务器还需要 NVIDIA Container Toolkit。

```bash
git submodule update --init --recursive
bash build-image.sh
```

构建会将虚拟环境原样复制到镜像的 `/usr/local/tts/.venv`。对于 uv 等工具安装到独立目录的 Python，脚本也会复制其基础解释器并保留路径。脚本默认使用 NVIDIA NGC 的 `nvcr.io/nvidia/cuda:12.1.0-cudnn8-devel-ubuntu22.04` 基础镜像，并将构建产物加载到本地 Docker，标记为 `ccr.ccs.tencentyun.com/gz_asr/light-tts:local`。可用 `BASE_IMAGE` 覆盖基础镜像，或传入镜像名覆盖默认标签。

将宿主机的模型目录挂载到容器中。目录内应包含 `CosyVoice2-0.5B-finetune-v1`，如果虚拟环境安装了 `ttsfrd`，还需要 `CosyVoice-ttsfrd/resource`。模型挂载保留写权限，供首次启动生成 TensorRT 引擎。

```bash
docker run -d --name light-tts --gpus all --shm-size 4g \
    -p 8080:8080 \
    -v /path/to/pretrained_models:/usr/local/tts/LightTTS/pretrained_models \
    ccr.ccs.tencentyun.com/gz_asr/light-tts:local
```

可在镜像名后传入 `--model_dir` 和其他服务参数。容器就绪后可用 `curl -f http://localhost:8080/readiness` 检查。

#### 在镜像内下载 Python 依赖

```bash
git submodule update --init --recursive
bash build-image-download.sh
```

脚本用基础镜像内的系统 Python 3.10 创建 `/usr/local/tts/.venv`，从包源安装 LightTTS 依赖，默认使用 `ccr.ccs.tencentyun.com/gz_asr/light-tts:local` 标签。对比体积时可传入另一个标签，例如 `bash build-image-download.sh light-tts:download-test`。启动方式和模型挂载路径与上文相同。该构建使用 WeTextProcessing 做文本归一化。

#### 构建镜像
```bash
docker build -t light-tts:v1.0 .
```

#### 运行容器
```bash
# GPU支持
docker run -it --gpus all \
    -p 8080:8080 \
    --shm-size 4g \
    -v $(pwd)/models:/data/models \
    light-tts:v1.0

# 后台运行
docker run -d --gpus all \
    -p 8080:8080 \
    --shm-size 4g \
    --name light-tts-server \
    light-tts:v1.0
```

#### Docker Compose
```yaml
version: '3.8'
services:
  light-tts:
    build: .
    ports:
      - "8080:8080"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    volumes:
      - ./models:/app/models
      - ./logs:/app/logs
    environment:
      - CUDA_VISIBLE_DEVICES=0
      - MODEL_DIR=/app/models/CosyVoice2-0.5B-latest
    shm_size: 4g
```

### 4. Kubernetes 部署

#### 部署清单
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: light-tts
spec:
  replicas: 1
  selector:
    matchLabels:
      app: light-tts
  template:
    metadata:
      labels:
        app: light-tts
    spec:
      containers:
      - name: light-tts
        image: light-tts:v1.0
        ports:
        - containerPort: 8080
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 24Gi
          requests:
            nvidia.com/gpu: 1
            memory: 16Gi
        env:
        - name: MODEL_DIR
          value: "/models/CosyVoice2-0.5B-latest"
        volumeMounts:
        - name: model-volume
          mountPath: /models
        - name: shm-volume
          mountPath: /dev/shm
      volumes:
      - name: model-volume
        persistentVolumeClaim:
          claimName: model-pvc
      - name: shm-volume
        emptyDir:
          medium: Memory
---
apiVersion: v1
kind: Service
metadata:
  name: light-tts-service
spec:
  selector:
    app: light-tts
  ports:
  - port: 80
    targetPort: 8080
  type: LoadBalancer
```

### 5. 负载均衡部署

#### Nginx 负载均衡
```nginx
upstream tts_servers {
    server 127.0.0.1:8080 weight=1;
    server 127.0.0.1:8081 weight=1;
    server 127.0.0.1:8082 weight=1;
}

server {
    listen 80;

    location / {
        proxy_pass http://tts_servers;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        # WebSocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # 健康检查
    location /healthz {
        proxy_pass http://tts_servers/healthz;
        access_log off;
    }
}
```

#### 多实例启动脚本
```bash
#!/bin/bash
# start_cluster.sh

INSTANCES=3
BASE_PORT=8080
MODEL_DIR="./pretrained_models/CosyVoice2-0.5B-latest"

for i in $(seq 1 $INSTANCES); do
    PORT=$((BASE_PORT + i - 1))

    CUDA_VISIBLE_DEVICES=$((i - 1)) \
    python -m light_tts.server.api_server \
        --model_dir $MODEL_DIR \
        --port $PORT \
        --load_trt True \
        --max_total_token_num 65536 \
        > logs/tts_server_$PORT.log 2>&1 &

    echo "Started TTS server on port $PORT (PID: $!)"
done

echo "All $INSTANCES instances started"
```

## 监控和日志

### 1. 健康检查

```bash
# 基础健康检查
curl http://localhost:8080/healthz

# 详细状态
curl http://localhost:8080/health
```

### 2. 指标监控

```bash
# Prometheus指标
curl http://localhost:8080/metrics
```

关键指标:
- `lightllm_request_count`: 请求总数
- `lightllm_request_failure`: 失败请求数
- `lightllm_request_success`: 成功请求数
- `lightllm_request_latency`: 请求延迟

### 3. 日志配置

```python
# 生产环境日志配置
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/light-tts/app.log'),
        logging.StreamHandler()
    ]
)
```

## 性能调优

### 1. GPU利用率优化

```python
CONFIG = {
    "decode_process_num": 2,      # 增加decode进程
    "decode_paral_num": 2,        # 增加decode并行
    "decode_max_batch_size": 4,   # 增加batch size
    "gpt_paral_num": 100,         # GPT并行度
}
```

### 2. 内存优化

```python
CONFIG = {
    "max_total_token_num": 131072,    # 根据GPU内存调整
    "max_req_total_len": 32768,       # 单请求限制
    "cache_capacity": 100,            # LRU缓存容量
}
```

### 3. 网络优化

```python
# 启用HTTP/2和keep-alive
CONFIG = {
    "workers": 3,
    "worker_class": "uvicorn.workers.UvicornWorker",
    "worker_connections": 1000,
    "max_requests": 10000,
    "max_requests_jitter": 1000,
    "preload_app": False,  # 避免CUDA fork问题
}
```

## 故障排除

### 常见问题

1. **CUDA内存不足**
   ```bash
   # 解决方案：减少进程数或batch大小
   "decode_process_num": 1,
   "decode_max_batch_size": 2,
   ```

2. **请求超时**
   ```bash
   # 解决方案：增加超时时间
   gunicorn --timeout 600 ...
   ```

3. **模型加载失败**
   ```bash
   # 检查模型路径和权限
   ls -la ./pretrained_models/
   ```

### 调试模式

```bash
# 启用详细日志
export LIGHT_TTS_LOG_LEVEL=DEBUG

# 单步调试
python -m pdb light_tts/server/api_server.py
```

## 安全考虑

### 1. 网络安全

```bash
# 绑定特定IP
--host 127.0.0.1  # 仅本地访问
--host 10.0.0.100 # 内网访问

# 使用反向代理
# 建议使用Nginx/HAProxy作为前端代理
```

### 2. 访问控制

```python
# API限流
from slowapi import Limiter
from slowapi.util import get_remote_address

limiter = Limiter(key_func=get_remote_address)

@app.post("/inference_zero_shot")
@limiter.limit("10/minute")
async def inference_zero_shot(...):
    pass
```

### 3. 输入验证

```python
# 文件大小限制
MAX_FILE_SIZE = 50 * 1024 * 1024  # 50MB

# 文本长度限制
MAX_TEXT_LENGTH = 1000

# 支持的音频格式
ALLOWED_AUDIO_FORMATS = ['wav', 'mp3', 'flac']
```
