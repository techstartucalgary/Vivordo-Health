import 'package:firebase_ai/firebase_ai.dart';

class AiDemoService {
  static Future<void> testPrompt() async {
    final model = FirebaseAI.googleAI().generativeModel(
      model: 'gemini-2.5-flash',
    );

    // Provide a prompt that contains text
    final prompt = [Content.text('Write a story about a magic backpack.')];

    // To generate text output, call generateContent with the text input
    final response = await model.generateContent(prompt);
    print(response.text);
  }
}
