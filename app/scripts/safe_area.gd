extends RefCounted
## 真机（Android）的屏幕安全区：应用是全屏（沉浸式）的，画面铺满整屏，于是刘海 /
## 挖孔与屏幕左右上角的圆角都压在顶栏上——顶栏两端正好落在圆角里被切掉。这里把
## 系统报的安全区高度留出来，根容器整体下移，内容就落到了圆角以下。
##
## 参考 lingwang 的 `Scenes/UI/ui_main.gd::_apply_safe_area`（那里是 NotchBar 垫高
## 加 `SafeAreaContent.offset_top = top`），两处不同：
##   - 系统报的是**物理像素**，而布局用的是画布单位（600 宽的基准视口，见
##     ARCHITECTURE「界面缩放」），所以要先按 `DeviceMedia.display_scale()` 折算，
##     否则 1200 万像素的手机上会多留一倍（lingwang 那边是直接 clamp 到 36 兜住的）。
##   - 桌面（编辑器 / 本地跑）不留：窗口的边和屏幕的边不是一回事，`get_display_safe_area`
##     在桌面上给的是**屏幕**可用区（任务栏那块），拿来当窗口偏移会莫名其妙。
##
## 用法：建完铺满全屏的根容器后 `SAFE_AREA.apply(root)`。

## 屏幕上没有挖孔（只有圆角）时 Android 报的安全区是 0，圆角照样切顶栏两端，所以
## 真机至少留这一条。取 36 与 lingwang 的上限同一个数：600 宽的画布上是 6%，在
## 华为 P50（1224 宽）上是 73 物理像素 ≈ 25dp，够躲开圆角半径与状态栏。
const MIN_TOP := 36.0


## 顶栏要让开的高度（画布单位），0 = 不用让。
static func top_inset() -> float:
	var mobile := OS.get_name() == "Android"
	var safe_top := 0.0
	if mobile:
		safe_top = float(DisplayServer.get_display_safe_area().position.y)
	return band(safe_top, DeviceMedia.display_scale(), mobile)


## 安全区高度（物理像素）折成画布单位。拆出来是为了数值得以离开真机验证。
static func band(safe_top_px: float, scale: float, mobile: bool) -> float:
	if not mobile or scale <= 0.0:
		return 0.0
	return maxf(MIN_TOP, safe_top_px / scale)


## 把一个铺满全屏的根容器压到安全区以下（它得是上边锚在 0 的 Control：偏移加在
## 上锚点上，下边跟着锚点走，底部的操作行不会被顶出屏幕）。
static func apply(root: Control) -> void:
	_snap(root)
	# Android 的窗口 inset 是首次布局之后才派发的，而场景的 _ready 可能赶在它前面
	# （那一帧只量到 MIN_TOP，高刘海的机器会留不够），所以下一帧再量一次。之后
	# 只有分屏 / 改窗口大小会让缩放比变，交给 resized（同一个值时不会再触发）。
	_snap.call_deferred(root)
	root.resized.connect(_snap.bind(root))


static func _snap(root: Control) -> void:
	if is_instance_valid(root):
		root.offset_top = top_inset()
