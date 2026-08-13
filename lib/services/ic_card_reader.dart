import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/platform_tags.dart';

/// ── IC カード残高リーダー (= ユーザー要望: ICカード残高取得ボタン) ──
///
/// 交通系 FeliCa カード (Suica / PASMO / ICOCA / manaca / TOICA / SUGOCA /
/// nimoca / Kitaca / はやかけん など) の残高を NFC 経由で読み取る。
/// これらは全て同じ FeliCa 仕様 (システムコード 0x0003 / 履歴サービス
/// 0x090F) なので 1 つの読み取り経路で対応できる。
///
/// **Android 専用**。 FeliCa 読み取りはネイティブ NFC が必須で、 iOS は
/// 有料の Apple Entitlement 申請が前提のため未対応。 Windows / iOS / その他
/// では [readTransitBalance] が [IcReadStatus.notSupported] を返すだけで、
/// 例外を投げず、 ビルドも壊さない (nfc_manager は android/ios のみ宣言する
/// federated プラグインなので、 Windows ビルドではプラグイン登録がスキップ
/// されるだけ。 念のため全てのネイティブ呼び出しは Platform.isAndroid で
/// ガードする)。
enum IcReadStatus {
  /// 残高取得に成功。
  success,

  /// この端末は FeliCa(NFC) に対応していない / NFC がオフ。
  notSupported,

  /// 一定時間カードがタッチされなかった。
  timeout,

  /// FeliCa カードではない / 残高サービスを持たない / 通信エラー。
  readError,
}

/// 残高読み取りの結果。
class IcCardResult {
  final IcReadStatus status;

  /// 残高 (円)。 [status] が success のときのみ非 null。
  final int? balanceYen;

  /// カードの IDm (16進文字列)。 検出できたら入れる。
  final String? idm;

  /// 読み取り失敗時の補足メッセージ (日本語)。
  final String? message;

  /// 交通系ICの利用履歴。最新順。
  final List<IcCardHistoryEntry> history;

  const IcCardResult(
    this.status, {
    this.balanceYen,
    this.idm,
    this.message,
    this.history = const [],
  });
}

/// 交通系ICの利用履歴 1 件。
///
/// 駅名DBはアプリ内に同梱していないため、入出場駅はカード内の線区/駅コードで
/// 表示する。駅名DBを追加すれば [inLineCode]/[inStationCode] 等から駅名変換できる。
class IcCardHistoryEntry {
  final DateTime? date;
  final int terminalCode;
  final int processCode;
  final int inLineCode;
  final int inStationCode;
  final int outLineCode;
  final int outStationCode;
  final int balanceYen;
  final int? amountYen;
  final int sequenceNumber;
  final Uint8List rawBlock;

  const IcCardHistoryEntry({
    required this.date,
    required this.terminalCode,
    required this.processCode,
    required this.inLineCode,
    required this.inStationCode,
    required this.outLineCode,
    required this.outStationCode,
    required this.balanceYen,
    required this.sequenceNumber,
    required this.rawBlock,
    this.amountYen,
  });

  IcCardHistoryEntry withAmount(int? value) => IcCardHistoryEntry(
        date: date,
        terminalCode: terminalCode,
        processCode: processCode,
        inLineCode: inLineCode,
        inStationCode: inStationCode,
        outLineCode: outLineCode,
        outStationCode: outStationCode,
        balanceYen: balanceYen,
        amountYen: value,
        sequenceNumber: sequenceNumber,
        rawBlock: rawBlock,
      );

  String get dateLabel {
    if (date == null) return '日付なし';
    final y = date!.year.toString();
    final m = date!.month.toString().padLeft(2, '0');
    final d = date!.day.toString().padLeft(2, '0');
    return '$y/$m/$d';
  }

  String get processLabel {
    switch (processCode) {
      case 0x01:
        return '運賃支払';
      case 0x02:
        return 'チャージ';
      case 0x03:
        return '券購入';
      case 0x04:
        return '精算';
      case 0x05:
        return '入場精算';
      case 0x06:
        return '窓口出場';
      case 0x07:
        return '新規発行';
      case 0x08:
        return '控除';
      case 0x0D:
      case 0x0F:
        return 'バス利用';
      case 0x11:
        return '再発行';
      case 0x13:
        return '支払/購入';
      case 0x14:
        return 'オートチャージ';
      case 0x46:
        return '物販';
      case 0x48:
        return '特典';
      default:
        return '処理 ${_hex2(processCode)}';
    }
  }

  String get terminalLabel {
    switch (terminalCode) {
      case 0x03:
        return '精算機';
      case 0x04:
        return '携帯端末';
      case 0x05:
        return '車載端末';
      case 0x07:
      case 0x08:
      case 0x12:
      case 0x14:
      case 0x15:
      case 0x48:
        return '券売機';
      case 0x09:
      case 0x1F:
        return '入金機';
      case 0x16:
      case 0x1A:
      case 0x1D:
        return '改札機';
      case 0x17:
        return '簡易改札機';
      case 0x18:
      case 0x19:
        return '窓口端末';
      case 0x1B:
        return '携帯端末';
      case 0x1C:
        return '乗継精算機';
      case 0x46:
        return 'VIEW ALTTE';
      case 0xC7:
        return '物販端末';
      case 0xC8:
        return '自販機';
      default:
        return '端末 ${_hex2(terminalCode)}';
    }
  }

  String get sectionLabel {
    final from = _stationCodeLabel(inLineCode, inStationCode);
    final to = _stationCodeLabel(outLineCode, outStationCode);
    if (from == null && to == null) return '区間情報なし';
    return '${from ?? '----'} → ${to ?? '----'}';
  }

  static String? _stationCodeLabel(int lineCode, int stationCode) {
    if (lineCode == 0 && stationCode == 0) return null;
    // 駅名DB (assets/transit/station_codes.csv) があれば駅名に変換し、
    //   無ければ従来どおり駅コードで表示する (= ユーザー要望: 駅コードを人が
    //   分かる駅名に変換)。
    final name = IcCardReader.stationName(lineCode, stationCode);
    if (name != null && name.isNotEmpty) return name;
    return '駅コード ${_hex2(lineCode)}-${_hex2(stationCode)}';
  }

  static String _hex2(int value) =>
      '0x${value.toRadixString(16).padLeft(2, '0').toUpperCase()}';
}

class IcCardReader {
  IcCardReader._();

  // ── 駅コード → 駅名 変換 DB (= ユーザー要望: 交通系ICの駅コードを人が
  //    分かる駅名に変換)。 FeliCa 履歴の (線区コード, 駅順コード) を駅名へ引く。
  //    巨大な駅名DBはアプリに同梱しないため、 assets/transit/station_codes.csv
  //    を配置すると駅名表示になり、 無ければ従来の駅コード表示にフォールバック
  //    する。 CSV 形式 (1行1駅、 # 始まりはコメント):
  //        lineCode,stationCode,駅名
  //    コードは 10進 か 0x 始まりの16進。 例: `0x01,0x2C,東京` / `1,44,東京`。
  static final Map<int, String> _stationNames = <int, String>{};
  static bool _stationDbLoaded = false;

  static int _stationKey(int lineCode, int stationCode) =>
      ((lineCode & 0xFF) << 8) | (stationCode & 0xFF);

  /// 駅コードに対応する駅名を返す (未登録 / DB未ロードなら null)。
  static String? stationName(int lineCode, int stationCode) {
    if (_stationNames.isEmpty) return null;
    return _stationNames[_stationKey(lineCode, stationCode)];
  }

  /// assets/transit/station_codes.csv から駅名DBを読み込む (初回のみ)。
  /// アセット未配置 / 解析失敗時は何もしない (= 駅コード表示のままにする)。
  static Future<void> loadStationDb() async {
    if (_stationDbLoaded) return;
    _stationDbLoaded = true;
    String csv;
    try {
      csv = await rootBundle.loadString('assets/transit/station_codes.csv');
    } catch (_) {
      return; // アセット未配置
    }
    int parseCode(String s) {
      final t = s.trim();
      if (t.isEmpty) return -1;
      if (t.toLowerCase().startsWith('0x')) {
        return int.tryParse(t.substring(2), radix: 16) ?? -1;
      }
      return int.tryParse(t) ?? -1;
    }

    for (final rawLine in const LineSplitter().convert(csv)) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final cols = line.split(',');
      if (cols.length < 3) continue;
      final lc = parseCode(cols[0]);
      final sc = parseCode(cols[1]);
      if (lc < 0 || sc < 0) continue;
      // 駅名にカンマが含まれる場合に備えて 3 列目以降を結合する。
      final name = cols.sublist(2).join(',').trim();
      if (name.isEmpty) continue;
      _stationNames[_stationKey(lc, sc)] = name;
    }
  }

  /// 交通系 FeliCa の履歴サービス 0x090F (リトルエンディアン 2 バイト)。
  static final Uint8List _suicaHistoryService =
      Uint8List.fromList(<int>[0x0f, 0x09]);

  /// 最新の取引ブロック (ブロック番号 0)。 2 バイトブロックリスト要素:
  /// 0x80 = サービスリスト順 0 + アクセスモード, 0x00 = ブロック番号 0。
  static final Uint8List _latestBlock = Uint8List.fromList(<int>[0x80, 0x00]);

  /// 端末が FeliCa(NFC) 読み取りに使えそうかの事前判定。
  /// NFC アダプタが無い / オフのときに false。 ※ FeliCa 専用かまでは
  /// 確実には判別できないため、 実際の可否は読み取り時に確定する。
  static Future<bool> isAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      return await NfcManager.instance.isAvailable();
    } catch (_) {
      return false;
    }
  }

  /// 交通系 IC カードの残高を読み取る。
  /// [timeout] の間カードがタッチされなければ [IcReadStatus.timeout]。
  static Future<IcCardResult> readTransitBalance({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (!Platform.isAndroid) {
      return const IcCardResult(IcReadStatus.notSupported);
    }

    // 駅コード→駅名 変換用 DB を読み込む (初回のみ。 履歴の区間を駅名表示する)。
    await loadStationDb();

    bool available;
    try {
      available = await NfcManager.instance.isAvailable();
    } catch (_) {
      available = false;
    }
    if (!available) {
      return const IcCardResult(IcReadStatus.notSupported);
    }

    final completer = Completer<IcCardResult>();
    Timer? timer;

    Future<void> finish(IcCardResult result) async {
      if (completer.isCompleted) return;
      timer?.cancel();
      try {
        await NfcManager.instance.stopSession();
      } catch (_) {
        // セッション停止失敗は致命的でないので握り潰す。
      }
      completer.complete(result);
    }

    try {
      // pollingOptions / onError は nfc_manager のバージョン差が大きいため
      //   以前は指定していなかったが、 Android 端末によっては既定ポーリングで
      //   NFC-F(FeliCa) を拾いにくいことがあるため iso18092 を明示する。
      await NfcManager.instance.startSession(
        pollingOptions: {NfcPollingOption.iso18092},
        onDiscovered: (NfcTag tag) async {
          final nfcF = NfcF.from(tag);
          if (nfcF == null) {
            await finish(const IcCardResult(
              IcReadStatus.readError,
              message: 'NFC-F(FeliCa) カードではありません',
            ));
            return;
          }
          String? idmHex;
          try {
            idmHex = _toHex(nfcF.identifier);
          } catch (_) {
            idmHex = null;
          }
          try {
            int? balance;
            List<IcCardHistoryEntry> history = const [];
            String? detail;

            try {
              history = await _readHistoryWithRawCommand(nfcF, blockCount: 20);
              if (history.isNotEmpty) {
                balance = history.first.balanceYen;
              }
            } catch (e) {
              detail = e.toString();
            }
            if (balance == null) {
              try {
                history =
                    await _readHistoryWithRawCommand(nfcF, blockCount: 10);
                if (history.isNotEmpty) {
                  balance = history.first.balanceYen;
                }
              } catch (e) {
                detail ??= e.toString();
              }
            }
            if (balance == null) {
              try {
                balance = await _readBalanceWithRawCommand(nfcF);
              } catch (e) {
                detail ??= e.toString();
              }
            }

            if (balance == null) {
              await finish(IcCardResult(
                IcReadStatus.readError,
                idm: idmHex,
                message: detail == null || detail.isEmpty
                    ? '残高を読み取れませんでした (交通系カードではない可能性)'
                    : '残高を読み取れませんでした: $detail',
              ));
              return;
            }

            await finish(IcCardResult(
              IcReadStatus.success,
              balanceYen: balance,
              idm: idmHex,
              history: history,
            ));
          } catch (e) {
            await finish(IcCardResult(
              IcReadStatus.readError,
              idm: idmHex,
              message: '読み取りエラー: $e',
            ));
          }
        },
      );
    } catch (e) {
      await finish(IcCardResult(
        IcReadStatus.readError,
        message: 'NFC セッションを開始できませんでした: $e',
      ));
      return completer.future;
    }

    timer = Timer(timeout, () {
      finish(const IcCardResult(IcReadStatus.timeout));
    });

    return completer.future;
  }

  static Future<List<IcCardHistoryEntry>> _readHistoryWithRawCommand(
    NfcF nfcF, {
    int blockCount = 20,
  }) async {
    final idm = nfcF.identifier;
    if (idm.length != 8) {
      throw Exception('IDm が取得できませんでした');
    }

    final blocksToRead = blockCount.clamp(1, 20).toInt();
    final command = BytesBuilder(copy: false)
      ..addByte(13 + blocksToRead * 2)
      ..addByte(0x06)
      ..add(idm)
      ..addByte(0x01)
      ..add(_suicaHistoryService)
      ..addByte(blocksToRead);
    for (int i = 0; i < blocksToRead; i++) {
      command
        ..addByte(0x80)
        ..addByte(i);
    }

    final response = await nfcF.transceive(data: command.toBytes());
    if (response.length < 13 || response[1] != 0x07) {
      throw Exception('FeliCa raw response が想定外です');
    }
    final statusFlag1 = response[10];
    final statusFlag2 = response[11];
    if (statusFlag1 != 0 || statusFlag2 != 0) {
      throw Exception('FeliCa raw status=$statusFlag1/$statusFlag2');
    }

    final responseBlockCount = response[12];
    final readableBlockCount =
        responseBlockCount < blocksToRead ? responseBlockCount : blocksToRead;
    if (readableBlockCount < 1 ||
        response.length < 13 + readableBlockCount * 16) {
      throw Exception('FeliCa raw block が空です');
    }

    final parsed = <IcCardHistoryEntry>[];
    for (int i = 0; i < readableBlockCount; i++) {
      final offset = 13 + i * 16;
      final block = Uint8List.fromList(response.sublist(offset, offset + 16));
      if (block.every((b) => b == 0)) continue;
      parsed.add(_parseHistoryBlock(block));
    }

    return [
      for (int i = 0; i < parsed.length; i++)
        parsed[i].withAmount(
          i + 1 < parsed.length
              ? parsed[i].balanceYen - parsed[i + 1].balanceYen
              : null,
        )
    ];
  }

  static Future<int?> _readBalanceWithRawCommand(NfcF nfcF) async {
    final idm = nfcF.identifier;
    if (idm.length != 8) {
      throw Exception('IDm が取得できませんでした');
    }

    final command = BytesBuilder(copy: false)
      ..addByte(0x0F)
      ..addByte(0x06)
      ..add(idm)
      ..addByte(0x01)
      ..add(_suicaHistoryService)
      ..addByte(0x01)
      ..add(_latestBlock);
    final response = await nfcF.transceive(data: command.toBytes());
    if (response.length < 13 || response[1] != 0x07) {
      throw Exception('FeliCa raw response が想定外です');
    }
    final statusFlag1 = response[10];
    final statusFlag2 = response[11];
    if (statusFlag1 != 0 || statusFlag2 != 0) {
      throw Exception('FeliCa raw status=$statusFlag1/$statusFlag2');
    }
    final blockCount = response[12];
    if (blockCount < 1 || response.length < 13 + 16) {
      throw Exception('FeliCa raw block が空です');
    }
    return _balanceFromHistoryBlock(response.sublist(13, 29));
  }

  static IcCardHistoryEntry _parseHistoryBlock(Uint8List block) {
    if (block.length < 16) {
      throw Exception('履歴データの形式が想定外です');
    }
    return IcCardHistoryEntry(
      date: _parseHistoryDate(block[4], block[5]),
      terminalCode: block[0],
      processCode: block[1],
      inLineCode: block[6],
      inStationCode: block[7],
      outLineCode: block[8],
      outStationCode: block[9],
      balanceYen: _balanceFromHistoryBlock(block),
      sequenceNumber: block[12] | (block[13] << 8) | (block[14] << 16),
      rawBlock: block,
    );
  }

  static DateTime? _parseHistoryDate(int high, int low) {
    final year = 2000 + ((high & 0xFE) >> 1);
    final month = ((high & 0x01) << 3) | ((low & 0xE0) >> 5);
    final day = low & 0x1F;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    try {
      return DateTime(year, month, day);
    } catch (_) {
      return null;
    }
  }

  static int _balanceFromHistoryBlock(Uint8List block) {
    if (block.length < 12) {
      throw Exception('残高データの形式が想定外です');
    }
    return block[10] | (block[11] << 8);
  }

  /// 進行中の NFC セッションを停止する (ダイアログを閉じたとき等)。
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {}
  }

  static String _toHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
    return sb.toString();
  }
}
