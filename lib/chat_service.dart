import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class ChatService {
  static final _db = FirebaseFirestore.instance;

  static Future<void> sendMessage(String travelId, String text) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    debugPrint('[CHAT DEBUG] sendMessage → travelId="$travelId" | authUid="$uid"');
    if (uid == null) {
      debugPrint('[CHAT DEBUG] sendMessage → ABORTADO: usuario no autenticado');
      return;
    }
    if (text.trim().isEmpty) return;

    // Verificar que el documento del viaje existe antes de escribir
    try {
      final travelDoc = await _db.collection('travels').doc(travelId).get();
      debugPrint('[CHAT DEBUG] travels/$travelId exists=${travelDoc.exists}');
      if (travelDoc.exists) {
        final data = travelDoc.data() ?? {};
        debugPrint('[CHAT DEBUG] driverId en travels="${data['driverId']}" | userId="${data['userId']}"');
        debugPrint('[CHAT DEBUG] authUid=="$uid" | match driverId=${data['driverId'] == uid} | match userId=${data['userId'] == uid}');
      }
    } catch (e) {
      debugPrint('[CHAT DEBUG] Error leyendo travels/$travelId: $e');
    }

    try {
      await _db
          .collection('travels')
          .doc(travelId)
          .collection('chat_messages')
          .add({
        'senderId': uid,
        'senderType': 2,
        'text': text.trim(),
        'timestamp': FieldValue.serverTimestamp(),
      });
      debugPrint('[CHAT DEBUG] sendMessage → mensaje enviado OK');
    } catch (e) {
      debugPrint('[CHAT DEBUG] sendMessage → ERROR al escribir: $e');
      rethrow;
    }
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> messagesStream(
      String travelId) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    debugPrint('[CHAT DEBUG] messagesStream → travelId="$travelId" | authUid="$uid"');
    return _db
        .collection('travels')
        .doc(travelId)
        .collection('chat_messages')
        .orderBy('timestamp', descending: true)
        .limit(20)
        .snapshots();
  }
}
