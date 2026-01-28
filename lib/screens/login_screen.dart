import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'booking_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  // ✅ 新規登録時に使う
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _contactController = TextEditingController();

  bool _isLogin = true; // true:ログイン false:新規登録
  bool _isLoading = false;

  bool _validateInput() {
    if (_emailController.text.trim().isEmpty ||
        _passwordController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('メールとパスワードを入力してください')),
      );
      return false;
    }

    // ✅ 新規登録のときだけチェック
    if (!_isLogin) {
      if (_nameController.text.trim().isEmpty ||
          _contactController.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('名前と連絡先を入力してください')),
        );
        return false;
      }
    }

    return true;
  }

  Future<void> _submit() async {
    if (!_validateInput()) return;

    setState(() => _isLoading = true);

    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();
    final contact = _contactController.text.trim();

    try {
      if (_isLogin) {
        // =========================
        // ✅ ログイン
        // =========================
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: email,
          password: password,
        );

        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const BookingScreen()),
        );
      } else {
        // =========================
        // ✅ 新規登録(Auth)
        // =========================
        final credential =
            await FirebaseAuth.instance.createUserWithEmailAndPassword(
          email: email,
          password: password,
        );

        final user = credential.user;
        if (user == null) {
          throw Exception('ユーザー作成に失敗しました');
        }

        // =========================
        // ✅ Firestore に名前と連絡先を保存
        // users/{uid}
        // =========================
        await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
          'uid': user.uid,
          'email': email,
          'name': name,
          'contact': contact,
          'createdAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登録が完了しました！')),
        );

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const BookingScreen()),
        );
      }
    } on FirebaseAuthException catch (e) {
      String message = 'エラーが発生しました';

      if (e.code == 'user-not-found') {
        message = 'ユーザーが見つかりません';
      } else if (e.code == 'wrong-password') {
        message = 'パスワードが違います';
      } else if (e.code == 'email-already-in-use') {
        message = 'このメールアドレスはすでに登録されています';
      } else if (e.code == 'invalid-email') {
        message = 'メールアドレスの形式が正しくありません';
      } else if (e.code == 'weak-password') {
        message = 'パスワードが短すぎます（6文字以上推奨）';
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラー: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    _contactController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isLogin ? 'ログイン' : '新規登録')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // ✅ 新規登録時のみ表示
            if (!_isLogin) ...[
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: '名前',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contactController,
                decoration: const InputDecoration(
                  labelText: '連絡先（電話番号など）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
            ],

            TextField(
              controller: _emailController,
              decoration: const InputDecoration(
                labelText: 'メールアドレス',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),

            TextField(
              controller: _passwordController,
              decoration: const InputDecoration(
                labelText: 'パスワード',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isLoading ? null : _submit,
                child: _isLoading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(_isLogin ? 'ログイン' : '登録'),
              ),
            ),

            const SizedBox(height: 12),

            TextButton(
              onPressed: _isLoading
                  ? null
                  : () {
                      setState(() {
                        _isLogin = !_isLogin;
                      });
                    },
              child: Text(_isLogin
                  ? 'アカウントをお持ちでない方はこちら（新規登録）'
                  : 'すでにアカウントをお持ちの方はこちら（ログイン）'),
            ),
          ],
        ),
      ),
    );
  }
}
