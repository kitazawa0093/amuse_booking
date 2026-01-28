import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

    Future<void> _register() async {
    print('1');
    // 1. 入力されたメールアドレスとパスワードを取得
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    print('登録開始: $email / $password');
    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      print('登録成功！');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('登録成功！')),
      );
      Navigator.pop(context);
    } catch (e) {
      print('登録エラー: $e'); // 👈 ここ重要
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('登録失敗: $e')),
      );
    }
}


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ユーザー登録')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _emailController,
              decoration: const InputDecoration(labelText: 'メールアドレス'),
              keyboardType: TextInputType.emailAddress,
            ),
            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(labelText: 'パスワード'),
              obscureText: true,
            ),
            const SizedBox(height: 20),
            ElevatedButton(
                onPressed: () {
                    print('ボタン押された！');
                    _register();
                },
            child: const Text('登録'),
            ),
          ],
        ),
      ),
    );
  }
}

