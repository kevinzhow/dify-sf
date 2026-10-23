"""Guard against reporting a mostly blank crop or text masking as control parity."""
import tempfile
from pathlib import Path
import unittest

from PIL import Image, ImageDraw

from compare import similarity, threshold_failures, validate_environments


class VisualAcceptanceTests(unittest.TestCase):
    def test_large_background_cannot_hide_a_wrong_control(self):
        # The full header looks 99.9% identical, but one tight control is wrong.
        rows = [('toolbar', .999, .999)]
        controls = {'toolbar': {'sort': {'geometryMatches': True, 'allPixelsWithin16': .72}}}
        self.assertEqual(threshold_failures(rows, controls, 99.5, 99.5), ['toolbar/sort'])

    def test_masked_typography_still_fails_the_score_including_text(self):
        with tempfile.TemporaryDirectory() as tmp:
            a, b = Path(tmp) / 'reference.png', Path(tmp) / 'actual.png'
            reference = Image.new('RGB', (100, 40), 'white')
            actual = reference.copy()
            ImageDraw.Draw(actual).rectangle((10, 10, 29, 19), fill='black')
            reference.save(a)
            actual.save(b)
            all_pixels, non_text, _ = similarity(a, b, text_rects=[(9, 9, 31, 21)])
            self.assertEqual(non_text, 1)
            self.assertLess(all_pixels, .995)
            self.assertEqual(threshold_failures([('toolbar', non_text, all_pixels)], {}, 99.5, 99.5), ['toolbar'])

    def test_size_mismatch_is_not_rescaled_into_a_pass(self):
        controls = {'toolbar': {'type': {'geometryMatches': False, 'allPixelsWithin16': None}}}
        self.assertEqual(threshold_failures([('toolbar', 1, 1)], controls, 99.5, 99.5), ['toolbar/type'])

    def test_wrong_reference_locale_is_rejected(self):
        reference = dict(locale='zh-Hans', theme='light', devicePixelRatio=2,
                         visualViewportScale=1, width=1440, height=900, userAgent='same')
        with self.assertRaisesRegex(ValueError, 'locale/theme'):
            validate_environments(reference, dict(reference, locale='en-US'))

    def test_zoomed_reference_is_rejected(self):
        reference = dict(locale='en-US', theme='light', devicePixelRatio=2,
                         visualViewportScale=1, width=1440, height=900, userAgent='same')
        with self.assertRaisesRegex(ValueError, 'DPR/zoom'):
            validate_environments(dict(reference, visualViewportScale=1.25), reference)


    def test_no_gate_requested_preserves_legacy_report_mode(self):
        self.assertEqual(threshold_failures([('known-deviation', .97, .92)], {}), [])


if __name__ == '__main__':
    unittest.main()
