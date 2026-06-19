import 'package:flutter/material.dart';
import 'dart:async';
import '../providers/mind_map_provider.dart';

/// メッセージング機能ダイアログ
/// - ユーザー名設定
/// - 受信箱
/// - メッセージ送信（個別UID指定 or グループ全員）
class MessagingDialog extends StatefulWidget {
  final MindMapProvider provider;
  const MessagingDialog({super.key, required this.provider});

  @override
  State<MessagingDialog> createState() => _MessagingDialogState();
}

class _MessagingDialogState extends State<MessagingDialog> {
  int _tab = 0; // 0=受信箱, 1=送信, 2=設定
  List<Map<String, dynamic>>? _messages;
  bool _loading = false;
  Timer? _pollTimer;

  // 送信フォーム
  String _sendMode = 'group'; // 'group' or 'uid' (uid = 個別指定。UI上はメンバー選択)
  String? _selectedGroupId;
  final TextEditingController _toUidCtrl = TextEditingController();
  final TextEditingController _msgCtrl = TextEditingController();
  bool _sending = false;
  String? _sendError;
  String? _sendSuccess;

  // ── 個別送信用: 同期グループのメンバー一覧を読み込んで選ばせる ──
  // 匿名 / 空名メンバーは除外（自分自身も除外）。
  // _selectedGroupId が変わる毎に再ロードする。
  List<Map<String, String>>? _membersForUidPicker; // null=未ロード
  bool _loadingMembers = false;
  String? _selectedRecipientUid;
  String? _loadedMembersGroupId; // 最後にロードしたグループ (=>キャッシュ判定)

  // 設定
  late final TextEditingController _nameCtrl;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.provider.displayName);
    _selectedGroupId = widget.provider.currentGroupId;
    _loadMessages();
    // 30秒ごとに自動更新
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && _tab == 0) _loadMessages();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _toUidCtrl.dispose();
    _msgCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadMessages() async {
    setState(() => _loading = true);
    final list = await widget.provider.fetchMyMessages();
    if (!mounted) return;
    setState(() {
      _messages = list;
      _loading = false;
    });
  }

  /// 個別送信タブ用に同期グループのメンバー一覧を取得する。
  /// 匿名 (displayName が空 or '匿名'/'Anonymous') と自分自身は除外。
  Future<void> _loadMembersForUidPicker(String groupId) async {
    // 既にロード済みなら再取得しない
    if (_loadedMembersGroupId == groupId && _membersForUidPicker != null) {
      return;
    }
    setState(() {
      _loadingMembers = true;
      _membersForUidPicker = null;
    });
    try {
      final raw = await widget.provider.fetchGroupMembers(groupId);
      final myUid = widget.provider.currentUid;
      final filtered = raw.where((m) {
        final uid = m['uid'] ?? '';
        final name = (m['displayName'] ?? '').trim();
        if (uid.isEmpty || uid == myUid) return false;
        if (name.isEmpty) return false;
        if (name == '匿名') return false;
        if (name.toLowerCase() == 'anonymous') return false;
        return true;
      }).toList();
      if (!mounted) return;
      setState(() {
        _membersForUidPicker = filtered;
        _loadingMembers = false;
        _loadedMembersGroupId = groupId;
        // 既に選ばれていた uid がリストに無ければクリア
        if (_selectedRecipientUid != null &&
            !filtered.any((m) => m['uid'] == _selectedRecipientUid)) {
          _selectedRecipientUid = null;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMembers = false;
        _membersForUidPicker = [];
      });
    }
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _sendError = null;
      _sendSuccess = null;
    });
    try {
      final text = _msgCtrl.text;
      bool ok;
      if (_sendMode == 'group') {
        if (_selectedGroupId == null) {
          throw Exception(widget.provider.t('msg.selectGroupFirst'));
        }
        ok = await widget.provider.sendMessage(
            toGroupId: _selectedGroupId, text: text);
      } else {
        // 個別送信: メンバードロップダウンで選択された uid を使う
        final uid = _selectedRecipientUid ?? '';
        if (uid.isEmpty) {
          throw Exception(widget.provider.t('msg.selectRecipient'));
        }
        ok = await widget.provider.sendMessage(toUid: uid, text: text);
      }
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendSuccess = ok
            ? widget.provider.t('msg.sent')
            : widget.provider.t('msg.sendFail');
        if (ok) _msgCtrl.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendError = e.toString();
      });
    }
  }

  Future<void> _saveName() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) return;
    await widget.provider.setDisplayName(name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(widget.provider.t('msg.sent')),
        backgroundColor: const Color(0xFF43B97F),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E2E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(children: [
        const Icon(Icons.chat_bubble_rounded,
            color: Color(0xFFBA68C8), size: 20),
        const SizedBox(width: 8),
        Text(provider.t('msg.title'),
            style: const TextStyle(color: Colors.white, fontSize: 16)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white54, size: 18),
          onPressed: () => Navigator.pop(context),
        ),
      ]),
      content: SizedBox(
        width: 420,
        height: 480,
        child: Column(children: [
          // タブ
          Row(children: [
            _tabBtn(provider.t('msg.tabInbox'), 0, icon: Icons.inbox_rounded),
            const SizedBox(width: 6),
            _tabBtn(provider.t('msg.tabSend'), 1, icon: Icons.send_rounded),
            const SizedBox(width: 6),
            _tabBtn(provider.t('msg.tabSettings'), 2, icon: Icons.person_rounded),
            const Spacer(),
            if (_tab == 0)
              IconButton(
                icon: const Icon(Icons.refresh_rounded,
                    color: Colors.white54, size: 18),
                tooltip: provider.t('msg.refreshTooltip'),
                onPressed: _loadMessages,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              ),
          ]),
          const SizedBox(height: 12),
          Expanded(
            child: _tab == 0
                ? _buildInbox()
                : _tab == 1
                    ? _buildSendForm()
                    : _buildSettings(),
          ),
        ]),
      ),
    );
  }

  Widget _tabBtn(String label, int idx, {IconData? icon}) {
    final selected = _tab == idx;
    const color = Color(0xFFBA68C8);
    return GestureDetector(
      onTap: () => setState(() => _tab = idx),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color : Colors.white24),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, color: selected ? color : Colors.white38, size: 12),
            const SizedBox(width: 4),
          ],
          Text(label,
              style: TextStyle(
                  color: selected ? color : Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }

  Widget _buildInbox() {
    final provider = widget.provider;
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFFBA68C8)));
    }
    if (_messages == null || _messages!.isEmpty) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.inbox_rounded, color: Colors.white24, size: 40),
          const SizedBox(height: 8),
          Text(provider.t('msg.empty'),
              style: const TextStyle(color: Colors.white38, fontSize: 13)),
        ]),
      );
    }
    return ListView.builder(
      itemCount: _messages!.length,
      itemBuilder: (_, i) => _buildMessageItem(_messages![i]),
    );
  }

  Widget _buildMessageItem(Map<String, dynamic> msg) {
    final provider = widget.provider;
    final isFromMe = msg['isFromMe'] as bool? ?? false;
    final isRead = msg['read'] as bool? ?? false;
    final ts = msg['timestamp'] as String? ?? '';
    final dt = DateTime.tryParse(ts)?.toLocal();
    final dtStr = dt != null
        ? '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'
        : '';
    final fromName = msg['fromName'] as String? ?? provider.t('msg.anonymous');
    final toGroupId = msg['toGroupId'] as String? ?? '';
    final toUid = msg['toUid'] as String? ?? '';
    final text = msg['text'] as String? ?? '';
    final msgId = msg['id'] as String;
    final color = isFromMe
        ? const Color(0xFF6C63FF)
        : (isRead
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFBA68C8).withValues(alpha: 0.18));

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
            color: isFromMe
                ? const Color(0xFF6C63FF).withValues(alpha: 0.5)
                : (isRead
                    ? Colors.white12
                    : const Color(0xFFBA68C8).withValues(alpha: 0.5))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(
              isFromMe
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              color: isFromMe ? Colors.white70 : Colors.white54,
              size: 12),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              isFromMe
                  ? '${provider.t('msg.toPrefix')}: ${toGroupId.isNotEmpty ? "${provider.t('msg.group')} $toGroupId" : (toUid.isNotEmpty ? "UID:${toUid.length > 8 ? "${toUid.substring(0, 8)}..." : toUid}" : "")}'
                  : '${provider.t('msg.fromPrefix')}: $fromName${toGroupId.isNotEmpty ? "（${provider.t('msg.group')} $toGroupId）" : ""}',
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(dtStr,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
        ]),
        const SizedBox(height: 6),
        Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 13)),
        const SizedBox(height: 4),
        Row(children: [
          if (!isFromMe && !isRead) ...[
            TextButton.icon(
              icon: const Icon(Icons.mark_email_read_rounded,
                  color: Color(0xFF43B97F), size: 12),
              label: Text(provider.t('msg.markRead'),
                  style: const TextStyle(
                      color: Color(0xFF43B97F), fontSize: 10)),
              style: TextButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              onPressed: () async {
                await widget.provider.markMessageRead(msgId);
                _loadMessages();
              },
            ),
            const Spacer(),
          ] else
            const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.delete_outline_rounded,
                color: Colors.white24, size: 12),
            label: Text(provider.t('msg.deleteBtn'),
                style: const TextStyle(color: Colors.white24, fontSize: 10)),
            style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap),
            onPressed: () async {
              final ok = await widget.provider.deleteMessage(msgId);
              if (ok) _loadMessages();
            },
          ),
        ]),
      ]),
    );
  }

  Widget _buildSendForm() {
    final provider = widget.provider;
    final groups = widget.provider.joinedGroupIds;
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(provider.t('msg.recipientLabel'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _sendMode = 'group'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _sendMode == 'group'
                      ? const Color(0xFFBA68C8).withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _sendMode == 'group'
                          ? const Color(0xFFBA68C8)
                          : Colors.white12),
                ),
                child: Center(
                  child: Text(provider.t('msg.groupAll'),
                      style: TextStyle(
                          color: _sendMode == 'group'
                              ? const Color(0xFFBA68C8)
                              : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: GestureDetector(
              onTap: () => setState(() => _sendMode = 'uid'),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _sendMode == 'uid'
                      ? const Color(0xFFBA68C8).withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _sendMode == 'uid'
                          ? const Color(0xFFBA68C8)
                          : Colors.white12),
                ),
                child: Center(
                  child: Text(provider.t('msg.uidMode'),
                      style: TextStyle(
                          color: _sendMode == 'uid'
                              ? const Color(0xFFBA68C8)
                              : Colors.white54,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        if (_sendMode == 'group') ...[
          if (groups.isEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.redAccent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                provider.t('msg.noGroupWarn'),
                style: const TextStyle(color: Colors.redAccent, fontSize: 11),
              ),
            )
          else
            DropdownButtonFormField<String>(
              initialValue: groups.contains(_selectedGroupId)
                  ? _selectedGroupId
                  : groups.first,
              dropdownColor: const Color(0xFF1E1E2E),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
              items: groups
                  .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                  .toList(),
              onChanged: (v) => setState(() => _selectedGroupId = v),
            ),
        ] else ...[
          // 個別送信: 同期グループのメンバーを選ぶドロップダウン
          // - まずグループを選ぶ必要あり (一覧はその中のメンバー)
          // - 匿名メンバー & 自分自身は除外
          if (groups.isEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(provider.t('msg.noGroupWarn'),
                  style: const TextStyle(
                      color: Colors.orangeAccent, fontSize: 12)),
            )
          else ...[
            // グループ選択 (個別送信の絞り込みに使う)
            Row(children: [
              const Icon(Icons.folder_rounded,
                  color: Colors.white38, size: 14),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: groups.contains(_selectedGroupId)
                      ? _selectedGroupId
                      : groups.first,
                  dropdownColor: const Color(0xFF1E1E2E),
                  style:
                      const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.05),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                  items: groups
                      .map((g) =>
                          DropdownMenuItem(value: g, child: Text(g)))
                      .toList(),
                  onChanged: (v) {
                    setState(() {
                      _selectedGroupId = v;
                      _selectedRecipientUid = null;
                      _loadedMembersGroupId = null;
                      _membersForUidPicker = null;
                    });
                    if (v != null) _loadMembersForUidPicker(v);
                  },
                ),
              ),
            ]),
            const SizedBox(height: 10),
            // メンバー一覧を取ってきてドロップダウンで選ばせる
            Builder(builder: (_) {
              // 初回: まだロードしてないならロード発火
              final targetGid = groups.contains(_selectedGroupId)
                  ? _selectedGroupId!
                  : groups.first;
              if (_loadedMembersGroupId != targetGid &&
                  !_loadingMembers) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _loadMembersForUidPicker(targetGid);
                });
              }
              if (_loadingMembers) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Color(0xFFBA68C8)),
                    ),
                  ),
                );
              }
              final members = _membersForUidPicker ?? const [];
              if (members.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(provider.t('msg.noNamedMembers'),
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 11)),
                );
              }
              // 選択 uid が members 内にあるか確認
              final selected = members.any(
                      (m) => m['uid'] == _selectedRecipientUid)
                  ? _selectedRecipientUid
                  : null;
              return Row(children: [
                const Icon(Icons.person_rounded,
                    color: Colors.white38, size: 14),
                const SizedBox(width: 6),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: selected,
                    dropdownColor: const Color(0xFF1E1E2E),
                    style: const TextStyle(
                        color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      hintText: provider.t('msg.selectRecipient'),
                      hintStyle: const TextStyle(
                          color: Colors.white24, fontSize: 12),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                    ),
                    items: members
                        .map((m) => DropdownMenuItem(
                              value: m['uid'],
                              child: Text(m['displayName'] ?? '—'),
                            ))
                        .toList(),
                    onChanged: (v) =>
                        setState(() => _selectedRecipientUid = v),
                  ),
                ),
              ]);
            }),
          ],
        ],
        const SizedBox(height: 14),
        Text(provider.t('msg.bodyLabel'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        TextField(
          controller: _msgCtrl,
          maxLines: 5,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: provider.t('msg.bodyHint'),
            hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            contentPadding: const EdgeInsets.all(12),
          ),
        ),
        const SizedBox(height: 12),
        if (_sendError != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.redAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_sendError!,
                style: const TextStyle(
                    color: Colors.redAccent, fontSize: 11)),
          ),
        if (_sendSuccess != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFF43B97F).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_sendSuccess!,
                style: const TextStyle(
                    color: Color(0xFF43B97F), fontSize: 11)),
          ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFBA68C8),
                padding: const EdgeInsets.symmetric(vertical: 12)),
            icon: _sending
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded,
                    size: 16, color: Colors.white),
            label: Text(
                _sending ? provider.t('msg.sending') : provider.t('msg.sendBtn'),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            onPressed: _sending ? null : _send,
          ),
        ),
      ]),
    );
  }

  Widget _buildSettings() {
    final provider = widget.provider;
    final uid = widget.provider.currentUid ?? '';
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(provider.t('msg.displayNameLabel'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        TextField(
          controller: _nameCtrl,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            hintText: provider.t('msg.displayNameHint'),
            hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
            filled: true,
            fillColor: Colors.white.withValues(alpha: 0.05),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFBA68C8),
                padding: const EdgeInsets.symmetric(vertical: 10)),
            icon: const Icon(Icons.save_rounded,
                size: 16, color: Colors.white),
            label: Text(provider.t('msg.saveBtn'),
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            onPressed: _saveName,
          ),
        ),
        const SizedBox(height: 24),
        Text(provider.t('msg.yourUid'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            uid.isEmpty ? provider.t('msg.uidNotFetched') : uid,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          provider.t('msg.uidExplain'),
          style: const TextStyle(color: Colors.white38, fontSize: 10),
        ),
        const SizedBox(height: 16),
        Text(provider.t('msg.joinedGroups'),
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 6),
        if (widget.provider.joinedGroupIds.isEmpty)
          Text(provider.t('msg.noGroups'),
              style: const TextStyle(color: Colors.white38, fontSize: 11))
        else
          ...widget.provider.joinedGroupIds.map((g) => Container(
                margin: const EdgeInsets.only(bottom: 4),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(children: [
                  const Icon(Icons.group_rounded,
                      color: Color(0xFF43B97F), size: 14),
                  const SizedBox(width: 6),
                  Text(g,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace')),
                  if (g == widget.provider.currentGroupId) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFF43B97F).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(provider.t('msg.active'),
                          style: const TextStyle(
                              color: Color(0xFF43B97F),
                              fontSize: 9,
                              fontWeight: FontWeight.w700)),
                    ),
                  ],
                ]),
              )),
      ]),
    );
  }
}
