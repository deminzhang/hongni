# hongni
绿蚁新醅酒，红泥小火炉。晚来天欲雪，能饮一杯无？

轻量自托管云相册：
server:	Go服务端 + SQLite，重复文件去重存储；每台设备用「身份 ID + PIN」登录，共享相册全家可见，隐私相册按身份隔离
app:	Godot客户端, 主分三大相册：系统相册、共享相册、隐私相册（按身份隔离）（Android可内置播放, PC用本地图库及播放器）

架构与实现细节见 [ARCHITECTURE.md](./ARCHITECTURE.md)。
