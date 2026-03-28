import 'package:flutter/material.dart';
import 'package:mydatatools/models/tables/file.dart' as model;
import 'package:mydatatools/modules/email/widgets/email_detail/attachment_thumbnail_widget.dart';

class EmailAttachmentsSection extends StatelessWidget {
  const EmailAttachmentsSection({super.key, required this.attachments});

  final List<model.File> attachments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${attachments.length} Attachments',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 100,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: attachments.length,
              itemBuilder: (context, index) =>
                  AttachmentThumbnailWidget(file: attachments[index]),
            ),
          ),
        ],
      ),
    );
  }
}
