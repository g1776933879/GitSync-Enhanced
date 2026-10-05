import 'dart:io';

import 'package:GitSync/api/helper.dart';
import 'package:GitSync/api/manager/settings_manager.dart';
import 'package:GitSync/api/manager/storage.dart';
import 'package:GitSync/constant/dimens.dart';
import 'package:GitSync/global.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:path/path.dart' as p;

/// 传输模式：下载（仓库→本地） / 上传（本地→仓库）
enum TransferMode { download, upload }

/// 传输结果汇总
class TransferResult {
  final List<String> succeeded;
  final List<String> failed;
  final int totalBytes;

  TransferResult({required this.succeeded, required this.failed, required this.totalBytes});

  bool get allSuccess => failed.isEmpty;
  int get totalCount => succeeded.length + failed.length;
}

/// 仓库条目（用于仓库选择器）
class _RepoEntry {
  final int index;
  final String name;
  final String rootPath; // 仓库真实根目录

  _RepoEntry({required this.index, required this.name, required this.rootPath});
}

/// 上传条目（本地文件 → 仓库）
class _UploadItem {
  final String absPath; // 本地绝对路径
  final String relPath; // 目标仓库内的相对路径
  final int size;

  _UploadItem({required this.absPath, required this.relPath, required this.size});
}

/// 文件传输对话框 v4 终极版（下载 / 上传 共用，支持任意仓库 + 任意目录 + 文件夹 + 冲突预览）
///
/// 上传：选本地文件/文件夹（递归）→ 选目标仓库 + 目标目录 → 冲突预览 → 复制 → 自动 stage+commit+push
/// 下载：选源仓库 + 浏览目录 + 勾选文件/文件夹 → 选本地目标目录 → 复制（保留结构）
class TransferDialog extends StatefulWidget {
  final TransferMode mode;
  final String repoRoot; // 当前仓库根目录（文件浏览器传入）
  final String currentDir; // 当前浏览目录
  final List<String> selectedPaths; // 启动时预设的选中路径（下载模式用，可继续增删）
  final Future<void> Function(List<String> relativePaths, int repoIndex, String commitMessage) onUploadCommit; // 上传后提交回调

  const TransferDialog({
    super.key,
    required this.mode,
    required this.repoRoot,
    required this.currentDir,
    required this.selectedPaths,
    required this.onUploadCommit,
  });

  @override
  State<TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends State<TransferDialog> {
  bool _running = false;
  double _progress = 0;
  String _taskLabel = "";
  String? _targetDir; // 下载本地目标目录
  TransferResult? _result;
  final TextEditingController _commitMsgController = TextEditingController(text: "Upload files via GitSync: %s");

  // ---- 仓库选择相关 ----
  List<_RepoEntry> _repos = [];
  int? _selectedRepoIndex;
  List<String> _repoDirPath = []; // 仓库内当前目录（相对根目录的路径段）

  // ---- 下载状态 ----
  final Set<String> _downloadSelections = {}; // 绝对路径集合（文件或文件夹，文件夹递归）

  // ---- 上传状态 ----
  final List<_UploadItem> _uploadItems = [];

  // ---- 冲突预览 ----
  List<String> _conflicts = [];
  bool _conflictsChecked = false;

  @override
  void initState() {
    super.initState();
    _taskLabel = widget.mode == TransferMode.download ? "准备下载…" : "准备上传…";
    _loadRepos();
    // 预置来自文件浏览器的选中项（下载模式）
    if (widget.mode == TransferMode.download) {
      _downloadSelections.addAll(widget.selectedPaths);
    }
  }

  /// 加载所有仓库，并匹配当前仓库
  Future<void> _loadRepos() async {
    try {
      final names = await repoManager.getStringList(StorageKey.repoman_repoNames);
      final list = <_RepoEntry>[];
      for (var i = 0; i < names.length; i++) {
        try {
          final setman = await SettingsManager.scoped(i);
          final path = await setman.getGitDirPath();
          if (path != null) {
            list.add(_RepoEntry(index: i, name: names[i], rootPath: path.$2));
          }
        } catch (e) {
          debugPrint("Load repo $i failed: $e");
        }
      }
      if (!mounted) return;
      setState(() {
        _repos = list;
        final current = widget.repoRoot.replaceFirst(RegExp(r'/$'), '');
        final match = list.indexWhere((r) => r.rootPath.replaceFirst(RegExp(r'/$'), '') == current);
        _selectedRepoIndex = match >= 0 ? list[match].index : (list.isNotEmpty ? list.first.index : null);
        _repoDirPath = [];
      });
    } catch (e) {
      debugPrint("Load repos failed: $e");
    }
  }

  /// 当前选中仓库条目
  _RepoEntry? get _selectedRepo {
    if (_selectedRepoIndex == null) return null;
    for (final r in _repos) {
      if (r.index == _selectedRepoIndex) return r;
    }
    return null;
  }

  /// 当前选中仓库的绝对目录路径
  String get _repoAbsDir {
    final repo = _selectedRepo;
    if (repo == null) return widget.repoRoot;
    return _repoDirPath.isEmpty ? repo.rootPath : p.join(repo.rootPath, p.joinAll(_repoDirPath));
  }

  /// 当前仓库目录相对显示
  String get _repoRelDisplay {
    final repo = _selectedRepo;
    if (repo == null) return "仓库根目录";
    return _repoDirPath.isEmpty ? "仓库根目录 (${repo.name})" : "/${p.joinAll(_repoDirPath)}";
  }

  /// 判断是否为系统目录/文件（.git、.DS_Store），过滤掉避免误操作
  bool _isSystemEntry(String path) {
    final n = p.basename(path);
    return n == ".git" || n == ".DS_Store";
  }

  // ================= 文件选择 =================

  /// 上传：选择本地文件（多选）
  Future<void> _pickUploadFiles() async {
    try {
      final result = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (result == null || result.files.isEmpty) return;
      setState(() {
        for (final f in result.files) {
          final path = f.path;
          if (path == null || path.isEmpty) continue;
          _uploadItems.add(_UploadItem(
            absPath: path,
            relPath: p.basename(path),
            size: f.size,
          ));
        }
        _conflictsChecked = false;
      });
    } catch (e) {
      Fluttertoast.showToast(msg: "选择文件失败: $e", toastLength: Toast.LENGTH_LONG, gravity: null);
    }
  }

  /// 上传：选择整个文件夹（递归展开，保留文件夹名作为顶级目录）
  Future<void> _pickUploadFolder() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || dir.isEmpty) return;
      final folderName = p.basename(dir);
      final files = await _collectFilesRecursively(Directory(dir));
      if (files.isEmpty) {
        Fluttertoast.showToast(msg: "该文件夹为空，没有可上传的文件", toastLength: Toast.LENGTH_LONG, gravity: null);
        return;
      }
      setState(() {
        for (final f in files) {
          _uploadItems.add(_UploadItem(
            absPath: f.path,
            relPath: p.join(folderName, p.relative(f.path, from: dir)),
            size: f.lengthSync(), // 同步取真实大小，避免界面显示 0 B
          ));
        }
        _conflictsChecked = false;
      });
    } catch (e) {
      Fluttertoast.showToast(msg: "选择文件夹失败: $e", toastLength: Toast.LENGTH_LONG, gravity: null);
    }
  }

  /// 递归收集目录内所有文件
  Future<List<File>> _collectFilesRecursively(Directory dir) async {
    final files = <File>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && !_isSystemEntry(entity.path)) files.add(entity);
    }
    return files;
  }

  // ================= 传输执行 =================

  /// 复制单个文件（自动建父目录）
  Future<bool> _copyFile(File src, String destPath) async {
    try {
      await File(destPath).parent.create(recursive: true);
      await src.copy(destPath);
      return true;
    } catch (e) {
      debugPrint("Copy failed: $src → $e");
      return false;
    }
  }

  /// 执行上传：本地文件/文件夹 → 所选仓库目录 → stage+commit+push
  Future<TransferResult> _runUpload() async {
    final succeeded = <String>[];
    final failed = <String>[];
    var totalBytes = 0;
    final relPaths = <String>[];

    final repo = _selectedRepo;
    if (repo == null) {
      return TransferResult(succeeded: [], failed: ["未找到可用仓库"], totalBytes: 0);
    }
    final destDir = _repoAbsDir;

    final total = _uploadItems.length;
    for (var i = 0; i < total; i++) {
      final item = _uploadItems[i];
      setState(() {
        _progress = (i + 1) / total;
        _taskLabel = "上传中 (${i + 1}/$total): ${p.basename(item.absPath)}";
      });
      final destPath = p.join(destDir, item.relPath);
      final size = await File(item.absPath).length();
      if (await _copyFile(File(item.absPath), destPath)) {
        succeeded.add(p.relative(destPath, from: repo.rootPath));
        relPaths.add(p.relative(destPath, from: repo.rootPath));
        totalBytes += size;
      } else {
        failed.add(item.relPath);
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }

    if (relPaths.isNotEmpty) {
      setState(() => _taskLabel = "提交并推送到「${repo.name}」…");
      try {
        final msg = _commitMsgController.text.trim();
        await widget.onUploadCommit(relPaths, repo.index, msg.isEmpty ? "Upload files via GitSync: %s" : msg);
      } catch (e) {
        debugPrint("Commit/Push failed: $e");
        failed.addAll(relPaths.where((r) => !failed.contains(r)));
      }
    }

    return TransferResult(succeeded: succeeded, failed: failed, totalBytes: totalBytes);
  }

  /// 收集下载文件列表：（absPath, 目标相对路径）
  Future<List<(String, String)>> _collectDownloadItems() async {
    final items = <(String, String)>[];
    for (final sel in _downloadSelections.toList()) {
      final type = FileSystemEntity.typeSync(sel);
      if (type == FileSystemEntityType.file) {
        items.add((sel, p.basename(sel)));
      } else if (type == FileSystemEntityType.directory) {
        final dirFiles = await _collectFilesRecursively(Directory(sel));
        final parent = p.dirname(sel);
        for (final f in dirFiles) {
          items.add((f.path, p.relative(f.path, from: parent)));
        }
      }
    }
    return items;
  }

  /// 执行下载：源仓库勾选项 → 本地目标目录
  Future<TransferResult> _runDownload() async {
    final target = _targetDir!;
    final succeeded = <String>[];
    final failed = <String>[];
    var totalBytes = 0;

    final items = await _collectDownloadItems();
    if (items.isEmpty) {
      return TransferResult(succeeded: [], failed: [], totalBytes: 0);
    }

    final total = items.length;
    for (var i = 0; i < total; i++) {
      final (absPath, relDest) = items[i];
      setState(() {
        _progress = (i + 1) / total;
        _taskLabel = "下载中 (${i + 1}/$total): ${p.basename(absPath)}";
      });
      final destPath = p.join(target, relDest);
      final size = await File(absPath).length();
      if (await _copyFile(File(absPath), destPath)) {
        succeeded.add(relDest);
        totalBytes += size;
      } else {
        failed.add(relDest);
      }
      await Future.delayed(const Duration(milliseconds: 10));
    }

    return TransferResult(succeeded: succeeded, failed: failed, totalBytes: totalBytes);
  }

  /// 计算上传冲突（目标已存在同名文件）
  void _checkConflicts() {
    final repo = _selectedRepo;
    if (repo == null || _uploadItems.isEmpty) {
      _conflicts = [];
      _conflictsChecked = true;
      return;
    }
    final destDir = _repoAbsDir;
    final conflicts = <String>[];
    for (final item in _uploadItems) {
      final destPath = p.join(destDir, item.relPath);
      if (File(destPath).existsSync()) {
        conflicts.add(item.relPath);
      }
    }
    _conflicts = conflicts;
    _conflictsChecked = true;
  }

  /// 开始执行前的最终确认（上传=同名冲突预览；下载=本地覆盖确认）
  Future<bool> _confirmBeforeStart() async {
    if (widget.mode == TransferMode.upload && _uploadItems.isNotEmpty) {
      _checkConflicts();
      if (_conflicts.isNotEmpty) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: colours.primaryDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
            title: Row(
              children: [
                FaIcon(FontAwesomeIcons.triangleExclamation, color: colours.tertiaryInfo, size: textLG),
                SizedBox(width: spaceSM),
                Text("发现 ${_conflicts.length} 个同名文件", style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("以下文件在目标仓库已存在，继续将覆盖：", style: TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                  SizedBox(height: spaceSM),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: _conflicts
                            .map((c) => Padding(
                                  padding: EdgeInsets.symmetric(vertical: 2),
                                  child: Row(
                                    children: [
                                      FaIcon(FontAwesomeIcons.filePen, color: colours.tertiaryInfo, size: textSM),
                                      SizedBox(width: spaceSM),
                                      Expanded(child: Text(c, style: TextStyle(color: colours.primaryLight, fontSize: textSM))),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text("取消"),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text("覆盖并继续"),
              ),
            ],
          ),
        );
        return proceed ?? false;
      }
    }

    // 下载模式：本地目标目录覆盖确认
    if (widget.mode == TransferMode.download && _targetDir != null && _downloadSelections.isNotEmpty) {
      final items = await _collectDownloadItems();
      final overwriteList = <String>[];
      for (final (_, relDest) in items) {
        if (File(p.join(_targetDir!, relDest)).existsSync()) {
          overwriteList.add(relDest);
        }
      }
      if (overwriteList.isNotEmpty) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: colours.primaryDark,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
            title: Row(
              children: [
                FaIcon(FontAwesomeIcons.triangleExclamation, color: colours.tertiaryInfo, size: textLG),
                SizedBox(width: spaceSM),
                Text("本地已存在 ${overwriteList.length} 个同名文件", style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold)),
              ],
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("下载到目标目录会覆盖以下本地文件：", style: TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                  SizedBox(height: spaceSM),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: overwriteList
                            .take(100)
                            .map((c) => Padding(
                                  padding: EdgeInsets.symmetric(vertical: 2),
                                  child: Row(
                                    children: [
                                      FaIcon(FontAwesomeIcons.filePen, color: colours.tertiaryInfo, size: textSM),
                                      SizedBox(width: spaceSM),
                                      Expanded(child: Text(c, style: TextStyle(color: colours.primaryLight, fontSize: textSM))),
                                    ],
                                  ),
                                ))
                            .toList(),
                      ),
                    ),
                  ),
                  if (overwriteList.length > 100)
                    Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text("… 等共 ${overwriteList.length} 项", style: TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text("取消"),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text("覆盖并下载"),
              ),
            ],
          ),
        );
        return proceed ?? false;
      }
    }

    return true;
  }

  /// 开始执行
  Future<void> _start() async {
    if (!await _confirmBeforeStart()) return;

    setState(() => _running = true);
    _progress = 0;

    TransferResult result;
    if (widget.mode == TransferMode.download) {
      if (_targetDir == null) {
        Fluttertoast.showToast(msg: "请先选择下载目标目录", toastLength: Toast.LENGTH_LONG, gravity: null);
        setState(() => _running = false);
        return;
      }
      if (_downloadSelections.isEmpty) {
        Fluttertoast.showToast(msg: "请先勾选要下载的文件/文件夹", toastLength: Toast.LENGTH_LONG, gravity: null);
        setState(() => _running = false);
        return;
      }
      result = await _runDownload();
    } else {
      if (_uploadItems.isEmpty) {
        Fluttertoast.showToast(msg: "请先选择要上传的文件/文件夹", toastLength: Toast.LENGTH_LONG, gravity: null);
        setState(() => _running = false);
        return;
      }
      result = await _runUpload();
    }

    if (!mounted) return;
    setState(() {
      _result = result;
      _running = false;
      _progress = 1;
      _taskLabel = result.allSuccess ? "全部完成 ✓" : "部分失败，请查看结果";
    });
  }

  // ================= UI 组件 =================

  /// 结果展示面板
  Widget _buildResultView() {
    final r = _result!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.allSuccess ? "✅ 全部成功（${r.succeeded.length} 个文件）" : "⚠️ 完成，但有失败项",
          style: TextStyle(color: r.allSuccess ? colours.primaryLight : colours.tertiaryInfo, fontSize: textMD, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: spaceSM),
        Text("📦 传输字节: ${formatBytes(r.totalBytes)}", style: TextStyle(color: colours.secondaryLight, fontSize: textSM)),
        if (r.failed.isNotEmpty) ...[
          SizedBox(height: spaceSM),
          Text("❌ 失败列表:", style: TextStyle(color: colours.tertiaryInfo, fontSize: textSM, fontWeight: FontWeight.bold)),
          ...r.failed.map((f) => Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text("• $f", style: TextStyle(color: colours.secondaryLight, fontSize: textSM)),
              )),
        ],
        SizedBox(height: spaceMD),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text("关闭"),
            ),
          ],
        ),
      ],
    );
  }

  /// 仓库选择下拉
  Widget _buildRepoSelector() {
    if (_repos.isEmpty) {
      return Row(
        children: [
          FaIcon(FontAwesomeIcons.triangleExclamation, color: colours.tertiaryInfo, size: textSM),
          SizedBox(width: spaceSM),
          Expanded(
            child: Text(
              "未找到仓库，请先在应用里添加仓库",
              style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        FaIcon(FontAwesomeIcons.boxArchive, color: colours.primaryLight, size: textMD),
        SizedBox(width: spaceSM),
        Expanded(
          child: DropdownButton<int>(
            value: _selectedRepoIndex,
            isExpanded: true,
            dropdownColor: colours.secondaryDark,
            borderRadius: BorderRadius.all(cornerRadiusSM),
            icon: FaIcon(FontAwesomeIcons.chevronDown, color: colours.primaryLight, size: textSM),
            style: TextStyle(color: colours.primaryLight, fontSize: textSM),
            underline: const SizedBox.shrink(),
            items: _repos
                .map((r) => DropdownMenuItem<int>(
                      value: r.index,
                      child: Text(
                        r.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colours.primaryLight, fontSize: textSM),
                      ),
                    ))
                .toList(),
            onChanged: _running
                ? null
                : (idx) {
                    setState(() {
                      _selectedRepoIndex = idx;
                      _repoDirPath = [];
                      _downloadSelections.clear();
                      _conflictsChecked = false;
                    });
                  },
          ),
        ),
      ],
    );
  }

  /// 仓库内目录浏览器（下载=勾选源，上传=选目标目录）
  Widget _buildRepoDirBrowser() {
    final repo = _selectedRepo;
    if (repo == null) return const SizedBox.shrink();

    final currentAbs = _repoAbsDir;
    List<FileSystemEntity> children;
    try {
      children = Directory(currentAbs).listSync(followLinks: false);
      children.removeWhere((e) => _isSystemEntry(e.path));
      children.sort((a, b) {
        final aDir = FileSystemEntity.isDirectorySync(a.path);
        final bDir = FileSystemEntity.isDirectorySync(b.path);
        if (aDir != bDir) return aDir ? -1 : 1;
        return p.basename(a.path).toLowerCase().compareTo(p.basename(b.path).toLowerCase());
      });
    } catch (e) {
      children = [];
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                widget.mode == TransferMode.download ? "📂 源目录: $_repoRelDisplay" : "📂 上传目录: $_repoRelDisplay",
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colours.primaryLight, fontSize: textSM, fontWeight: FontWeight.bold),
              ),
            ),
            if (_repoDirPath.isNotEmpty)
              IconButton(
                onPressed: _running ? null : () => setState(() => _repoDirPath.removeLast()),
                icon: FaIcon(FontAwesomeIcons.arrowUp, color: colours.primaryLight, size: textSM),
              ),
          ],
        ),
        Container(
          constraints: BoxConstraints(maxHeight: 160),
          decoration: BoxDecoration(
            color: colours.secondaryDark,
            borderRadius: BorderRadius.all(cornerRadiusSM),
          ),
          child: children.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(spaceSM),
                  child: Text(
                    "（此目录为空）",
                    style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                  ),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: children.length,
                  itemBuilder: (context, i) {
                    final isDir = FileSystemEntity.isDirectorySync(children[i].path);
                    final name = p.basename(children[i].path);
                    final isSelected = _downloadSelections.contains(children[i].path);

                    return InkWell(
                      onTap: _running
                          ? null
                          : () {
                              if (widget.mode == TransferMode.download) {
                                // 下载模式：点文件夹进入，点文件勾选
                                if (isDir) {
                                  setState(() => _repoDirPath.add(name));
                                } else {
                                  setState(() {
                                    if (isSelected) {
                                      _downloadSelections.remove(children[i].path);
                                    } else {
                                      _downloadSelections.add(children[i].path);
                                    }
                                  });
                                }
                              } else {
                                // 上传模式：点文件夹进入选目标目录
                                if (isDir) setState(() => _repoDirPath.add(name));
                              }
                            },
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: spaceSM, vertical: 6),
                        child: Row(
                          children: [
                            if (widget.mode == TransferMode.download)
                              Checkbox(
                                value: isDir ? false : isSelected,
                                onChanged: _running || isDir
                                    ? null
                                    : (v) {
                                        setState(() {
                                          if (v == true) {
                                            _downloadSelections.add(children[i].path);
                                          } else {
                                            _downloadSelections.remove(children[i].path);
                                          }
                                        });
                                      },
                              ),
                            FaIcon(
                              isDir ? FontAwesomeIcons.folder : FontAwesomeIcons.file,
                              color: isDir ? colours.tertiaryInfo : colours.secondaryLight,
                              size: textSM,
                            ),
                            SizedBox(width: spaceSM),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: colours.primaryLight, fontSize: textSM),
                              ),
                            ),
                            // 下载模式：文件夹可"整目录勾选"
                            if (isDir && widget.mode == TransferMode.download)
                              IconButton(
                                onPressed: _running
                                    ? null
                                    : () {
                                        setState(() {
                                          if (_downloadSelections.contains(children[i].path)) {
                                            _downloadSelections.remove(children[i].path);
                                          } else {
                                            _downloadSelections.add(children[i].path);
                                          }
                                        });
                                      },
                                icon: FaIcon(
                                  _downloadSelections.contains(children[i].path) ? FontAwesomeIcons.solidSquareCheck : FontAwesomeIcons.square,
                                  color: _downloadSelections.contains(children[i].path) ? colours.primaryLight : colours.secondaryLight,
                                  size: textMD,
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: colours.primaryDark,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(cornerRadiusMD)),
      title: Row(
        children: [
          FaIcon(
            widget.mode == TransferMode.download ? FontAwesomeIcons.download : FontAwesomeIcons.upload,
            color: colours.primaryLight,
            size: textLG,
          ),
          SizedBox(width: spaceSM),
          Text(
            widget.mode == TransferMode.download ? "下载文件" : "上传文件/文件夹到仓库",
            style: TextStyle(color: colours.primaryLight, fontSize: textLG, fontWeight: FontWeight.bold),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: _result != null
            ? _buildResultView()
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 仓库选择器（共用）
                  _buildRepoSelector(),
                  SizedBox(height: spaceSM),
                  // 仓库内目录浏览
                  _buildRepoDirBrowser(),
                  SizedBox(height: spaceSM),
                  // 下载：本地目标目录 + 已选列表
                  if (widget.mode == TransferMode.download) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _targetDir == null ? "未选择本地目标目录" : _targetDir!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                          ),
                        ),
                        IconButton(
                          onPressed: _running ? null : _pickDownloadTarget,
                          icon: FaIcon(FontAwesomeIcons.folderOpen, color: colours.primaryLight, size: textMD),
                        ),
                      ],
                    ),
                    if (_downloadSelections.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          "已勾选 ${_downloadSelections.length} 项（文件夹递归）",
                          style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                        ),
                      ),
                  ],
                  // 上传：选择文件/文件夹 + 已选列表 + 提交信息
                  if (widget.mode == TransferMode.upload) ...[
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            _uploadItems.isEmpty ? "未选择文件/文件夹" : "已选 ${_uploadItems.length} 个文件（${formatBytes(_uploadItems.fold<int>(0, (s, it) => s + it.size))}）",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                          ),
                        ),
                        IconButton(
                          onPressed: _running ? null : _pickUploadFiles,
                          tooltip: "选择文件",
                          icon: FaIcon(FontAwesomeIcons.fileCirclePlus, color: colours.primaryLight, size: textMD),
                        ),
                        IconButton(
                          onPressed: _running ? null : _pickUploadFolder,
                          tooltip: "选择整个文件夹",
                          icon: FaIcon(FontAwesomeIcons.folderPlus, color: colours.primaryLight, size: textMD),
                        ),
                      ],
                    ),
                    if (_uploadItems.isNotEmpty)
                      Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          "目标相对路径会保留目录结构",
                          style: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                        ),
                      ),
                    SizedBox(height: spaceSM),
                    TextField(
                      controller: _commitMsgController,
                      enabled: !_running,
                      maxLines: 2,
                      minLines: 1,
                      style: TextStyle(color: colours.primaryLight, fontSize: textSM),
                      decoration: InputDecoration(
                        labelText: "提交信息（可选，%s 会被替换为时间）",
                        labelStyle: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                        hintText: "Upload files via GitSync: %s",
                        hintStyle: TextStyle(color: colours.secondaryLight, fontSize: textSM),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(cornerRadiusSM),
                          borderSide: BorderSide(color: colours.tertiaryDark),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(cornerRadiusSM),
                          borderSide: BorderSide(color: colours.primaryLight),
                        ),
                      ),
                    ),
                  ],
                  if (_running) ...[
                    SizedBox(height: spaceMD),
                    LinearProgressIndicator(value: _progress, color: colours.primaryLight, backgroundColor: colours.tertiaryDark),
                    SizedBox(height: spaceSM),
                    Text(_taskLabel, style: TextStyle(color: colours.secondaryLight, fontSize: textSM)),
                  ],
                ],
              ),
      ),
      actions: [
        if (_result == null) ...[
          TextButton(
            onPressed: _running ? null : () => Navigator.of(context).pop(),
            child: Text("取消"),
          ),
          TextButton(
            onPressed: _running
                ? null
                : () {
                    if (widget.mode == TransferMode.download && _targetDir == null) {
                      Fluttertoast.showToast(msg: "请先选择本地目标目录", toastLength: Toast.LENGTH_LONG, gravity: null);
                      return;
                    }
                    if (widget.mode == TransferMode.download && _downloadSelections.isEmpty) {
                      Fluttertoast.showToast(msg: "请先勾选要下载的内容", toastLength: Toast.LENGTH_LONG, gravity: null);
                      return;
                    }
                    if (widget.mode == TransferMode.upload && _uploadItems.isEmpty) {
                      Fluttertoast.showToast(msg: "请先选择要上传的文件/文件夹", toastLength: Toast.LENGTH_LONG, gravity: null);
                      return;
                    }
                    if (_selectedRepo == null) {
                      Fluttertoast.showToast(msg: "请先选择目标仓库", toastLength: Toast.LENGTH_LONG, gravity: null);
                      return;
                    }
                    _start();
                  },
            child: Text(_running ? "处理中…" : "开始"),
          ),
        ],
      ],
    );
  }

  /// 下载：选择本地目标目录
  Future<void> _pickDownloadTarget() async {
    try {
      final dir = await FilePicker.platform.getDirectoryPath();
      if (dir == null || dir.isEmpty) return;
      setState(() => _targetDir = dir);
    } catch (e) {
      Fluttertoast.showToast(msg: "选择目录失败: $e", toastLength: Toast.LENGTH_LONG, gravity: null);
    }
  }
}

/// 便捷入口：显示传输对话框
Future<void> showTransferDialog(
  BuildContext context, {
  required TransferMode mode,
  required String repoRoot,
  required String currentDir,
  required List<String> selectedPaths,
  required Future<void> Function(List<String> relativePaths, int repoIndex, String commitMessage) onUploadCommit,
}) {
  return showDialog(
    context: context,
    builder: (context) => TransferDialog(
      mode: mode,
      repoRoot: repoRoot,
      currentDir: currentDir,
      selectedPaths: selectedPaths,
      onUploadCommit: onUploadCommit,
    ),
  );
}