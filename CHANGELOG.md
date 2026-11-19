# Changelog

## v1.0.0 - 2026-11-19

Initial public release. / 首次公开发布。

### 中文说明

MTP Guardian 是一个用于将 iPhone 照片和视频稳定复制到 Windows 的工具。它逐个文件复制，自动恢复 MTP 连接，跳过已经完成的文件，对失败文件进行多轮重试，并生成最终统计与失败清单。

### English

MTP Guardian is a resilient Windows utility for transferring iPhone photos and videos over MTP. It copies one file at a time, recovers from connection failures, resumes completed files, retries failures in multiple rounds, and writes final statistics and failure reports.

### 更新内容 / Changes

- 从 iPhone 的 MTP 存储复制照片和视频 / Copy iPhone photos and videos from MTP storage
- 按月份保留文件夹结构 / Preserve the monthly folder structure
- 自动处理 MTP 掉线并关闭阻塞的 Windows 复制错误窗口 / Recover from MTP failures and close blocking Windows copy dialogs
- 跳过已完成文件，并对失败文件进行多轮自动重试 / Skip completed files and retry failures in deferred rounds
- 输出逐文件结果、月份汇总和最终失败清单 / Write per-file results, month summaries, and final failure lists
- 增加单实例保护，避免重复任务同时写入 / Add single-instance protection to prevent concurrent writers
