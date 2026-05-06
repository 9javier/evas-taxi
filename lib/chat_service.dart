import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> sendMessage(String travelId, String text) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    debugPrint('[ChatService] sendMessage → uid=$uid travelId=$travelId text="$text"');
    if (uid == null) {
      debugPrint('[ChatService] ERROR: currentUser es null');
      return;
    }
    if (text.trim().isEmpty) return;
    final ref = await _db
        .collection('travels')
        .doc(travelId)
        .collection('chat_messages')
        .add({
      'senderId': uid,
      'senderType': 2, // 2 = driver (la app del pasajero envía 1)
      'text': text.trim(),
      'timestamp': FieldValue.serverTimestamp(),
    });
    debugPrint('[ChatService] Documento creado: ${ref.path}');
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
