# KC Mapper (KC761 Mapper)

中文 / English

一个用于 KC761 辐射仪的 Android 地图记录 App：通过 BLE 连接设备，采集 CPS 与剂量率，结合手机 GPS 在地图上绘制辐射轨迹，并支持历史查看与 CSV 导出。
An Android mapping app for KC761 radiation meters: connects via BLE, collects CPS and dose rate, combines GPS to draw radiation tracks on a map, and supports history view and CSV export.

## 版本 / Release Info
- 版本号: v0.0.2
- Version: v0.0.2
- APK 大小: 53062 KB
- APK Size: 53062 KB

## 功能亮点 / Highlights
- 实时 BLE 辐射数据与 OSM 地图叠加。
  Real-time BLE radiation data on an OSM map.
- 辐射点颜色映射，支持历史轨迹回放。
  Color-mapped radiation points with history playback.
- 一键 CSV 导出（系统文件选择器）。
  One-tap CSV export via system file picker.
- 传感器感知 UI（γ / n / PIN 可用时显示）。
  Sensor-aware UI (γ / n / PIN when available).
- 数据仅本机保存，无云同步。
  Local-only storage, no cloud sync.

## 功能 / Features
- BLE 扫描并连接 KC761 设备
  Scan and connect to KC761 devices via BLE
- 实时显示 CPS 与剂量率（μSv/h）
  Live CPS and dose rate (μSv/h)
- GPS 轨迹记录并在地图上绘制点
  GPS track recording with map points
- 历史轨迹查看、隐藏/显示、左滑删除
  View/hide history tracks, swipe to delete
- CSV 导出（系统文件选择器）
  CSV export via system file picker
- OSM Standard 地图瓦片缓存（可清除）
  OSM Standard tile caching (clearable)

## 设备与传感器 / Devices & Sensors
- 传感器：γ / n / PIN（按设备能力自动启用/禁用）
  Sensors: γ / n / PIN (auto enabled/disabled by device capability)

## 权限 / Permissions
- 蓝牙扫描/连接
  Bluetooth scan/connect
- 定位（用于 GPS 轨迹）
  Location (for GPS tracking)
- 网络（地图瓦片下载）
  Network (map tiles)

## 兼容性 / Compatibility
- Android 8.0+ (minSdk 26)
  Android 8.0+ (minSdk 26)
- 仅支持 KC761 系列设备（BLE）
  Only KC761 series devices (BLE)

## 隐私 / 免责声明 / Privacy / Disclaimer
- 仅限 KC761 设备配套使用
  For use with KC761 devices only
- 记录数据仅保存在本机
  Data stays on-device only
- 本软件为测试版，结果仅供参考
  This is a test build; results are for reference only

## 数据与导出 / Data & Export
- 记录数据仅保存在本机
  Data is stored locally only
- CSV 字段包含：时间戳、传感器类型、CPS、剂量率、经纬度、定位精度
  CSV fields: timestamp, sensor type, CPS, dose rate, lat/lng, accuracy
- 导出路径由系统文件选择器选择
  Export path selected via system file picker

## 地图缓存 / Map Cache
- 仅缓存 OSM Standard 图层
  Only OSM Standard tiles are cached
- 缓存上限约 500MB
  Cache cap ~500MB
- 可在 Option 中清除缓存
  Cache can be cleared in Options

## 快速开始 / Quick Start
```bash
flutter pub get
flutter run
```

## 发布 / Release
```bash
flutter build apk --release
```
生成的 APK 会在 GitHub Release 中提供下载。
The APK will be available for download via GitHub Releases.

## 开发者 / Developers
- Wu Xiao
- Codex (GPT-5)

## 许可 / License
本项目使用 GPLv3 开源许可。
This project is licensed under GPLv3.

## ???? / Recent Changes
- ??????????????????????????Y???/?????CSV ???  
  Added spectrum panel below the top bar with clear, Y-axis linear/log toggle, and CSV export.
- ?????????????? MC_DATA ?????????????????????  
  Wired multi-channel data + calibration coefficients with energy conversion and axis ticks.
- ????????32px ???? + 200ms ???????????  
  32px grid aggregation with 200ms debounce for better performance.
