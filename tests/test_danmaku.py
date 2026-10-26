"""Offline regressions against the complete vendored Danmu2Ass module."""

import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest import mock
from urllib.error import HTTPError


SOURCE = (
    Path(__file__).resolve().parents[1]
    / "config/scripts/bilibiliAssert/Danmu2Ass.py"
)
SPEC = importlib.util.spec_from_file_location("danmu2ass_under_test", SOURCE)
danmaku = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(danmaku)


class DanmakuTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        network = mock.patch.object(
            danmaku.request, "urlopen", side_effect=AssertionError("Network forbidden")
        )
        self.urlopen = network.start()
        self.addCleanup(network.stop)
        xml = '<i>' + ''.join(
            f'<d p="{1 + index * 10},1,25,16777215,0">{text}</d>'
            for index, text in enumerate(("keep", "regex_drop", "file_drop"))
        ) + '</i>'
        self.comments = list(danmaku.ReadCommentsBilibili(io.StringIO(xml), 25))

    def write_comments(self, **options):
        danmaku.write2file(self.comments, str(self.directory), 640, 360, **options)
        output = self.directory / "bilibili.ass"
        content = output.read_text(encoding="utf-8")
        self.assertIn("[Script Info]", content)
        return [
            line.rsplit('}', 1)[-1]
            for line in content.splitlines()
            if line.startswith("Dialogue:")
        ]

    def filter_file(self, content):
        path = self.directory / "filters.txt"
        path.write_text(content, encoding="utf-8")
        return str(path)

    def test_default_keeps_all_comments(self):
        self.assertEqual(self.write_comments(), ["keep", "regex_drop", "file_drop"])

    def test_empty_filters_keep_all_comments(self):
        self.assertEqual(
            self.write_comments(
                comment_filter="", comment_filters_file=self.filter_file("\n \n")
            ),
            ["keep", "regex_drop", "file_drop"],
        )

    def test_regex_filter(self):
        self.assertEqual(
            self.write_comments(comment_filter="^regex_"), ["keep", "file_drop"]
        )

    def test_file_filter(self):
        self.assertEqual(
            self.write_comments(
                comment_filters_file=self.filter_file("\n  ^file_  \n\n")
            ),
            ["keep", "regex_drop"],
        )

    def test_regex_and_file_filters(self):
        self.assertEqual(
            self.write_comments(
                comment_filter="^regex_",
                comment_filters_file=self.filter_file("^file_\n"),
            ),
            ["keep"],
        )

    def test_invalid_regex_is_reported_before_output_is_created(self):
        for options in (
            {"comment_filter": "["},
            {"comment_filters_file": self.filter_file("[\n")},
            {"comment_filter": "^regex_", "comment_filters_file": self.filter_file("[\n")},
        ):
            with self.subTest(options=options):
                with self.assertRaisesRegex(ValueError, r"Invalid regular expression: \["):
                    self.write_comments(**options)
                self.assertFalse((self.directory / "bilibili.ass").exists())

    def test_http_errors_preserve_message_and_failure_exit(self):
        for status in (412, 403, 500):
            with self.subTest(status=status):
                error = HTTPError("https://comment.bilibili.com/123.xml", status, "test", None, None)
                self.urlopen.side_effect = error
                stdout = io.StringIO()
                with contextlib.redirect_stdout(stdout):
                    with self.assertRaises(SystemExit) as raised:
                        danmaku.getComments(["123"])
                self.assertEqual(raised.exception.code, 1)
                self.assertIn(f"HTTP Error occurred: {error}", stdout.getvalue())
                self.assertEqual("412 Precondition Failed:" in stdout.getvalue(), status == 412)


if __name__ == "__main__":
    unittest.main()
