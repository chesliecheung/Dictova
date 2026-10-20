# 隐私说明

Dictova 以本地优先为设计原则。

## Dictova 不会做什么

- 不上传 MDX、MDD、CSS 或转换后的词典内容
- 不收集使用数据、崩溃分析或设备标识符
- 不接入广告、分析或用户追踪服务
- 不修改用户选择的原始词典文件

## 网络访问

首次转换时，Dictova 需要联网安装开源解析依赖，并取得 Apple Dictionary Development Kit 的公开镜像。依赖会缓存在：

`~/Library/Application Support/Dictova`

完成初始化后，普通词典转换在本机执行。

## 本地文件

- 转换结果写入用户选择的输出目录
- 一键导入会将 `.dictionary` 包复制到 `~/Library/Dictionaries`
- 用户可以从 Dictova 的“工具”页打开或管理这些目录

本说明适用于 Dictova 1.6.0。
