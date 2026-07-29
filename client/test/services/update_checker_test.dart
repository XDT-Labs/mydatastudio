import 'package:flutter_test/flutter_test.dart';
import 'package:mydatastudio/services/update_checker.dart';

void main() {
  // Version comparison decides whether a release prompt appears at all. Get it
  // wrong one way and every user is nagged on a build they already run; wrong
  // the other way and nobody ever hears about a release.
  group('UpdateChecker.normalizeVersion', () {
    test('strips the tag prefix the release workflow adds', () {
      expect(UpdateChecker.normalizeVersion('v1.2.3'), '1.2.3');
      expect(UpdateChecker.normalizeVersion('V1.2.3'), '1.2.3');
    });

    test('strips the build number carried by the app version', () {
      // currentAppVersion() returns "<version>+<build>"; the release tag has no
      // build number, so the two are only comparable once it is dropped.
      expect(UpdateChecker.normalizeVersion('1.0.1+2'), '1.0.1');
    });

    test('strips a pre-release suffix', () {
      expect(UpdateChecker.normalizeVersion('v2.0.0-beta.1'), '2.0.0');
    });

    test('tolerates surrounding whitespace', () {
      expect(UpdateChecker.normalizeVersion('  v1.2.3 '), '1.2.3');
    });
  });

  group('UpdateChecker.compareVersions', () {
    test('orders by numeric value, not lexically', () {
      // The bug this pins: "1.10.0" sorts before "1.9.0" as a string, which
      // would leave everyone on 1.10.0 permanently prompted to "upgrade" to
      // 1.9.0.
      expect(UpdateChecker.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.9.0', '1.10.0'), lessThan(0));
    });

    test('reports equality for the same version', () {
      expect(UpdateChecker.compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('compares major and minor before patch', () {
      expect(UpdateChecker.compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(UpdateChecker.compareVersions('1.3.0', '1.2.99'), greaterThan(0));
    });

    test('treats missing components as zero', () {
      expect(UpdateChecker.compareVersions('1.2', '1.2.0'), 0);
      expect(UpdateChecker.compareVersions('1.2.1', '1.2'), greaterThan(0));
    });

    test('treats a malformed component as zero rather than throwing', () {
      // A hand-cut tag must not make the check blow up on every launch; the
      // caller reads "not newer" and stays quiet.
      expect(UpdateChecker.compareVersions('1.2.x', '1.2.0'), 0);
      expect(UpdateChecker.compareVersions('', '0.0.0'), 0);
    });

    test('a released tag reads as newer than the running build', () {
      // The end-to-end shape of the real check: tag_name vs currentAppVersion.
      final latest = UpdateChecker.normalizeVersion('v1.1.0');
      final current = UpdateChecker.normalizeVersion('1.0.1+2');
      expect(UpdateChecker.compareVersions(latest, current), greaterThan(0));
    });

    test('the running build is not newer than its own release tag', () {
      final latest = UpdateChecker.normalizeVersion('v1.0.1');
      final current = UpdateChecker.normalizeVersion('1.0.1+2');
      expect(UpdateChecker.compareVersions(latest, current), 0);
    });
  });
}
