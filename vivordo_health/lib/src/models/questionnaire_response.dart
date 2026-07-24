import 'package:cloud_firestore/cloud_firestore.dart';

class QuestionnaireResponse {
  final String userId;
  String questionnaireType;
  String version;
  FieldValue submittedAt;
  Map<String, dynamic> metadata;
  Map<String, dynamic> answers;
  Map<String, dynamic> derivedScores;
  FieldValue createdAt;
  FieldValue updatedAt;

  QuestionnaireResponse({
    required this.userId,
    required this.questionnaireType,
    this.version = 'v1',
    required this.submittedAt,
    required this.metadata,
    this.answers = const {},
    this.derivedScores = const {"stressScore": null},
    required this.createdAt,
    required this.updatedAt,
  });

  factory QuestionnaireResponse.fromMap(Map<String, dynamic> data) {
    return QuestionnaireResponse(
      userId: data['userId'],
      questionnaireType: data['questionnaireType'],
      version: data['version'],
      submittedAt: data['submittedAt'],
      metadata: data['metadata'],
      answers: data['answers'],
      derivedScores: data['derivedScores'],
      createdAt: data['createdAt'],
      updatedAt: data['updatedAt'],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'userId': userId,
      'questionnaireType': questionnaireType,
      'version': version,
      'submittedAt': submittedAt,
      'metadata': metadata,
      'answers': answers,
      'derivedScores': derivedScores,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  void addAnswer(String questionID, dynamic answer) {
    answers[questionID] = answer;
  }

  void changeStressScore(double score) {
    derivedScores["stressScore"] = score;
  }

  Future<void> toFirestore() async {
    FirebaseFirestore.instance.collection('questionnaire_responses').add(toMap());
  }
}