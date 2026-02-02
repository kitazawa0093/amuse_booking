import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';





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
  late Map<String, List<Reservation>> reservations;
  StreamSubscription<QuerySnapshot>? _bookingSub;


  // ===== 種目 =====
  final List<String> sports = const [
    'サイバープレイヤーズ',
    'ビアポン',
    'ダーツ１F',
    'ダーツ２F',
  ];
  @override
  void initState() {
    super.initState();

    reservations = {for (final s in sports) s: []};

    // ===== 営業日ロジック（13時リセット）=====
    final now = DateTime.now();
    final today13 = DateTime(now.year, now.month, now.day, 13);

    final businessStart = now.isBefore(today13)
        ? today13.subtract(const Duration(days: 1))
        : today13;

    final businessEnd = businessStart.add(const Duration(days: 1));

    // ===== Firestoreリアルタイム監視 =====
    _bookingSub = FirebaseFirestore.instance
        .collection('bookings')
        .where('type', isEqualTo: 'beerpong')
        .where('paymentStatus', whereIn: ['paid', 'pending'])
        .where('startAt',
            isGreaterThanOrEqualTo: Timestamp.fromDate(businessStart))
        .where('startAt', isLessThan: Timestamp.fromDate(businessEnd))
        .snapshots()
        .listen((snapshot) {
      final list = <Reservation>[];

      for (final doc in snapshot.docs) {
        final s = (doc['startAt'] as Timestamp).toDate();
        final e = (doc['endAt'] as Timestamp).toDate();

        list.add(
          Reservation(
            name: doc['name'],
            start: TimeOfDay(hour: s.hour, minute: s.minute),
            end: TimeOfDay(hour: e.hour, minute: e.minute),
          ),
        );
      }

      if (mounted) {
        setState(() {
          reservations['ビアポン'] = list;
        });
      }
    });
  }
  @override
  void dispose() {
    _bookingSub?.cancel();
    super.dispose();
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
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const Text('予約入力',
                  style: TextStyle(fontWeight: FontWeight.bold)),

              const SizedBox(height: 20),
              const Text('お名前を入力してください',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),

              const SizedBox(height: 16),
              _highlightNameField(nameCtrl),

              const SizedBox(height: 16),
              SizedBox(
                height: 140,
                child: CupertinoTimerPicker(
                  mode: CupertinoTimerPickerMode.hm,
                  minuteInterval: 1,
                  initialTimerDuration: selected,
                  onTimerDurationChanged: (d) => selected = d,
                ),
              ),

              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.all(8),
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('予約する（30分）'),
                ),
              ),
              const SizedBox(height: 12),
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

 Future<bool> _startStripePayment({
  required int people,
  required String bookingId,
}) async {
  try {
    final functions = FirebaseFunctions.instance;

    final result = await functions
        .httpsCallable('createBeerpongPayment')
        .call({
          'peopleCount': people,
          'bookingId': bookingId,
        });

    final clientSecret = result.data['clientSecret'];

    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: 'Beer Pong Reservation',
      ),
    );

    await Stripe.instance.presentPaymentSheet();

    // 🔥 支払い確定をサーバーに通知
    await functions.httpsCallable('confirmStripePayment').call({
      'bookingId': bookingId,
      'paymentIntentId': result.data['paymentIntentId'],
    });

    return true;
  } catch (e) {
    debugPrint('Stripe payment error: $e');
    return false;
  }
}

Future<bool> _startPayPayPayment({
  required int people,
  required String bookingId,
  }) async {
    try {
      final functions = FirebaseFunctions.instance;

      final result = await functions
          .httpsCallable('createPayPayPayment')
          .call({
            'amount': people * 700,
            'orderId': bookingId,
          });

      final paymentUrl = result.data['url'] as String;
      await launchUrl(Uri.parse(paymentUrl),
          mode: LaunchMode.externalApplication);

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('PayPay決済'),
          content: const Text('決済完了後「完了」を押してください'),
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

      if (confirmed != true) return false;

      // 🔥 サーバーで支払い確認
      await functions
          .httpsCallable('confirmPayPayPayment')
          .call({'orderId': bookingId});

      return true;
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
  var paymentMethod = 'card';

  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (context, setLocalState) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
             mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              const Text('ビアポン予約',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              const Text('お名前',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              _highlightNameField(nameCtrl),

              SizedBox(
                height: 140,
                child: CupertinoTimerPicker(
                  mode: CupertinoTimerPickerMode.hm,
                  minuteInterval: 1,
                  initialTimerDuration: selected,
                  onTimerDurationChanged: (d) => selected = d,
                ),
              ),
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
                  Text('$people 人',
                      style: const TextStyle(
                          fontSize: 22, fontWeight: FontWeight.bold)),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () => setLocalState(() => people++),
                  ),
                ],
              ),
              Text('合計 ¥${people * 700}',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('カード'),
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

  // ===== 時間計算 =====
  final start = TimeOfDay(
    hour: selected.inHours,
    minute: selected.inMinutes % 60,
  );
  final endMinutes = selected.inMinutes + 30;
  final end = TimeOfDay(
    hour: endMinutes ~/ 60,
    minute: endMinutes % 60,
  );

  // ローカル重複チェック
  if (_isOverlapping('ビアポン', start, end)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('その時間帯は既に予約があります')),
    );
    return;
  }

  // ===== 他端末予約チェック（Firestore）=====
  // 🔥 まず時間を作る
  final now = DateTime.now();
  final bookingStart = DateTime(
    now.year,
    now.month,
    now.day,
    start.hour,
    start.minute,
  );
  final bookingEnd = bookingStart.add(const Duration(minutes: 30));

  // 🔥 そのあとクエリ
  final snap = await FirebaseFirestore.instance
      .collection('bookings')
      .where('type', isEqualTo: 'beerpong')
      .where('paymentStatus', whereIn: ['paid', 'pending'])
      .where(
        'startAt',
        isGreaterThanOrEqualTo:
            Timestamp.fromDate(bookingStart.subtract(const Duration(hours: 1))),
      )
      .where(
        'startAt',
        isLessThan:
            Timestamp.fromDate(bookingEnd.add(const Duration(hours: 1))),
      )
      .get();



  for (final doc in snap.docs) {
    final s = (doc['startAt'] as Timestamp).toDate();
    final e = (doc['endAt'] as Timestamp).toDate();

    if (bookingStart.isBefore(e) && bookingEnd.isAfter(s)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('他の端末で予約が入りました')),
      );
      return;
    }
  }

  // ===== Firestore 仮予約作成 =====
  final user = FirebaseAuth.instance.currentUser!;
  final bookingRef = FirebaseFirestore.instance.collection('bookings').doc();

  await bookingRef.set({
    'uid': user.uid,
    'type': 'beerpong',
    'people': people,
    'name': nameCtrl.text.trim(),
    'paymentStatus': 'pending',
    'startAt': Timestamp.fromDate(bookingStart),
    'endAt': Timestamp.fromDate(bookingEnd),   // ← 追加
    'createdAt': FieldValue.serverTimestamp(),
  });


  // ===== 決済開始 =====
  bool paymentOk = false;
  if (paymentMethod == 'paypay') {
    paymentOk =
        await _startPayPayPayment(people: people, bookingId: bookingRef.id);
  } else {
    paymentOk =
        await _startStripePayment(people: people, bookingId: bookingRef.id);
  }

  // ❌ 決済失敗 → 予約削除
  if (!paymentOk) {
    await bookingRef.delete();
    return;
  }

  // ✅ 決済成功 → 予約確定
  await bookingRef.update({
    'paymentStatus': 'paid',
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
