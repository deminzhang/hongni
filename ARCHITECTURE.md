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
└── app/                     # Godot 4.7 客户端（竖屏）
    ├── project.godot        # 自动加载单例 + 竖屏配置
    ├── plugin-android/      # 插件 Kotlin 源码 + gradle 工程（构建 AAR）
    ├── scenes/              # main / albums / album_view / viewer / settings / trash
    ├── scripts/             # GDScript：Store/Api/Sync/Lock/Cache/DeviceMedia + 场景脚本 + media_probe（容器元数据解析）/ asset_menu（资材操作菜单）/ details_sheet（详细面板）
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
- **albums**：树形（`parent_id` 自引用级联删除），`is_hidden`、`sync_mode`（`backup/two_way/mirror/local_only`）。**相册封面不进服务端**：由客户端按设备记在 `settings.json` 的 `album_covers`（相册 id → asset id），换设备/清数据后回到「相册最新一张」。
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
| `Store` | `user://settings.json`（服务器结点列表/PIN/游标/存储策略/相册封面 `album_covers`）与 `user://sync_index.json`（本地已上传映射）持久化 |
| `Api` | HTTP 客户端，返回 `Dictionary`（`error` 非空即失败）；请求按结点优先级失败切换；多段上传、缩略图/原图拉取 |
| `Sync` | `run_backup`（本地删云端留）+ `run_sync`（two_way/mirror 拉取 + 冲突重命名） |
| `Lock` | 家长 PIN/指纹门禁，代理插件 MediaStore/PhotoPicker/mDNS 能力 |
| `Cache` | 离线缓存：云端相册快照、缩略图/原件缓存、LRU 空间清理 |
| `DeviceMedia` | 系统相册数据源：MediaStore（Android）/ Pictures 目录（桌面）扫描、按相册分组、缩略图生产与缓存、上传暂存与播放取文件 |

### 服务器结点（多结点与优先级）

`settings.json` 的 `servers` 是结点数组，**数组顺序即优先级**，每项 `{name, url, token}`。旧版单服务器字段 `server_url`/`token` 在首次加载时迁移为唯一结点（名称默认取地址的 host:port）后删除。

- 请求路由（`Api._do_request`）：先试上次成功的结点，再按优先级依次试其余结点；只有**连不上**（地址非法/DNS/超时）才切下一个，任一结点给出 HTTP 响应（含 401/404）即视为该结点生效并记住它。稳态无额外开销；结点掉线只在切换那一刻付一次超时。
- 设置页「服务器」区每行一个结点：**连通性圆点**（灰=未知/检测中、绿=可达、红=不可达；进页面与「检测连接」时并发探测 `/health`）+ **名称** + **▲/▼**（调顺序即调优先级）+ **设置**。
- 「设置」打开子 UI：名称、地址（旁有「扫描局域网」填入）、令牌、**连接测试**（`GET /assets?limit=1`，区分「连不上」与「令牌无效」401）、**删除**，以及取消/保存；新建结点不显示删除；测试用输入框里的未保存值，结果同时回填该行圆点。
- `Api.probe_all` 并发发出全部 `/health` 请求，结果由各自回调收集——**不能逐个 `await request_completed`**：该信号只触发一次，快结点会在等待慢结点期间就绪而被永久错过。

### 场景流

```
main.tscn ──无可用结点──▶ settings.tscn ──结点连得上──▶ albums.tscn
albums.tscn ──顶部三个并列 tab:红泥相册 | 系统相册 | 红泥隐私相册──▶ 三套相册平级切换
albums.tscn ──相册卡片（多列大图卡）──▶ album_view.tscn
   红泥相册 = 收藏 / 全部 / 视频 / 各子相册（云端）   系统相册 = 全部 / 视频 / 各本机相册
   红泥隐私相册 = 隐藏相册（PIN/指纹门禁，结构与红泥相册一致）
album_view.tscn ──点击照片/视频──▶ viewer.tscn（全屏原图、左右滑；点按切换周边 UI；视频默认不播，点按才播，Android 走应用内播放 + 预览帧进度条、否则外部播放器）
album_view.tscn ──长按或底部「选择」──▶ 多选模式（每格右上勾选框）──▶ 底部 ⋮ 菜单批量执行
   云端资材：收藏 / 移动到 / 复制到 / 删除 / 设为相册封面（单张图片）    本机资材：上传到红泥
viewer.tscn ──底部 ⋮ 菜单──▶ 收藏/移动到/复制到/设为相册封面/重命名/删除/详细（作用于当前这张；本机资材为 上传到红泥/详细）
albums.tscn ──⋮ 菜单（最近删除/立即同步/设置）──▶ trash.tscn（恢复 / 永久删除 / 清空，主/隐私分离）
album_view/viewer/trash/settings ──返回──▶ albums.tscn（回到本会话最后所在的主干 `Api.current_trunk`：从系统相册的本机相册返回仍停在 系统相册，隐私主干仅在会话已解锁时恢复）
```

### 三套并列的相册

- **红泥相册**（云端主干 `相册`）与 **红泥隐私相册**（云端主干 `隐私`，`is_hidden`）都是云端数据；隐私主干由顶部 tab 进入，需先解锁（PIN 或指纹）。
- **系统相册**是本机的相册，数据直读设备：Android 走 MediaStore（插件 `list_media` 返回 `bucket_id`/`bucket_name`，据此分组出各本机相册），桌面/编辑器走 `%USERPROFILE%\Pictures`（一级子目录即一个相册，根目录文件归入「图片」）。该主干完全不依赖服务器，离线可用。
- 三个主干共用同一套界面：相册卡片网格（`albums.tscn`）与照片网格（`album_view.tscn`）+ 查看器 + 多选 + 底部 ⋮ 菜单。本机相册卡片只有「点击进入」（设备自己的相册，无改名/删除），云端卡片长按仍是相册菜单。
- **虚相册**（没有对应的服务端相册行，只是同一批资材的另一种看法）：
  - **全部**＝主干自身（服务端聚合其全部后代相册的成员）。
  - **视频**＝「全部」再按媒体类型过滤（`GET /assets?filter=videos&album_id=<主干>`），主干里一张视频都没有时不显示这张卡片；本机主干走 `DeviceMedia.bucket_items(VIDEO_BUCKET)`（`is_video` 过滤），同样为空时不显示。点开后 `Api.current_filter = "videos"`，网格/查看器/多选/⋮ 菜单与「全部」完全一致（移动时同样按「脱离散照」处理）；本地待上传文件也只并入视频。
  - 离线缓存按「相册 id + filter」分别存（`Cache.offline_assets(id, filter)`；filter 为 `all` 时沿用旧的裸 id 键），所以 VIDEO 视图不会覆盖「全部」的快照。
- 系统主干的资材是**设备自己的文件**（Android 为 `content://` URI，桌面为绝对路径）：网格缩略图由 `DeviceMedia` 生成并缓存到 `user://system_thumbs`（Android 经插件 `load_thumbnail` 在调用线程解码，按帧限流；桌面由后台线程解码）；查看器用插件 `load_media_preview`（保比例、不裁剪）或桌面直接解码；视频仍走应用内/外部播放（点 ▶ 后 Android 才把 `content://` 落到 `user://cache/device` 再交给 MediaPlayer）。
- 设备文件不受删除/改名/移动等云端操作影响，唯一动作是 **⋮ 菜单 → 上传到红泥**：把选中项暂存到隐藏目录 `user://import_tmp`，`Api.upload_asset` 上传进云端主干的 `散照` bucket（即「全部」聚合到的位置），随后删除暂存副本。`Api.resolve_scatter_album()` 负责定位该 bucket（离线时提示无法上传）。

### 底部操作行与资材菜单

- `album_view`（照片网格）与 `viewer`（全屏）底部各有一行操作按钮，**最右侧固定为 ⋮ 菜单**（`asset_menu.gd`，两个界面共用）：收藏 / 移动到 / 复制到 / 设为相册封面 / 重命名 / 删除 / 详细。网格里这组操作原先是**长按弹出**；现在长按改为**切换进多选模式**（每格右上角出现勾选框，`↓` 云角标让位隐藏），⋮ 菜单于是按「当前选中项」批量执行，未选中时回退到最近点过的那一张。viewer 的删除/存到相册按钮移到同一行，原本的「加入相册（输入相册 ID）」由菜单里的 移动到/复制到（相册选择器）取代。
- 目标是**系统相册**的本机资材时，菜单换成 **上传到红泥 / 详细**（云端专属项一律不出现），viewer 同时隐藏「删除」与「存到相册」——设备文件归设备所有，本应用只负责把它送进云端。
- 菜单项 **设为相册封面** 只对**单张云端图片**开放（视频服务端不解码、没有缩略图；多选没有唯一封面；尚未上传的本地图片没有云端记录），视频/多选/本地图片一律置灰。封面**只记在本机** `settings.json` 的 `album_covers`（相册 id → asset id），服务端不存、相册成员关系不动，所以也不依赖联网：相册卡片缩略图优先用该封面，封面照片取不到缩略图（离线未缓存、已删除）时退回相册最新一张。
- 移动到 / 复制到 / 设为相册封面 **共用同一个相册选择器**（`AcceptDialog` + 下拉框）：只列当前主干的子相册并排除 收藏（移动到/复制到 再排除正在浏览的那个相册）。下拉框宽度按最长相册名自适应、下限 **7 个汉字**，长相册名不再被截断。
- 菜单项 **详细** 从屏幕底部弹出一个文本显示区（`details_sheet.gd`，占视口下方约 42%），列出该资材的：名称、哈希、时间、大小、宽高、时长（视频才有）、路径；多选时「重命名/详细」置灰。
- 取值来源：服务端资材记录优先（`hash`/`size`/图片 `width`/`height`/`taken_at`→`created_at`）；服务端不掌握的（视频时长与分辨率、本地路径、尚未上传的本地照片的哈希）由 `media_probe.gd` 直接读本地文件——MP4/MOV 走 ISO BMFF box（`mvhd` 时长、`tkhd` 像素尺寸），MKV/WebM 走 EBML（`Info.Duration`/`TimecodeScale`、`Video.PixelWidth/Height`）；无本地副本时显示云端 URL，「时间/大小」回退到本地文件 mtime/长度，本地照片的 SHA-256 在后台线程计算。

### 门禁规则

- 隐藏相册（`is_hidden=1`）不出现在主列表，解锁后可见。
- **家长 PIN/指纹只守红泥隐私相册的入口**：顶部 tab 切到隐私主干（`albums.gd::_on_trunk`）与打开隐私主干的 最近删除（`trash.gd`）两处校验，且同一会话解锁一次即通行。其余操作一律不校验：删除照片（网格与 viewer 共用的 `asset_menu.delete_assets`）、删除相册、打开设置都直接执行。
- 设置页**更换已设的 PIN 必须先输入旧 PIN**（`Lock.require_current_pin`，不受“本会话已解锁”影响；未设 PIN 时直接设置）。入口既然不再拦截，这就是防止有人进设置把锁换掉的唯一一道校验。
- PIN：PBKDF2-HMAC-SHA256，100000 次迭代；无插件时用纯 GDScript 回退（与 Kotlin 实现逐字节一致）。

### 离线浏览与空间策略

- `Cache` 单例在 `user://cache` 维护三样东西：`catalog.json`（相册树 + 每相册成员 + 每资产最后查看时间）、`thumbs/<asset_id>.jpg`、`originals/<asset_id>.<ext>`。
- 在线浏览时相册列表/成员快照写入缓存，每个缩略图下载即写盘；查看器打开原图时先读本地原件缓存，未命中才联网下载并写缓存。
- 服务器不可达时主流程仍进入相册页：相册/网格/查看器全部回退到本地缓存（离线可浏览缩略图、看已缓存原图；未缓存原图仅显示缩略图并提示）。
- 空间策略：`settings.json` 的 `cache_clean_enabled`（默认开）与 `cache_min_free_mb`（默认 1024 = 1 GiB）。触发点：打开相册页、每次同步结束、每次缓存新原件。剩余空间低于阈值时按 `last_viewed` 从旧到新删除 `originals/` 下的原件（每个文件都来自云端下载，删除安全）；仍不足时再删除 `user://photos` 中已备份（`sync_index` 有记录且非墓碑）的原件，云端保留权威副本。缩略图与快照永不删除，未备份的本地文件永不删除。
- 网格/相册卡片缩略图采用**异步占位渲染**：先同步铺满占位、缩略图后台填充，不阻塞主循环；离线/弱联时未缓存缩略图不再发起网络等待（元数据请求用短超时），网格仍即时流畅。
- 照片 cell 右上角标：`↓` = 只存云（本地无原件，可下载）；`↑` = 仅本地待上传（`user://photos` 未同步，见「全部」视图）。标志只打在照片上，不用于相册卡片。多选模式下该角改为勾选框，`↓` 角标隐藏。
- 视频：服务端 `EnsureThumb` 不解码视频（无缩略图），网格 cell 用**居中 `▶`** 标记。抽帧全在前端：`_load_cell_thumb` 先确保**本地副本**（缺则 `Api.fetch_original` 整段下载进 `user://cache/originals`，与查看器缓存复用），再经插件 `extract_video_thumb` 对**本地文件**抽帧，`poll_video_thumb_finished` 回填 cell。
- 查看器里的视频**不自动播放、打开时也不下载**：先显示缓存的海报（无海报则只有 ▶），点 ▶ 或点画面才开始取本地副本（云端下到 `user://cache/originals`，本机相册先落到 `user://cache/device`）并启动**应用内播放**。插件用 MediaPlayer（`AudioAttributes` + 1×1 屏幕内 TextureView 保持合成以排空 SurfaceTexture）解码，`prepareAsync()` 完成后停在第 1 帧并发 `inapp_video_prepared`，GDScript 才 `resume_inapp_video()` —— 即"点了才播"；`grab_inapp_frame()` 把帧统一缩放到目标尺寸后回读渲染到 TextureRect。
- 视频操作 UI（`viewer.gd`，状态机见下）：画面下方是 `播放至时间|总时间`（分:秒）+ **预览帧进度条** —— 插件 `request_video_filmstrip()` 在后台把整段均匀抽 `count` 帧、居中裁剪后拼成一张 RGBA 长图，GDScript 铺满屏宽，白线播放头 + 右侧压暗表示进度；在条上按下即跟手预览、松手 `seek_inapp_video()` 落位。进度条正中是 ▶/❚❚ 按钮（播放中显示为暂停）。
- 点按语义：图片点一下隐藏/再点一下显示周边 UI（顶栏、名称、状态、底部操作行）；视频未播放时点按 = 播放/续播，**播放中**点按 = 隐藏周边 UI（含进度条与暂停按钮）全屏播放，再点恢复。
- 异常退化：画面卡住（`inapp_frame_age_ms()` 超时）或播放器报错（`inapp_video_closed` 只表示错误，放完是 `inapp_video_completed`）时，自动退化为**外部播放器**（Android 经 FileProvider 共享为 content:// URI，桌面用默认播放器）；桌面/编辑器没有插件，点 ▶ 直接交给系统播放器。
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
| `list_media` / `read_media_bytes` | MediaStore 扫描 / 读取；每项含 `bucket_id`/`bucket_name`（本机相册分组）、`width`/`height`、视频 `duration_ms` |
| `load_thumbnail` / `load_media_preview` | 生成居中裁剪方图缩略图 / 保比例的预览图（最长边 ≤ maxPx，不裁剪，供查看器） |
| `open_photo_picker` | ACTION_PICK_IMAGES |
| `schedule_backup` / `cancel_backup` / `consume_backup_pending` | WorkManager 周期备份 |
| `play_video` | 外部播放器（本地文件经 FileProvider 共享为 content:// URI） |
| `start_inapp_video` / `pause_inapp_video` / `resume_inapp_video` / `stop_inapp_video` / `grab_inapp_frame` / `is_inapp_video_playing` / `inapp_frame_age_ms` | 应用内播放：MediaPlayer 解码到 1×1 屏幕内 TextureView，帧回读；`prepareAsync()` 完成后**停在第 1 帧并 `emitSignal("inapp_video_prepared")`**（不自动播），`inapp_frame_age_ms` 供 GDScript 检测画面卡死 |
| `inapp_video_prepared` / `inapp_video_completed` / `inapp_video_position_ms` / `inapp_video_duration_ms` / `seek_inapp_video` | 播放状态与定位：是否就绪、是否播完（播完不发 `inapp_video_closed`）、当前位置/总时长（ms，未知为 -1）、定位（API 26+ 用 `SEEK_CLOSEST` 精确到帧） |
| `request_video_filmstrip` / `take_video_filmstrip` | 后台线程把整段均匀抽 `count` 帧、居中裁剪后横向拼成一张 RGBA 长图（进度条底图）；`token` 保证只收最新一次请求的结果 |
| `extract_video_thumb` / `poll_video_thumb_finished` | 后台线程抽视频帧为缩略图，结果入队由 GDScript 排空 |
| `scan_lan` | NsdManager 发现 `_hongni._tcp` |

信号：`biometric_result` / `photo_picker_result` / `lan_scan_result` / `backup_pending` / `inapp_video_prepared` / `inapp_video_closed`（**仅报错**；正常播完由 `inapp_video_completed` 轮询得知）。

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
# 客户端：Godot 4.7 打开 app/，在设置里添加服务器结点（名称/地址/令牌，可多个、可排序）
# Android 导出：项目设置启用 use_gradle_build，开启 hongni_plugin 插件
```
