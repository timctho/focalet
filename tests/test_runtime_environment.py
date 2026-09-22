"""Runtime probes retain agent configuration without a parent app's identity."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from runtime_environment import without_parent_context


class RuntimeEnvironmentTests(unittest.TestCase):
    def test_parent_namespaces_are_isolated_without_stripping_agent_settings(self):
        kept = {
            "HOME": "/home/example", "PATH": "/bin", "CODEX_HOME": "/home/example/.codex",
            "OPENAI_API_KEY": "fixture-provider-key", "AWS_SESSION_TOKEN": "fixture-token",
            "ZOMMI_CODEX_HOME": "/home/example/.codex", "ZOMMI_RUNTIME_CHILD": "1",
            "ZOMMI_FAKE_CODEX_HOME": "/fixture", "ZOMMI_FAKE_CODEX_HOME_LOG": "/fixture/log",
        }
        parent = {
            "DESKTOP_HOST_AGENT_HOOK_ENDPOINT": "http://127.0.0.1:1",
            "DESKTOP_HOST_FUTURE_ROUTING_KEY": "fixture",
            "Editor_Tab_Id": "fixture", "Editor_Secret": "fixture",
            "SECOND_HOST_CODEX_HOME": "/parent", "SECOND_HOST_PANE_KEY": "fixture",
        }
        inherited = {**kept, **parent}
        self.assertEqual(without_parent_context(inherited), kept)
        self.assertEqual(inherited, {**kept, **parent})

    def test_an_ordinary_terminal_environment_is_preserved(self):
        inherited = {"CODEX_HOME": "/home/example/.codex", "API_KEY": "fixture"}
        self.assertEqual(without_parent_context(inherited), inherited)


if __name__ == "__main__":
    unittest.main()
