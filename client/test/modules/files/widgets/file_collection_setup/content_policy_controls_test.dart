import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/content_policy_controls.dart';
import 'package:mydatastudio/modules/files/widgets/file_collection_setup/sync_estimate_dialog.dart';
import 'package:mydatastudio/scanners/cloud/cloud_sync_estimator.dart';
import 'package:mydatastudio/scanners/cloud/content_policy.dart';

void main() {
  testWidgets('index switch and size cap change the policy', (tester) async {
    ContentPolicy? last;
    var policy = ContentPolicy.everything;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder:
                (c, set) => SingleChildScrollView(
                  child: ContentPolicyControls(
                    policy: policy,
                    onChanged: (v) => set(() => policy = last = v),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('index-switch')));
    await tester.pump();
    expect(last!.index, isFalse);

    await tester.tap(find.byKey(const ValueKey('size-cap')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Up to 100 MB').last);
    await tester.pumpAndSettle();
    expect(last!.maxFileBytes, 100 * 1024 * 1024);
    expect(last!.index, isFalse, reason: 'other settings are preserved');
  });

  test('estimate text matches the setup copy', () {
    final e =
        CloudSyncEstimate()
          ..files = 12340
          ..totalBytes = 48 * 1024 * 1024 * 1024
          ..downloadBytes = (9.1 * 1024 * 1024 * 1024).round();
    expect(
      describeEstimate(e),
      '12,340 files, 48 GB; 9.1 GB will be downloaded',
    );
  });
}
