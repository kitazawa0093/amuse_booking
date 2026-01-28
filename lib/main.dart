import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_stripe/flutter_stripe.dart';

import 'package:amuse_booking/screens/reservation_board_screen.dart';
// ↑ フォルダが screens の場合は screen → screens に変更

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // =========================
  // ★ 画面を横向きに固定 ★
  // =========================
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // （任意）業務端末っぽくしたい場合はUI非表示
  // SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // =========================
  // Firebase 初期化
  // =========================
  await Firebase.initializeApp();

  // =========================
  // Stripe 初期化
  // =========================
  Stripe.publishableKey =
      'pk_test_51SN9S71rWFNVgrh2g2BNuUrJ4fU6n3LRU1bbVb4k8moH6bRvns6Yka6kLxRXZGNHaBMairjmrp2PwzhVVu62Hcre00X4P4zHOU';
  await Stripe.instance.applySettings();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Amuse Booking',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),

      // =========================
      // ★ 起動したら即予約ボード ★
      // =========================
      home: ReservationBoardScreen(),
    );
  }
}
