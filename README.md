# hongni
绿蚁新醅酒，红泥小火炉。晚来天欲雪，能饮一杯无？

家庭轻量自托管云相册：
server:	Go服务端 + SQLite，重复文件去重存储；每台设备用「身份 ID + PIN」登录，共享相册全家可见，隐私相册按身份隔离
app:	Godot客户端, 主分三大相册：系统相册(本机相册)、共享相册(全家共享)、隐私相册（按身份隔离）（Android可内置播放）

架构与实现细节见 [ARCHITECTURE.md](./ARCHITECTURE.md)。

## 运行服务端

```bash
cd server
go run .                  # 默认：./data + :8354，首次生成并打印 HONGNI_TOKEN 一次
go build -o server.exe .  # 常驻用二进制；改过 server/ 下的代码就必须重编，否则跑的还是旧路由
server.exe -h             # 查看用法
```

参数优先于环境变量，环境变量优先于默认值：

| 参数 | 默认 | 环境变量 |
|---|---|---|
| `-data <目录>` | `./data` | `HONGNI_DATA_DIR` |
| `-port <端口>` | `8354` | `HONGNI_ADDR`（`host:port`；主机名会被 `-port` 保留） |
| `-journal WAL\|DELETE\|TRUNCATE` | `WAL` | — |
| — | — | `HONGNI_TOKEN`（不给则读 `<data>/config.json`，仍无则生成并打印一次） |

`-data` 的相对路径按**进程工作目录**解析，所以从别处启动时写绝对路径。

### 各种模式

| 场景 | 命令 |
|---|---|
| 默认（本地盘） | `server.exe` |
| 换数据目录与端口 | `server.exe -data D:\hongni-data -port 9000` |
| 数据目录在 SMB/NAS 共享 | `server.exe -data \\nas\photos\hongni -journal TRUNCATE` |
| 同上，另一种回滚日志 | `server.exe -data \\nas\photos\hongni -journal DELETE` |
| NAS 给的是 iSCSI/块设备，或本地盘 | `server.exe -data I:\hongni-data`（保持默认 `WAL`） |
| 同机跑第二个实例（测试/独立库） | `server.exe -data D:\hongni-test -port 9001` |
| 环境变量（cmd；`set` 要带引号，否则值会吃进尾随空格） | `set "HONGNI_DATA_DIR=D:\hongni-data"`<br>`set "HONGNI_ADDR=:9000"`<br>`server.exe` |
| 环境变量（PowerShell） | `$env:HONGNI_DATA_DIR="D:\hongni-data"; $env:HONGNI_ADDR=":9000"; .\server.exe` |
| 固定令牌（容器/换机器后仍认同一批客户端） | `set "HONGNI_TOKEN=<32位hex>" && server.exe`（给了就不写 `config.json`） |

`HONGNI_ADDR` 里给主机名就只监听该网卡：`set "HONGNI_ADDR=127.0.0.1:8354" && server.exe -port 9000` → 监听 `127.0.0.1:9000`。

网络盘（SMB/NAS）注意：`WAL` 只适合本地盘，共享目录上必须换 `TRUNCATE`/`DELETE`（启动时对 `\\` 路径 + `WAL` 会打警告）；同一目录同一时间**只能有一台机器**跑服务端；目录在 NAS 上不等于有备份。细节见 [ARCHITECTURE.md](./ARCHITECTURE.md) 的「数据目录放在网络盘」。

客户端在设置页给每个结点填 名称 / 地址（`http://<主机>:<端口>`）/ 令牌 / 身份 ID / PIN。
