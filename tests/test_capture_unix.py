"""Behavioral contracts for native Capture payloads and alignment boundaries."""
import base64
import json
from pathlib import Path
import sys
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'src/Focalet.Capture.Unix'))
from capture_context import Batch, Item, enrich, source_at, same_source, snapshot, png_bytes


class CaptureTests(unittest.TestCase):
    def source(self, **changes):
        return {'nativeWindowId': 'window:1', 'processId': 123, 'processStartToken': 'birth-1',
                'windowTitle': 'Fixture', 'bounds': {'x': 0, 'y': 0, 'width': 100, 'height': 100}, **changes}

    def test_context_preserves_unicode_full_structure_and_independent_images(self):
        metadata = {'regionContext': {'elements': [{'role': 'Text', 'text': '中文 🖼', 'state': {'focused': False}}]}}
        batch = Batch([Item(b'first image', 13, 9, metadata), Item(b'second image', 17, 6, metadata)])
        text, html = batch.text(), batch.html()
        self.assertLess(text.index('[A]'), text.index('[B]'))
        self.assertEqual(text.count('Captured context'), 1)
        self.assertIn('中文 🖼', text); self.assertIn('"focused":false', text)
        self.assertLess(html.index(base64.b64encode(b'first image').decode()), html.index('[A]'))
        self.assertLess(html.index('[A]'), html.index(base64.b64encode(b'second image').decode()))
        self.assertLess(html.index(base64.b64encode(b'second image').decode()), html.index('[B]'))

    def test_regions_are_bounded_and_source_requires_one_unobscured_window(self):
        with self.assertRaises(ValueError): Batch([])
        with self.assertRaises(ValueError): Batch([Item(b'a', 1, 1, {})]*9)
        with self.assertRaises(ValueError): Batch([Item(b'a'*(17*1024*1024), 1, 1, {})]*2)
        with self.assertRaises(ValueError): Item(b'a', 10000, 10000, {})
        bounds = {'x': 10, 'y': 10, 'width': 20, 'height': 20}
        source = self.source()
        self.assertEqual(source_at([source], bounds), source)
        obstruction = {'bounds': {'x': 10, 'y': 10, 'width': 1, 'height': 1}, 'obstruction': True}
        self.assertIsNone(source_at([obstruction, source], bounds))
        for field, value in [('nativeWindowId', 'other'), ('processId', 999), ('processStartToken', 'reused'), ('windowTitle', 'changed'), ('bounds', {})]:
            self.assertFalse(same_source(source, {**source, field: value}))

    def test_stale_pixels_and_missing_context_do_not_retain_structure(self):
        result = snapshot({'x': 0, 'y': 0, 'width': 10, 'height': 10}, 10, 10)
        self.assertEqual(result['region']['status'], 'image-only')
        self.assertNotIn('source', result); self.assertNotIn('regionContext', result)
        source = self.source()
        class Native:
            def request(self, *_): return {'stable': True, 'source': source, 'dataUrl': 'newer pixels'}
        self.assertIsNone(enrich(None, Native(), source, source['bounds'], 100, 100, lambda _: False))
        self.assertIsNone(enrich(None, Native(), None, source['bounds'], 100, 100, lambda _: True))

    def test_browser_requires_matching_confirmation_and_releases_observation(self):
        source = self.source(); bounds = source['bounds']
        class Native:
            def request(self, *_): return {'stable': True, 'source': source, 'dataUrl': 'pixels', 'browserViewport': bounds, 'windows': [source]}
        class Browser:
            def __init__(self, confirmed): self.calls = []; self.confirmed = confirmed
            def request(self, method, *_):
                self.calls.append(method)
                return {'available': self.confirmed if method == 'confirm' else True, 'dom': {'elements': ['fixture']}, 'source': {'tabId': 'tab-1'}}
        failed = Browser(False)
        self.assertIsNone(enrich(failed, Native(), source, bounds, 100, 100, lambda _: True))
        self.assertEqual(failed.calls, ['observe', 'confirm', 'release'])
        browser = Browser(True)
        result = enrich(browser, Native(), source, bounds, 100, 100, lambda _: True)
        self.assertEqual(result['source']['tabId'], 'tab-1'); self.assertEqual(result['dom']['elements'], ['fixture'])

    def test_malformed_image_is_rejected(self):
        for value in (None, 'other', 'data:image/png;base64,??', 'data:image/png;base64,'+base64.b64encode(b'not png').decode()):
            with self.assertRaises(ValueError): png_bytes(value)


if __name__ == '__main__': unittest.main()
