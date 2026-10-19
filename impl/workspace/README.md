# workspace/ — 尚未完成开发（活跃工作区）

按功能模块分目录（`workspace/<module>/`），**每个模块目录里最新的一篇迭代文档就是
该模块的当前任务**。实现完成后，把文档移到 [`../archive/<module>/`](../archive/README.md)
并更新其状态行。

## 目录语义

- 新功能的迭代文档写在 `workspace/<module>/`（目录不存在则创建），命名见下节。
- 不符合 `<时间戳>-<slug>.md` 命名的文件（如本 `README.md`）是目录索引，
  **不是**迭代文档，不参与「最新文档 = 当前任务」的判定。
- 模块名就是正文里的引用句柄（见 [`../README.md`](../README.md) 的「模块与文档」）。

## 文件命名

```
<YYYY-mm-ddTHH-MM-SS>-<slug>.md
```

- `<YYYY-mm-ddTHH-MM-SS>` 是 ISO 8601 本地时间戳（日期与时间用 `T` 分隔）。
- `<slug>` 是功能的简短 kebab-case 概括；不带 `step-` 前缀、不带 phase 编号。
- 时间戳不含空格，因此这类路径**无需**用 `<...>` 包裹即可在 Markdown 中链接。

## 活跃文档索引

当前**没有进行中的迭代**：M7（性能与架构优化）已全部落地，最后一步归档于
`archive/perf/`。原 `milestones` 文档里剩下的条目都属于「已备档、暂不做」：

| 备档条目 | 内容 | 出处 |
|---|---|---|
| `P1-4` | `repo_manager.get_by_path` 的线性扫描（仓库数个位数，0.032 ms 级） | `perf` §5 |
| `S2` | 多目标进程合并（`svn info a b c` / `git ls-files -- a b c`），可作 `status` 视图的过渡步 | `perf` §3.5 S2 |
| `S3` | svn `apply_patch` 的临时文件（svn 1.14.5 不吃 stdin，不是缺陷，勿「统一成 stdin」） | `perf` §5 |

下一个迭代开工时，在本目录建 `<module>/<时间戳>-<slug>.md`，并在上表把对应条目
改成指向新文档；实现完成后连同本表一起收尾。
