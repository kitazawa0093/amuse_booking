import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'login_screen.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:async';  // ←ファイル先頭に追加（Timer使うため）





String _formatTime(DateTime time) {
  return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
}

class BookingScreen extends StatefulWidget {
  const BookingScreen({super.key});

  @override
  State<BookingScreen> createState() => _BookingScreenState();
}



class _BookingScreenState extends State<BookingScreen> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final TextEditingController _beerPongPeopleController = TextEditingController();

  Timer? _refreshTimer; // ←ここ
  
  bool _notifiedStart5MinBefore = false;
  bool _isPaying = false;
  bool _hasActiveReservation = false;
  Future<String> _myBeerpongStatusFuture = Future.value('');
  Future<String> _shopNextSlotFuture = Future.value('');

  @override
  void initState() {
  super.initState();
  _refreshFutures();

  _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
    _refreshFutures();
  });
  
}
void _refreshFutures() async {
  _myBeerpongStatusFuture = getMyBeerpongStatusText();
  _shopNextSlotFuture = getShopNextBeerpongSlotText();
  setState(() {});
  await _checkStart5MinBeforeNotification();
}

Future<void> _checkStart5MinBeforeNotification() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final now = DateTime.now();

  final snap = await _firestore
      .collection('bookings')
      .where('type', isEqualTo: 'beerpong')
      .where('uid', isEqualTo: user.uid)
      .where('paymentStatus', isEqualTo: 'paid')
      .where('startAt', isGreaterThan: Timestamp.fromDate(now))
      .orderBy('startAt')
      .limit(1)
      .get();

  if (snap.docs.isEmpty) {
    _notifiedStart5MinBefore = false; // 次の予約のためリセット
    return;
  }

  final startAt = (snap.docs.first['startAt'] as Timestamp).toDate();
  final remainingSeconds = startAt.difference(now).inSeconds;

  // ✅ 5分切ったら一回だけ通知
  if (!_notifiedStart5MinBefore &&
      remainingSeconds <= 300 &&
      remainingSeconds > 0) {

    _notifiedStart5MinBefore = true;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🍺 もうすぐビアポン開始です！（5分前）'),
        duration: Duration(seconds: 5),
      ),
    );
  }
}


Future<String> getMyBeerpongStatusText() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    _hasActiveReservation = false;
    return '';
  }

  final now = DateTime.now();

  // ✅ 15時リセット（15:00以降は当日終了表示もしない）
  final resetTime = DateTime(now.year, now.month, now.day, 15, 0);
  final isAfterReset = now.isAfter(resetTime);

  // ① 利用中（endAt > now）
  final activeSnap = await _firestore
      .collection('bookings')
      .where('type', isEqualTo: 'beerpong')
      .where('uid', isEqualTo: user.uid)
      .where('paymentStatus', isEqualTo: 'paid')
      .where('endAt', isGreaterThan: Timestamp.fromDate(now))
      .orderBy('endAt', descending: false)
      .limit(1)
      .get();

  if (activeSnap.docs.isNotEmpty) {
    final doc = activeSnap.docs.first;
    final startAt = (doc['startAt'] as Timestamp).toDate();
    final endAt = (doc['endAt'] as Timestamp).toDate();

    _hasActiveReservation = true;
    return '✅ 決済ありがとうございます。\n${_formatTime(startAt)}〜${_formatTime(endAt)} 利用できます';
  }

  // ② 15:00以降ならリセット（当日終了表示しない）
  if (isAfterReset) {
    _hasActiveReservation = false;
    return '⚠️ あなたはまだ決済していません';
  }

  // ③ 当日分の「終了した予約」があるか確認
  final dayStart = DateTime(now.year, now.month, now.day, 0, 0, 0);
  final dayEnd = DateTime(now.year, now.month, now.day, 23, 59, 59);

  final todaySnap = await _firestore
      .collection('bookings')
      .where('type', isEqualTo: 'beerpong')
      .where('uid', isEqualTo: user.uid)
      .where('paymentStatus', isEqualTo: 'paid')
      .where('endAt', isGreaterThanOrEqualTo: Timestamp.fromDate(dayStart))
      .where('endAt', isLessThanOrEqualTo: Timestamp.fromDate(dayEnd))
      .orderBy('endAt', descending: true)
      .limit(1)
      .get();

  if (todaySnap.docs.isNotEmpty) {
    _hasActiveReservation = false;
    return '🙏 ご利用ありがとうございました。（本日分）';
  }

  _hasActiveReservation = false;
  return '⚠️ あなたはまだ決済していません';
}



Future<String> getShopNextBeerpongSlotText() async {
  final firestore = FirebaseFirestore.instance;

  final now = DateTime.now();

  final snapshot = await firestore
      .collection('bookings')
      .where('type', isEqualTo: 'beerpong')
      .where('paymentStatus', isEqualTo: 'paid')
      .orderBy('endAt', descending: true)
      .limit(1)
      .get();

  DateTime start;
  if (snapshot.docs.isEmpty) {
    start = now;
  } else {
    final lastEnd = (snapshot.docs.first['endAt'] as Timestamp).toDate();
    start = lastEnd.isBefore(now) ? now : lastEnd;
  }

  final end = start.add(const Duration(minutes: 30));
  return '🏪 店の次の空き：${_formatTime(start)}〜${_formatTime(end)}';
}

  // ===== ログアウト =====
  Future<void> _logout() async {
    await FirebaseAuth.instance.signOut();
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
  }

  // ===== 次に使えるビアポン時間 =====
  


Future<void> _submitBeerPongReservation() async {
  if (_isPaying) return;

  setState(() {
    _isPaying = true;
  });

  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    setState(() {
      _isPaying = false;
    });
    return;
  }

  DocumentReference? bookingRef;

  try {
    // ① 仮予約（unpaid）
    bookingRef = await _firestore.collection('bookings').add({
      'type': 'beerpong',
      'uid': user.uid,
      'paymentStatus': 'unpaid',
      'createdAt': FieldValue.serverTimestamp(),
    });

    // ② Cloud Functions 呼び出し（PaymentIntent 作成）
    final callable =
        FirebaseFunctions.instance.httpsCallable('createBeerpongPayment');

    final peopleCount = int.tryParse(_beerPongPeopleController.text) ?? 1;

    final result = await callable.call({
      'peopleCount': peopleCount,
    });

    final clientSecret = result.data['clientSecret'];
    debugPrint('Stripe clientSecret: $clientSecret');

    // ★ Stripeの内部キャッシュを完全リセット
    await Stripe.instance.resetPaymentSheetCustomer();

    // ③ Stripe PaymentSheet 初期化
    await Stripe.instance.initPaymentSheet(
      paymentSheetParameters: SetupPaymentSheetParameters(
        paymentIntentClientSecret: clientSecret,
        merchantDisplayName: 'Amuse Booking',
      ),
    );

    // ④ Stripe PaymentSheet 表示（ここでユーザー決済）
    await Stripe.instance.presentPaymentSheet();

    // ⑤ 利用時間計算（店全体の最後の予約から積み上げ）
    final now = DateTime.now();

    final lastSnapshot = await _firestore
        .collection('bookings')
        .where('type', isEqualTo: 'beerpong')
        .where('paymentStatus', isEqualTo: 'paid')
        .orderBy('endAt', descending: true)
        .limit(1)
        .get();

    DateTime startAt = now;
    if (lastSnapshot.docs.isNotEmpty) {
      final lastEnd = (lastSnapshot.docs.first['endAt'] as Timestamp).toDate();
      if (lastEnd.isAfter(now)) startAt = lastEnd;
    }

    final endAt = startAt.add(const Duration(minutes: 30));

    // ⑥ paid に更新
    await bookingRef.update({
      'paymentStatus': 'paid',
      'startAt': startAt,
      'endAt': endAt,
      'paidAt': FieldValue.serverTimestamp(),
      'peopleCount': peopleCount, // ←残しておくと便利
    });
    await Future.delayed(const Duration(milliseconds: 200));

    // ✅ ここが重要：Future を更新してUI再描画
    _hasActiveReservation = true;
    _myBeerpongStatusFuture = getMyBeerpongStatusText();
    _shopNextSlotFuture = getShopNextBeerpongSlotText();

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('決済が完了しました！')),
    );
  } catch (e, st) {
    debugPrint('決済エラー: $e');
    debugPrintStack(stackTrace: st);

    // 失敗したら cancelled に更新（仮予約のゴミを残さない）
    if (bookingRef != null) {
      await bookingRef.update({
        'paymentStatus': 'cancelled',
        'cancelledAt': FieldValue.serverTimestamp(),
      });
    }

    // （任意）失敗後も表示更新したい場合
    _myBeerpongStatusFuture = getMyBeerpongStatusText();
    _shopNextSlotFuture = getShopNextBeerpongSlotText();

    setState(() {});

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('決済エラー: $e')),
    );
  } finally {
    setState(() {
      _isPaying = false;
    });
  }
}



  // ===== ダーツ予約 =====
  Future<void> _submitDartsReservation() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    await _firestore.collection('bookings').add({
      'type': 'darts',
      'uid': user.uid,
      'createdAt': FieldValue.serverTimestamp(),
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('ダーツ予約を保存しました')),
    );
  }

  Stream<int> _getWaitingCount(String type) {
  var query = _firestore
      .collection('bookings')
      .where('type', isEqualTo: type);

  if (type == 'beerpong') {
    query = query
        .where('paymentStatus', isEqualTo: 'paid')
        .where('endAt', isGreaterThan: Timestamp.now());
  }

  return query.snapshots().map((s) => s.docs.length);
}



  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('予約メニュー'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: _logout,
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '🍺 ビアポン予約',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            StreamBuilder<int>(
              stream: _getWaitingCount('beerpong'),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Text('❌ エラー: ${snapshot.error}');
                }
                if (!snapshot.hasData) return const Text('読み込み中...');
                return Text('現在の待ち組数: ${snapshot.data} 組');
              },
            ),


            const SizedBox(height: 4),



            // ✅ 自分の決済状況
            FutureBuilder<String>(
              future: _myBeerpongStatusFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Text('あなたの決済状況を確認中...');
                }

                final text = snapshot.data ?? '';
                final active = text.startsWith('✅');

                return Text(
                  text,
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: active ? Colors.green : Colors.orange,
                  ),
                );
              },
            ),


            const SizedBox(height: 6),

            // ✅ 店全体の次の空き枠
            FutureBuilder<String>(
              future: _shopNextSlotFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Text('店の空き時間を計算中...');
                }

                final text = snapshot.data ?? '';
                return Text(
                  text,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.blue,
                  ),
                );
              },
            ),


            const SizedBox(height: 8),
            TextField(
              controller: _beerPongPeopleController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '人数を入力'),
            ),
            const SizedBox(height: 8),

            ElevatedButton(
              onPressed: (_isPaying || _hasActiveReservation)
                ? null
                : _submitBeerPongReservation,
              child: _isPaying
                ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_hasActiveReservation ? '利用中です' : 'ビアポンを予約する'),
            ),

            const Divider(height: 40),

            const Text(
              '🎯 ダーツ予約',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            StreamBuilder<int>(
              stream: _getWaitingCount('darts'),
              builder: (context, snapshot) {
                if (!snapshot.hasData) return const Text('読み込み中...');
                return Text('現在の待ち組数: ${snapshot.data} 組');
              },
            ),

            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _submitDartsReservation,
              child: const Text('ダーツを予約する'),
            ),
          ],
        ),
      ),

    );
  }
  @override
  void dispose() {
  _refreshTimer?.cancel();
  _beerPongPeopleController.dispose();
  super.dispose();
  }
}

