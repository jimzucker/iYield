// Copyright 2026 James A. Zucker
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'package:flutter_test/flutter_test.dart';
import 'package:true_yield/main.dart';

void main() {
  group('isStale — true when the calendar date differs', () {
    test('same day, different times → not stale', () {
      expect(
        isStale(DateTime(2026, 5, 28, 8, 0), DateTime(2026, 5, 28, 23, 59)),
        isFalse,
      );
    });

    test('next day → stale', () {
      expect(
        isStale(DateTime(2026, 5, 28, 23, 59), DateTime(2026, 5, 29, 0, 1)),
        isTrue,
      );
    });

    test('across month and year boundaries → stale', () {
      expect(isStale(DateTime(2026, 1, 31), DateTime(2026, 2, 1)), isTrue);
      expect(isStale(DateTime(2025, 12, 31), DateTime(2026, 1, 1)), isTrue);
    });
  });

  group('date formatting', () {
    test('fmtDateHuman renders "Mon D, YYYY"', () {
      expect(fmtDateHuman(DateTime(2025, 12, 31)), 'Dec 31, 2025');
      expect(fmtDateHuman(DateTime(2026, 1, 5)), 'Jan 5, 2026');
    });

    test('fmtStamp renders a 12-hour timestamp', () {
      expect(fmtStamp(DateTime(2026, 5, 28, 20, 41)), 'May 28, 2026, 8:41 PM');
      expect(fmtStamp(DateTime(2026, 5, 28, 0, 5)), 'May 28, 2026, 12:05 AM');
      expect(fmtStamp(DateTime(2026, 5, 28, 12, 0)), 'May 28, 2026, 12:00 PM');
    });
  });
}
