# 红泥（hongni）架构说明

轻量自托管云相册：单二进制 Go 服务端 + SQLite 索引 + 磁盘 blob 文件，Godot 客户端（Android 优先），参考 immich 但无 Docker、无外部数据库。

## 总体结构

```
hongni/
├── server/                  # Go 服务端（单二进制）
│   ├── main.go              # 装配 / 优雅关闭 / mDNS 注册
│   └── internal/
│       ├── config/          # 环境变量 + 令牌生成/持久化
│       ├── store/           # SQLite 迁移 + 数据访问 + sync_log
│       ├── blob/            # 内容寻址存储 + 缩略图
│       └── api/             # 路由 + Bearer 鉴权中间件 + handlers
├── plugin-android/          # 插件 Kotlin 源码 + gradle 工程（构建 AAR）
└── app/                     # Godot 4.7 客户端（竖屏）
    ├── project.godot        # 自动加载单例 + 竖屏配置
    ├── scenes/              # main / albums / album_view / viewer / settings / system_album
    ├── scripts/             # GDScript：Store/Api/Sync/Lock + 各场景脚本
    └── addons/hongni_plugin # Android 插件 AAR + 导出脚本
```

## 服务端

### 数据目录

`HONGNI_DATA_DIR`（默认 `./data`）：

```
data/
├── hongni.db      # SQLite 索引（WAL）
├── config.json    # 生成的共享 Bearer 令牌
├── blobs/<h0>/<h1>/<hash>   # 原始文件（内容寻址，无扩展名）
└── thumbs/<h0>/<h1>/<hash>.jpg  # 缩略图（最长边 512px）
```

### 存储模型（内容寻址 + 引用计数）

- **blobs**：`hash`（SHA-256 hex，主键）、`size`、`ref_count`。物理文件内容寻址、无扩展名。
- **assets**：一条上传记录 = 一个名字 + 一个 hash 引用。索引记录**原始扩展名**（`ext`，上传时从原始文件名提取、改名不影响），使内容寻址的 blob 即使在 `original_name` 被改掉后仍能还原真实文件类型。同名/不同名重复内容共享同一 blob。
- 去重语义：上传同内容文件 → `blobs` 行不变，新增 `assets` 行，`ref_count + 1`。
- 删除语义：删 `assets` → `ref_count - 1`；归零时同事务删除 `blobs` 行，并移除物理 blob + 缩略图。
- **albums**：树形（`parent_id` 自引用级联删除），`is_hidden`、`sync_mode`（`backup/two_way/mirror/local_only`）。
- **album_assets**：多对多成员关系，不产生新 asset。
- **sync_log**：增量变更日志（`entity`/`entity_id`/`op`/`seq`），供多设备同步游标。

### 配置与鉴权

- 环境变量：`HONGNI_DATA_DIR`、`HONGNI_ADDR`（默认 `:8354`）、`HONGNI_TOKEN`（可选）。
- 令牌为空时从 `config.json` 读；仍无则 `crypto/rand` 生成 32 字节 hex 持久化并打印一次。
- `/health` 无需鉴权；`/api/v1/*` 全部要求 `Authorization: Bearer <token>`，`crypto/subtle.ConstantTimeCompare` 比对。

### 依赖（纯 Go，无 CGO）

- `modernc.org/sqlite` — 纯 Go SQLite 驱动
- `golang.org/x/image` — WebP 解码 + 高质量缩放
- `github.com/grandcat/zeroconf` — mDNS `_hongni._tcp` 局域网发现

## 客户端

### 单例（autoload）

| 单例 | 职责 |
|---|---|
| `Store` | `user://settings.json`（服务器/令牌/PIN/游标/存储策略）与 `user://sync_index.json`（本地已上传映射）持久化 |
| `Api` | HTTP 客户端，返回 `Dictionary`（`error` 非空即失败）；多段上传、缩略图/原图拉取 |
| `Sync` | `run_backup`（本地删云端留）+ `run_sync`（two_way/mirror 拉取 + 冲突重命名） |
| `Lock` | 家长 PIN/指纹门禁，代理插件 MediaStore/PhotoPicker/mDNS 能力 |
| `Cache` | 离线缓存：云端相册快照、缩略图/原件缓存、LRU 空间清理 |

### 场景流

```
main.tscn ──未配置──▶ settings.tscn ──保存成功──▶ albums.tscn
                              ▲
                              └── 上传 / 新建相册 / 系统相册 / 顶部"更多 ⋮"菜单（最近删除/立即同步/设置）
albums.tscn ──顶部 相册 按钮 + ⋮ 菜单（隐私相册/最近删除/立即同步/设置）──▶ 相册 | 隐私（两个主干）
albums.tscn ──相册卡片（多列大图卡）──▶ album_view.tscn（收藏/全部/各子相册）
album_view.tscn ──点击照片/视频──▶ viewer.tscn（全屏原图、左右滑、删除、加入相册、存到设备相册；视频经外部播放器播放）
albums.tscn ──最近删除──▶ trash.tscn（恢复 / 永久删除 / 清空，主/隐私分离）
```

### 门禁规则

- 隐藏相册（`is_hidden=1`）不出现在主列表，解锁后可见。
- 进入设置、删除 asset、修改同步模式、查看隐藏相册内容均需解锁（家长 PIN 或指纹）。
- PIN：PBKDF2-HMAC-SHA256，100000 次迭代；无插件时用纯 GDScript 回退（与 Kotlin 实现逐字节一致）。

### 离线浏览与空间策略

- `Cache` 单例在 `user://cache` 维护三样东西：`catalog.json`（相册树 + 每相册成员 + 每资产最后查看时间）、`thumbs/<asset_id>.jpg`、`originals/<asset_id>.<ext>`。
- 在线浏览时相册列表/成员快照写入缓存，每个缩略图下载即写盘；查看器打开原图时先读本地原件缓存，未命中才联网下载并写缓存。
- 服务器不可达时主流程仍进入相册页：相册/网格/查看器全部回退到本地缓存（离线可浏览缩略图、看已缓存原图；未缓存原图仅显示缩略图并提示）。
- 空间策略：`settings.json` 的 `cache_clean_enabled`（默认开）与 `cache_min_free_mb`（默认 1024 = 1 GiB）。触发点：打开相册页、每次同步结束、每次缓存新原件。剩余空间低于阈值时按 `last_viewed` 从旧到新删除 `originals/` 下的原件（每个文件都来自云端下载，删除安全）；仍不足时再删除 `user://photos` 中已备份（`sync_index` 有记录且非墓碑）的原件，云端保留权威副本。缩略图与快照永不删除，未备份的本地文件永不删除。
- 网格/相册卡片缩略图采用**异步占位渲染**：先同步铺满占位、缩略图后台填充，不阻塞主循环；离线/弱联时未缓存缩略图不再发起网络等待（元数据请求用短超时），网格仍即时流畅。
- 照片 cell 右上角标：`↓` = 只存云（本地无原件，可下载）；`↑` = 仅本地待上传（`user://photos` 未同步，见「全部」视图）。标志只打在照片上，不用于相册卡片。
- 视频：服务端 `EnsureThumb` 不解码视频（无缩略图），网格 cell 用左上角 `▶` 标记；查看器对视频显示「播放」按钮，先下载原视频到 `user://cache/originals`（复用缓存），再交外部播放器（Android 经 FileProvider 共享为 content:// URI，桌面用默认播放器）。
- `Cache.enforce_cache()` 在内存空间查询失败（返回 0）时不动任何文件。

### 同步模式

统一双向同步,不再按相册区分。`Sync.run_sync()` 流程:

1. **上传**本地新增/变更到云端(去重:同 hash 复用 cloud asset)。
2. **墓碑**(离线删除):用户主动删除时,若云端不可达,本地删文件并把 `asset_id` 记入 `settings.pending_deletes`,联网后逐个 `DELETE /assets/{id}` 软删,成功即移除。
3. **拉取**云端变更(`sync_changes` 游标):`asset create` → 缓存缩略图(原图查看时按需下载);`asset delete` → 删本地源文件与缓存原件、保留缩略图。
4. **空间回收**:结束时 `Cache.enforce_cache()`。

本地模型:云端是唯一完整备份,本地是可精简的浏览端+上传源。

本地去重判定：`sync_index.json` 按 `local_id`（MediaStore ID 或 `user://` 相对路径）匹配，`mtime`+`size` 未变则跳过哈希。

## Android 插件（Kotlin，Godot v2 AAR）

单例 `HongniPlugin`，GDScript 按精确 snake_case 名调用（无 camelCase 强转）：

| 方法 | 能力 |
|---|---|
| `has_biometric` / `authenticate_biometric` | BiometricPrompt 指纹 |
| `hash_pin` / `verify_pin` / `random_salt` | PBKDF2 PIN 哈希 |
| `list_media` / `read_media_bytes` | MediaStore 扫描 / 读取 |
| `open_photo_picker` | ACTION_PICK_IMAGES |
| `schedule_backup` / `cancel_backup` / `consume_backup_pending` | WorkManager 周期备份 |
| `play_video` | 外部播放器（本地文件经 FileProvider 共享为 content:// URI） |
| `scan_lan` | NsdManager 发现 `_hongni._tcp` |

信号：`biometric_result` / `photo_picker_result` / `lan_scan_result` / `backup_pending`。

打包：v2 架构（`@UsedByGodot` + manifest `org.godotengine.plugin.v2.HongniPlugin`），经 `app/addons/hongni_plugin/export_plugin.gd` 注入 Gradle 导出。

## HTTP API 摘要

错误统一 `{"error":"<message>"}`。

- `GET /health` → `ok`
- `GET /api/v1/assets?filter=&album_id=&cursor=&limit=` → `{"assets":[...],"next_cursor":"..."}`
- `GET /api/v1/assets/{id}` → Asset JSON
- `GET /api/v1/assets/by-hash/{hash}` → 200 / 404
- `POST /api/v1/assets`（multipart）→ 201 + `deduplicated`/`thumb`
- `GET /api/v1/assets/{id}/original` / `.../thumb`
- `DELETE /api/v1/assets/{id}`（软删进回收站）、`PATCH /api/v1/assets/{id}`（改名 `original_name`）
- `GET /api/v1/trash?trunk_id=&cursor=&limit=`（回收站列表，主/隐私分离）、`POST /api/v1/trash/{id}/restore`（恢复，回原相册）
- `DELETE /api/v1/trash/{id}`（永久删除单个）、`DELETE /api/v1/trash?trunk_id=`（清空该 trunk 回收站）
- `GET/POST /api/v1/albums`、`PATCH/DELETE /api/v1/albums/{id}`
- `POST /api/v1/albums/{id}/assets`、`DELETE /api/v1/albums/{id}/assets/{asset_id}`
- `GET /api/v1/sync/changes?cursor={seq}`
- 回收站保留 7 天，列表/恢复/清空时惰性永久删除过期项。

## 运行与验证

```bash
cd server && go run .          # 打印 HONGNI_TOKEN 一次
# 客户端：Godot 4.7 打开 app/，填 server_url + token
# Android 导出：项目设置启用 use_gradle_build，开启 hongni_plugin 插件
```
