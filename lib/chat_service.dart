import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> sendMessage(String travelId, String text) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    if (text.trim().isEmpty) return;
    await _db
        .collection('travels')
        .doc(travelId)
        .collection('chat_messages')
        .add({
      'senderId': uid,
      'senderType': 2, // 2 = driver (la app del pasajero envía 1)
      'text': text.trim(),
      'timestamp': FieldValue.serverTimestamp(),
    });
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(
      String travelId) {
    return _db
        .collection('travels')
        .doc(travelId)
        .collection('chat_messages')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots();
  }
}
