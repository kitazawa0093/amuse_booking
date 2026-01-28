import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_stripe/flutter_stripe.dart';


class Reservation {
  final String name;
  final TimeOfDay start;
  final TimeOfDay end;

  Reservation({
    required this.name,
    required this.start,
    required this.end,
  });
}

class ReservationBoardScreen extends StatefulWidget {
  const ReservationBoardScreen({super.key});

  @override
  State<ReservationBoardScreen> createState() =>
      _ReservationBoardScreenState();
}

class _ReservationBoardScreenState extends State<ReservationBoardScreen> {
  // ===== 表示設定 =====
  static const double rowHeight = 54;
  static const double leftColWidth = 220;
  static const double cellWidth = 60; // 10分 = 60px

  final int startHour = 18;
  final int endHour = 23;

  // ===== 種目 =====
  final List<String> sports = const [
    'サイバープレイヤーズ',
    'ビアポン',
    'ダーツ１F',
    'ダーツ２F',
  ];

  late final Map<String, List<Reservation>> reservations;


  @override
  void initState() {
    super.initState();
    reservations = {for (final s in sports) s: []};
  }

  // ===== 分 → px =====
  double _minuteToPx(int minuteFromStart) {
    return minuteFromStart / 10 * cellWidth;
  }

  int _toMinute(TimeOfDay t) => (t.hour - startHour) * 60 + t.minute;

  // ===== 予約追加 =====
  Future<void> _addReservation(String sport) async {
    Duration selected = const Duration(hours: 18);

    final nameCtrl = TextEditingController();

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: 360,
          child: Column(
            children: [
              const SizedBox(height: 12),
              const Text('予約入力', style: TextStyle(fontWeight: FontWeight.bold)),

              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'お名前を入力してください',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 16),

      // ===== 強調された名前入力 =====
                    Container(
                      width: MediaQuery.of(context).size.width * 0.8,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      child: TextField(
                        controller: nameCtrl,
                        autofocus: true,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          hintText: '例）田中',
                        ),
                      ),
                    ),

                    const SizedBox(height: 12),
                    const Text(
                      '※ 予約バーに表示されます',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: CupertinoTimerPicker(
                  mode: CupertinoTimerPickerMode.hm,
                  minuteInterval: 1,
                  initialTimerDuration: selected,
                  onTimerDurationChanged: (d) => selected = d,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('予約する（30分）'),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (ok != true || nameCtrl.text.trim().isEmpty) return;

    final start = TimeOfDay(
      hour: selected.inHours,
      minute: selected.inMinutes % 60,
    );
    final endMinutes = selected.inMinutes + 30;
    final defaultEnd = TimeOfDay(
      hour: endMinutes ~/ 60,
      minute: endMinutes % 60,
    );

    final adjustedEnd = _adjustEndTime(sport, start, defaultEnd);

    // 調整後の長さが0以下なら予約不可
    if (_absMinute(adjustedEnd) - _absMinute(start) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('その時間帯は予約が埋まっています')),
      );
      return;
    }

    // ★ 重複チェック
    if (_isOverlapping(sport, start, adjustedEnd)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('その時間帯は既に予約があります')),
      );
      return;
    }
    setState(() {
      reservations[sport]!.add(
        Reservation(
          name: nameCtrl.text.trim(),
          start: start,
          end: adjustedEnd,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('予約ボード')),
      body: SafeArea(
        child: Row(
          children: [
            // ===== 左固定 =====
            SizedBox(
              width: leftColWidth,
              child: Column(
                children: [
                  _leftHeader(),
                  for (final s in sports) _leftRow(s),
                ],
              ),
            ),

            // ===== 右：時間軸 =====
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: (endHour - startHour) * 6 * cellWidth,
                  child: Column(
                    children: [
                      _timeHeader(),
                      for (final s in sports) _timeRow(s),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _startStripePayment({required int people}) async {
    try {
      final functions = FirebaseFunctions.instance;

      final result = await functions
          .httpsCallable('createBeerpongPayment')
          .call({
            'peopleCount': people,
          });

      final clientSecret = result.data['clientSecret'];

      await Stripe.instance.initPaymentSheet(
        paymentSheetParameters: SetupPaymentSheetParameters(
          paymentIntentClientSecret: clientSecret,
          merchantDisplayName: 'Beer Pong Reservation',
        ),
      );

      await Stripe.instance.presentPaymentSheet();
      return true;
    } catch (e) {
      debugPrint('Stripe payment error: $e');
      return false;
    }
  }

  Future<bool> _startPayPayPayment({required int people}) async {
    try {
      final functions = FirebaseFunctions.instance;

      final result = await functions
          .httpsCallable('createBeerpongPayPayPayment')
          .call({
            'peopleCount': people,
          });

      final paymentUrl = result.data['paymentUrl'] as String?;
      if (paymentUrl == null || paymentUrl.isEmpty) {
        throw Exception('PayPay paymentUrl is missing');
      }

      final uri = Uri.parse(paymentUrl);
      final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!launched) return false;

      if (!mounted) return false;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('PayPay決済'),
          content: const Text('PayPayでの決済が完了したら「完了」を押してください。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('完了'),
            ),
          ],
        ),
      );
      return confirmed == true;
    } catch (e) {
      debugPrint('PayPay payment error: $e');
      return false;
    }
  }


  // ===== 左 =====
  Widget _leftHeader() {
    return Container(
      height: rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: const Row(
        children: [
          Expanded(child: Text('種目', style: TextStyle(fontWeight: FontWeight.bold))),
          Text('予約'),
        ],
      ),
    );
  }

  Widget _leftRow(String sport) {
    return Container(
      height: rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.black12)),
      ),
      child: Row(
        children: [
          Expanded(child: Text(sport)),
          
          FilledButton(
            onPressed: () {
              if (sport == 'ビアポン') {
                _addBeerPongReservation(); // ★人数＋決済
              } else {
                _addReservation(sport); // ★今まで通り
              }
            },
            child: const Text('予約'),
          ),
        ],
       ),
    );
  }

  // ===== 時間ヘッダー =====
  Widget _timeHeader() {
    return Container(
      height: rowHeight,
      child: Row(
        children: List.generate((endHour - startHour) * 6, (i) {
          final h = startHour + i ~/ 6;
          final m = (i % 6) * 10;
          return Container(
            width: cellWidth,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              border: Border(right: BorderSide(color: Colors.black12)),
            ),
            child: Text(
              '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          );
        }),
      ),
    );
  }

  // ===== バー表示 =====
  Widget _timeRow(String sport) {
  return SizedBox(
    height: rowHeight,
    child: Stack(
      children: [
        // ===== 背景グリッド（罫線）=====
        Row(
          children: List.generate((endHour - startHour) * 6, (i) {
            return Container(
              width: cellWidth,
              height: rowHeight,
              decoration: const BoxDecoration(
                border: Border(
                  right: BorderSide(color: Colors.black12),
                  bottom: BorderSide(color: Colors.black12),
                ),
              ),
            );
          }),
        ),

        // ===== 予約バー =====
        for (final r in reservations[sport]!)
          Positioned(
            left: _minuteToPx(_toMinute(r.start)),
            top: 6,
            bottom: 6,
            width: _minuteToPx(
              _toMinute(r.end) - _toMinute(r.start),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .primary
                    .withOpacity(0.75),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(
                child: Text(
                  '${r.name} ${r.start.format(context)}〜${r.end.format(context)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
  Future<void> _addBeerPongReservation() async {
    Duration selected = const Duration(hours: 18);
    final nameCtrl = TextEditingController();
    int people = 2;
    var paymentMethod = 'card'; // 'card' or 'paypay'

    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (context, setLocalState) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SizedBox(
            height: 440,
            child: Column(
              children: [
                const SizedBox(height: 12),
                const Text(
                  'ビアポン予約',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),

                // ===== 名前（目立つ）=====
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'お名前',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 12),
                      _highlightNameField(nameCtrl),
                    ],
                  ),
                ),

                // ===== 時間スピナー =====
                SizedBox(
                  height: 140,
                  child: CupertinoTimerPicker(
                    mode: CupertinoTimerPickerMode.hm,
                    minuteInterval: 1,
                    initialTimerDuration: selected,
                    onTimerDurationChanged: (d) => selected = d,
                  ),
                ),

                // ===== 人数入力 =====
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: people > 1
                          ? () => setLocalState(() => people--)
                          : null,
                    ),
                    Text(
                      '$people 人',
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => setLocalState(() => people++),
                    ),
                  ],
                ),

                Text(
                  '合計 ¥${people * 700}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 12),
                // ===== 決済方法選択 =====
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ChoiceChip(
                      label: const Text('カード (Stripe)'),
                      selected: paymentMethod == 'card',
                      onSelected: (_) =>
                          setLocalState(() => paymentMethod = 'card'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('PayPay'),
                      selected: paymentMethod == 'paypay',
                      onSelected: (_) =>
                          setLocalState(() => paymentMethod = 'paypay'),
                    ),
                  ],
                ),

                const SizedBox(height: 12),
                FilledButton(
                  onPressed: nameCtrl.text.trim().isEmpty
                      ? null
                      : () => Navigator.pop(context, true),
                  child: const Text('決済へ進む'),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );

    if (ok != true) return;

    final start = TimeOfDay(
      hour: selected.inHours,
      minute: selected.inMinutes % 60,
    );
    final endMinutes = selected.inMinutes + 30;
    final defaultEnd = TimeOfDay(
      hour: endMinutes ~/ 60,
      minute: endMinutes % 60,
    );

    final adjustedEnd = _adjustEndTime('ビアポン', start, defaultEnd);

    // 調整後の長さが0以下なら予約不可
    if (_absMinute(adjustedEnd) - _absMinute(start) <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('その時間帯は予約が埋まっています')),
      );
      return;
    }

    bool paymentOk = false;
    if (paymentMethod == 'paypay') {
      paymentOk = await _startPayPayPayment(people: people);
    } else {
      paymentOk = await _startStripePayment(people: people);
    }

    if (!paymentOk) return;

    // ★ 重複チェック
    if (_isOverlapping('ビアポン', start, adjustedEnd)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('その時間帯は既に予約があります')),
      );
      return;
    }

    setState(() {
      reservations['ビアポン']!.add(
        Reservation(
          name: '${nameCtrl.text}（$people人）',
          start: start,
          end: adjustedEnd,
        ),
      );
    });
  }
  Widget _highlightNameField(TextEditingController controller) {
    return Container(
      width: MediaQuery.of(context).size.width * 0.8,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      child: TextField(
        controller: controller,
        autofocus: true,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          hintText: '例）田中',
        ),
      ),
    );
  }
  bool _isOverlapping(String sport, TimeOfDay newStart, TimeOfDay newEnd) {
    final list = reservations[sport]!;

    final ns = _absMinute(newStart);
    final ne = _absMinute(newEnd);

    for (final r in list) {
      final es = _absMinute(r.start);
      final ee = _absMinute(r.end);

      // 時間帯が重なったら予約不可
      if (ns < ee && ne > es) {
        return true;
      }
    }
    return false;
  }

  // ===== ヘルパー: 時刻計算 =====
  int _absMinute(TimeOfDay t) => t.hour * 60 + t.minute;

  TimeOfDay _fromAbsMinute(int totalMinutes) {
    return TimeOfDay(
      hour: totalMinutes ~/ 60,
      minute: totalMinutes % 60,
    );
  }

  /// 30分デフォルト終了時刻を、次の予約開始までに収まるように短縮
  TimeOfDay _adjustEndTime(
    String sport,
    TimeOfDay start,
    TimeOfDay defaultEnd,
  ) {
    final startMin = _absMinute(start);
    final defaultEndMin = _absMinute(defaultEnd);
    final nextStartMin = _findNextReservationStart(sport, startMin);

    if (nextStartMin != null && nextStartMin < defaultEndMin) {
      // 次の予約が30分以内にあるので、そこまでで切る
      return _fromAbsMinute(nextStartMin);
    }
    return defaultEnd;
  }

  /// 指定種目の中で、startMin 以降の最も近い予約開始を返す
  int? _findNextReservationStart(String sport, int startMin) {
    int? nearest;
    for (final r in reservations[sport]!) {
      final rStart = _absMinute(r.start);
      if (rStart >= startMin) {
        if (nearest == null || rStart < nearest) {
          nearest = rStart;
        }
      }
    }
    return nearest;
  }


}
