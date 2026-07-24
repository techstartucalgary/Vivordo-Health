import 'package:cloud_firestore/cloud_firestore.dart';

class MetricsDaily {
  final String userId;
  final String metricType;
  final String period;
  num? avg;
  num? min;
  num? max;
  num? sum;
  num? count;
  String? unit;
  String? dimension;
  String? source;
  List<String> tags;
  Timestamp? computedAt;
  Timestamp createdAt;
  Timestamp updatedAt;

  MetricsDaily({
    required this.userId,
    required this.metricType,
    required this.period,
    required this.createdAt,
    required this.updatedAt,
    this.avg,
    this.min,
    this.max,
    this.sum,
    this.count,
    this.unit,
    this.dimension,
    this.source,
    this.tags = const [],
    this.computedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      "userId": userId,
      "metricType": metricType,
      "period": period,
      "avg": avg,
      "min": min,
      "max": max,
      "sum": sum,
      "count": count,
      "unit": unit,
      "dimension": dimension,
      "source": source,
      "tags": tags,
      "computedAt": computedAt,
      "createdAt": createdAt,
      "updatedAt": updatedAt,
    };
  }

  factory MetricsDaily.fromMap(Map<String, dynamic> map) {
    return MetricsDaily(
      userId: map["userId"] ?? "",
      metricType: map["metricType"] ?? "",
      period: map["period"] ?? "",
      createdAt: map["createdAt"] as Timestamp,
      updatedAt: map["updatedAt"] as Timestamp,

      avg: map["avg"],
      min: map["min"],
      max: map["max"],
      sum: map["sum"],
      count: map["count"],

      unit: map["unit"],
      dimension: map["dimension"],
      source: map["source"],

      tags: map["tags"] != null ? List<String>.from(map["tags"]) : const [],

      computedAt: map["computedAt"] as Timestamp?,
    );
  }

  Future<void> toFirestore() async {
    await FirebaseFirestore.instance.collection('metrics_daily').add(toMap());
  }
}
