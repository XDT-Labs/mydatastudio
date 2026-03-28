import 'package:flutter/material.dart';

Widget infoRow(String label, String value, {String? tooltip}) {
  Widget valueWidget = Text(
    value,
    style: const TextStyle(fontSize: 12),
    overflow: TextOverflow.ellipsis,
    maxLines: 2,
  );

  if (tooltip != null) {
    valueWidget = Tooltip(message: tooltip, child: valueWidget);
  }

  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(child: valueWidget),
      ],
    ),
  );
}

Widget infoRowSelectable(String label, String value) {
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.grey,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 2),
        SelectableText(
          value,
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ],
    ),
  );
}
