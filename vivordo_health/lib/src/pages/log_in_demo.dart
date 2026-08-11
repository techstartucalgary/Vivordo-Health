import 'package:flutter/material.dart';
import 'package:vivordo_health/src/pages/home_demo.dart';
import 'package:vivordo_health/src/services/auth_service.dart';

class LoginDemo extends StatefulWidget {
  const LoginDemo({super.key});

  @override
  LoginDemoState createState() => LoginDemoState();
}

class LoginDemoState extends State<LoginDemo> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: const Text("Login Demo")),
      body: SingleChildScrollView(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 110.0),
              child: Center(
                child: SizedBox(
                  width: 200,
                  height: 100,
                  child: Image.asset('assets/images/Instagram.png'),
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 15),
              child: TextField(
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Phone number, email or username',
                  hintText: 'Enter valid email id as abc@gmail.com',
                ),
              ),
            ),

            Padding(
              padding: const EdgeInsets.only(
                left: 15.0,
                right: 15.0,
                top: 15,
                bottom: 0,
              ),
              child: TextField(
                obscureText: true,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Password',
                  hintText: 'Enter secure password',
                ),
              ),
            ),

            // --- Login button ---
            SizedBox(
              height: 65,
              width: 360,
              child: Container(
                child: Padding(
                  padding: const EdgeInsets.only(top: 20.0),
                  child: ElevatedButton(
                    child: Text(
                      'Log in ',
                      style: TextStyle(color: Colors.white, fontSize: 20),
                    ),
                    onPressed: () {
                      // Demo-only: uses a dummy PageController
                      AuthService.emailSignup(
                        emailAddress: "random@gmail.com",
                        password: "passsd",
                        displayName: "random username",
                        context: context,
                        pageController: PageController(),
                      );
                    },
                  ),
                ),
              ),
            ),

            // --- NEW: Stress Spike Test button ---
            SizedBox(
              height: 55,
              width: 360,
              child: Padding(
                padding: const EdgeInsets.only(top: 10.0),
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pushNamed(context, '/stress-test');
                  },
                  child: const Text(
                    'Open Stress Spike Test',
                    style: TextStyle(fontSize: 16),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 50),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('Forgot your login details? '),
                InkWell(
                  onTap: () {
                    debugPrint('Get help logging in tapped');
                  },
                  child: const Text(
                    'Get help logging in.',
                    style: TextStyle(fontSize: 14, color: Colors.blue),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
